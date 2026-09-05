import Darwin
import Foundation

/// A deliberately bounded recovery slot for the most recent accepted capture.
///
/// Samples remain in memory so a user can retry a poor transcription without
/// loading another model. The WAV exists only while delivery is unresolved: it
/// survives an inference failure or crash, then is removed after success.
final class LastRecordingRecovery: @unchecked Sendable {
    enum Recording: Sendable {
        case memory(samples: [Float], sampleRate: Int, fileURL: URL)
        case file(url: URL, sampleRate: Int, sampleCount: Int)

        var sampleRate: Int {
            switch self {
            case .memory(_, let sampleRate, _), .file(_, let sampleRate, _): return sampleRate
            }
        }

        var sampleCount: Int {
            switch self {
            case .memory(let samples, _, _): return samples.count
            case .file(_, _, let sampleCount): return sampleCount
            }
        }

        var duration: TimeInterval {
            guard sampleRate > 0 else { return 0 }
            return TimeInterval(sampleCount) / TimeInterval(sampleRate)
        }
    }

    enum RecoveryError: LocalizedError {
        case invalidWAV
        case unsupportedWAV
        case fileTooLarge
        case unsafeDirectory
        case atomicReplaceFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidWAV: return "the recovery recording is damaged"
            case .unsupportedWAV: return "the recovery recording has an unsupported format"
            case .fileTooLarge: return "the recovery recording is too large to restore safely"
            case .unsafeDirectory:
                return "the recovery directory must not be a symbolic link"
            case .atomicReplaceFailed(let code):
                return "couldn't commit the recovery recording (errno \(code))"
            }
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/parrot/recovery", isDirectory: true)
    }

    let fileURL: URL
    private let directory: URL
    private let lock = NSLock()
    private var lastSamples: [Float]?
    private var lastSampleRate = 16_000
    private var lastSampleCount = 0

    init(directory: URL = LastRecordingRecovery.defaultDirectory) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("last-recording.wav")
    }

    var hasRecording: Bool {
        lock.withLock { lastSamples != nil || (lastSampleCount > 0 && hasPendingFile) }
    }

    var hasPendingFile: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    func samples() -> (samples: [Float], sampleRate: Int)? {
        lock.withLock {
            guard let lastSamples else { return nil }
            return (lastSamples, lastSampleRate)
        }
    }

    func recording() -> Recording? {
        lock.withLock {
            if let lastSamples {
                return .memory(
                    samples: lastSamples,
                    sampleRate: lastSampleRate,
                    fileURL: fileURL
                )
            }
            guard lastSampleCount > 0, hasPendingFile else { return nil }
            return .file(
                url: fileURL,
                sampleRate: lastSampleRate,
                sampleCount: lastSampleCount
            )
        }
    }

    /// Recreate the private safety copy for a short in-memory retry after its
    /// previously delivered spool was deleted.
    func prepareForRetry() throws -> Recording? {
        let memory = lock.withLock { lastSamples.map { ($0, lastSampleRate) } }
        if !hasPendingFile, let memory {
            try stage(samples: memory.0, sampleRate: memory.1)
        }
        return recording()
    }

    /// A new capture intentionally owns the single recovery slot.
    func beginLiveCapture() throws {
        if hasPendingFile { try FileManager.default.removeItem(at: fileURL) }
        lock.withLock {
            lastSamples = nil
            lastSampleCount = 0
        }
    }

    /// Adopt the already-finalized live spool without rewriting its audio.
    func adoptLiveCapture(_ capture: CapturedAudio) throws -> Recording? {
        guard !capture.isEmpty else { return nil }
        if let url = capture.fileURL {
            guard url.standardizedFileURL == fileURL.standardizedFileURL else {
                throw RecoveryError.invalidWAV
            }
            let metadata = try LiveRecordingSpool.metadata(at: url)
            guard metadata.sampleRate == capture.sampleRate,
                  metadata.sampleCount == capture.sampleCount
            else { throw RecoveryError.invalidWAV }
            try tightenPermissions()
        } else if let samples = capture.samples {
            try stage(samples: samples, sampleRate: capture.sampleRate)
        } else {
            throw RecoveryError.invalidWAV
        }
        lock.withLock {
            lastSamples = capture.samples
            lastSampleRate = capture.sampleRate
            lastSampleCount = capture.sampleCount
        }
        return recording()
    }

    /// Load a recording left by a failed inference or interrupted process.
    @discardableResult
    func restorePending() throws -> Bool {
        if FileManager.default.fileExists(atPath: directory.path) {
            try validateDirectory()
        }
        removeStaleTemporaryFiles()
        guard hasPendingFile else { return false }
        try LiveRecordingSpool.repairHeaderIfNeeded(at: fileURL)
        let metadata = try LiveRecordingSpool.metadata(at: fileURL)
        if metadata.sampleCount <= AudioCapture.maximumInMemorySamples {
            let decoded = try Self.readPCM16WAV(at: fileURL)
            lock.withLock {
                lastSamples = decoded.samples
                lastSampleRate = decoded.sampleRate
                lastSampleCount = decoded.samples.count
            }
        } else {
            lock.withLock {
                lastSamples = nil
                lastSampleRate = metadata.sampleRate
                lastSampleCount = metadata.sampleCount
            }
        }
        try tightenPermissions()
        return true
    }

    /// Replace the prior slot atomically before inference begins.
    func stage(samples: [Float], sampleRate: Int) throws {
        guard !samples.isEmpty else { return }
        lock.withLock {
            lastSamples = samples
            lastSampleRate = sampleRate
            lastSampleCount = samples.count
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validateDirectory()
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        removeStaleTemporaryFiles()

        let temporaryURL = directory.appendingPathComponent(".last-recording-\(UUID().uuidString).tmp")
        do {
            try WAVWriter.write(samples: samples, sampleRate: sampleRate, to: temporaryURL.path)
            guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
                throw RecoveryError.atomicReplaceFailed(errno)
            }
            try tightenPermissions()
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            // The newest accepted capture owns the single recovery slot. If
            // replacing it failed, never leave an older WAV behind that could
            // be mistaken for the audio the user just recorded.
            try? fileManager.removeItem(at: fileURL)
            throw error
        }
    }

    /// Successful text delivery resolves the on-disk safety copy, while the
    /// in-memory samples remain available for an intentional reprocess.
    func markDelivered() throws {
        if hasPendingFile { try FileManager.default.removeItem(at: fileURL) }
        lock.withLock {
            if lastSamples == nil { lastSampleCount = 0 }
        }
    }

    func forget() throws {
        if hasPendingFile {
            try FileManager.default.removeItem(at: fileURL)
        }
        lock.withLock {
            lastSamples = nil
            lastSampleCount = 0
        }
    }

    private func tightenPermissions() throws {
        let fileManager = FileManager.default
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func validateDirectory() throws {
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RecoveryError.unsafeDirectory
        }
    }

    private func removeStaleTemporaryFiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents {
            let name = url.lastPathComponent
            let isInterruptedStage = name.hasPrefix(".last-recording-")
                && url.pathExtension == "tmp"
            let isInterruptedInference = name.hasPrefix(".parrot-inference-")
                && url.pathExtension == "wav"
            if isInterruptedStage || isInterruptedInference {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func readPCM16WAV(at url: URL) throws -> (samples: [Float], sampleRate: Int) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        // Roughly two hours at 16 kHz. This only guards a corrupt or replaced
        // local file from causing an unbounded allocation during startup.
        guard size <= 256 * 1_024 * 1_024 else { throw RecoveryError.fileTooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 44,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE",
              String(data: data[12..<16], encoding: .ascii) == "fmt ",
              String(data: data[36..<40], encoding: .ascii) == "data"
        else { throw RecoveryError.invalidWAV }

        let format = uint16LE(data, 20)
        let channels = uint16LE(data, 22)
        let sampleRate = Int(uint32LE(data, 24))
        let bitsPerSample = uint16LE(data, 34)
        let declaredBytes = Int(uint32LE(data, 40))
        guard format == 1, channels == 1, bitsPerSample == 16, sampleRate > 0 else {
            throw RecoveryError.unsupportedWAV
        }
        guard declaredBytes >= 0,
              declaredBytes.isMultiple(of: 2),
              44 + declaredBytes <= data.count
        else { throw RecoveryError.invalidWAV }

        var samples = [Float]()
        samples.reserveCapacity(declaredBytes / 2)
        var offset = 44
        let end = 44 + declaredBytes
        while offset < end {
            let value = Int16(bitPattern: uint16LE(data, offset))
            samples.append(Float(value) / 32_767.0)
            offset += 2
        }
        return (samples, sampleRate)
    }

    private static func uint16LE(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32LE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

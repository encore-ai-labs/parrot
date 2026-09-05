import Darwin
import Foundation

struct LiveRecordingSummary: Equatable, Sendable {
    let fileURL: URL
    let sampleRate: Int
    let sampleCount: Int
    let rms: Float

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(sampleCount) / TimeInterval(sampleRate)
    }
}

/// Streams one live capture to a private PCM16 WAV while it is recorded.
///
/// The header is kept repairable until `finish()`: if the process exits in the
/// middle of a locked note, startup derives the exact payload length from the
/// regular file and patches only the two WAV size fields.
final class LiveRecordingSpool {
    enum SpoolError: LocalizedError, Equatable {
        case invalidSampleRate
        case unsafeFile
        case outputExists
        case recordingTooLong
        case io(String)

        var errorDescription: String? {
            switch self {
            case .invalidSampleRate:
                return "live recording sample rate is invalid"
            case .unsafeFile:
                return "live recovery path is not a private regular file"
            case .outputExists:
                return "a live recovery recording already exists"
            case .recordingTooLong:
                return "live recording exceeded the WAV format limit"
            case .io(let message):
                return "live recovery write failed: \(message)"
            }
        }
    }

    static let headerSize = 44
    static let bytesPerSample = 2
    static let maximumDataBytes = Int(UInt32.max) - 36

    let fileURL: URL
    let sampleRate: Int

    private var descriptor: Int32
    private var sampleCount = 0
    private var sumOfSquares: Double = 0
    private var finished = false

    init(fileURL: URL, sampleRate: Int) throws {
        guard sampleRate > 0, sampleRate <= Int(UInt32.max) / Self.bytesPerSample else {
            throw SpoolError.invalidSampleRate
        }
        self.fileURL = fileURL
        self.sampleRate = sampleRate

        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let directoryValues = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true
        else { throw SpoolError.unsafeFile }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        descriptor = fileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            if errno == EEXIST { throw SpoolError.outputExists }
            throw SpoolError.io(Self.errorMessage(errno))
        }

        do {
            try Self.writeAll(Self.header(sampleRate: sampleRate, dataBytes: 0), to: descriptor)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Darwin.close(descriptor)
            descriptor = -1
            try? fileManager.removeItem(at: fileURL)
            throw error
        }
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    func append<C: Collection>(_ samples: C) throws where C.Element == Float {
        guard descriptor >= 0, !finished else {
            throw SpoolError.io("recording file is closed")
        }
        guard !samples.isEmpty else { return }
        let (additionalBytes, overflow) = samples.count.multipliedReportingOverflow(
            by: Self.bytesPerSample
        )
        let currentBytes = sampleCount * Self.bytesPerSample
        guard !overflow, additionalBytes <= Self.maximumDataBytes - currentBytes else {
            throw SpoolError.recordingTooLong
        }

        var localSquares: Double = 0
        var pcm = Data(count: additionalBytes)
        pcm.withUnsafeMutableBytes { rawBuffer in
            let output = rawBuffer.bindMemory(to: UInt16.self)
            var index = 0
            for sample in samples {
                let clamped = max(-1.0, min(1.0, sample))
                let value = Int16(clamped * 32_767.0)
                output[index] = UInt16(bitPattern: value).littleEndian
                localSquares += Double(clamped * clamped)
                index += 1
            }
        }
        try Self.writeAll(pcm, to: descriptor)
        sampleCount += samples.count
        sumOfSquares += localSquares
    }

    func finish() throws -> LiveRecordingSummary {
        guard descriptor >= 0, !finished else {
            throw SpoolError.io("recording file is already closed")
        }
        let dataBytes = sampleCount * Self.bytesPerSample
        do {
            try Self.patchSizes(descriptor: descriptor, dataBytes: dataBytes)
            guard fsync(descriptor) == 0 else {
                throw SpoolError.io(Self.errorMessage(errno))
            }
            guard Darwin.close(descriptor) == 0 else {
                descriptor = -1
                throw SpoolError.io(Self.errorMessage(errno))
            }
            descriptor = -1
            finished = true
            return LiveRecordingSummary(
                fileURL: fileURL,
                sampleRate: sampleRate,
                sampleCount: sampleCount,
                rms: sampleCount > 0
                    ? Float((sumOfSquares / Double(sampleCount)).squareRoot())
                    : 0
            )
        } catch {
            if descriptor >= 0 {
                Darwin.close(descriptor)
                descriptor = -1
            }
            throw error
        }
    }

    func cancel() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        finished = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Finalizes a recording left by a crash or clean shutdown during capture.
    /// Only the declared RIFF/data sizes are changed; audio payload bytes stay
    /// untouched.
    static func repairHeaderIfNeeded(at url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw SpoolError.unsafeFile }
        defer { Darwin.close(descriptor) }

        let metadata = try inspect(descriptor: descriptor)
        if metadata.declaredDataBytes != metadata.actualDataBytes {
            try patchSizes(descriptor: descriptor, dataBytes: metadata.actualDataBytes)
            guard fsync(descriptor) == 0 else {
                throw SpoolError.io(errorMessage(errno))
            }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func metadata(at url: URL) throws -> (sampleRate: Int, sampleCount: Int) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw SpoolError.unsafeFile }
        defer { Darwin.close(descriptor) }
        let metadata = try inspect(descriptor: descriptor)
        guard metadata.declaredDataBytes == metadata.actualDataBytes else {
            throw SpoolError.unsafeFile
        }
        return (metadata.sampleRate, metadata.actualDataBytes / bytesPerSample)
    }

    private static func inspect(descriptor: Int32) throws
        -> (sampleRate: Int, declaredDataBytes: Int, actualDataBytes: Int)
    {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= off_t(headerSize)
        else { throw SpoolError.unsafeFile }
        let actualDataBytes = Int(status.st_size) - headerSize
        guard actualDataBytes >= 0,
              actualDataBytes.isMultiple(of: bytesPerSample),
              actualDataBytes <= maximumDataBytes
        else { throw SpoolError.unsafeFile }

        var header = Data(count: headerSize)
        let readCount = header.withUnsafeMutableBytes { buffer in
            pread(descriptor, buffer.baseAddress, headerSize, 0)
        }
        guard readCount == headerSize,
              String(data: header[0..<4], encoding: .ascii) == "RIFF",
              String(data: header[8..<12], encoding: .ascii) == "WAVE",
              String(data: header[12..<16], encoding: .ascii) == "fmt ",
              uint16LE(header, 20) == 1,
              uint16LE(header, 22) == 1,
              uint16LE(header, 34) == 16,
              String(data: header[36..<40], encoding: .ascii) == "data"
        else { throw SpoolError.unsafeFile }
        let sampleRate = Int(uint32LE(header, 24))
        guard sampleRate > 0 else { throw SpoolError.unsafeFile }
        return (sampleRate, Int(uint32LE(header, 40)), actualDataBytes)
    }

    private static func patchSizes(descriptor: Int32, dataBytes: Int) throws {
        guard dataBytes >= 0, dataBytes <= maximumDataBytes else {
            throw SpoolError.recordingTooLong
        }
        var riffSize = UInt32(36 + dataBytes).littleEndian
        var payloadSize = UInt32(dataBytes).littleEndian
        guard withUnsafeBytes(of: &riffSize, {
            pwrite(descriptor, $0.baseAddress, $0.count, 4)
        }) == MemoryLayout<UInt32>.size,
        withUnsafeBytes(of: &payloadSize, {
            pwrite(descriptor, $0.baseAddress, $0.count, 40)
        }) == MemoryLayout<UInt32>.size else {
            throw SpoolError.io(errorMessage(errno))
        }
    }

    private static func header(sampleRate: Int, dataBytes: Int) -> Data {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(uint32LE(UInt32(36 + dataBytes)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(uint32LE(16))
        data.append(uint16LE(1))
        data.append(uint16LE(1))
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(UInt32(sampleRate * bytesPerSample)))
        data.append(uint16LE(UInt16(bytesPerSample)))
        data.append(uint16LE(16))
        data.append(contentsOf: Array("data".utf8))
        data.append(uint32LE(UInt32(dataBytes)))
        return data
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var failure: Int32?
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                if count == 0 {
                    failure = EIO
                    return
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        if let failure { throw SpoolError.io(errorMessage(failure)) }
    }

    private static func uint16LE(_ value: UInt16) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: MemoryLayout<UInt16>.size)
    }

    private static func uint32LE(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: MemoryLayout<UInt32>.size)
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

    private static func errorMessage(_ code: Int32) -> String {
        guard let message = strerror(code) else { return "error \(code)" }
        return String(cString: message)
    }
}

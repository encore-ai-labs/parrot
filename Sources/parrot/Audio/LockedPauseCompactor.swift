import Darwin
import Foundation

/// A deterministic, local-only edit list for an inference copy of a recording.
///
/// The original recovery WAV is never modified. Long quiet regions are shortened
/// rather than removed entirely so note-mode paragraph timing remains useful and
/// soft speech near either edge of a pause has generous protection.
struct LockedPauseCompactionPlan: Equatable, Sendable {
    let sampleRate: Int
    let originalSampleCount: Int
    let removedRanges: [Range<Int>]

    var removedSampleCount: Int {
        removedRanges.reduce(0) { $0 + $1.count }
    }

    var outputSampleCount: Int {
        originalSampleCount - removedSampleCount
    }

    var removedDuration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(removedSampleCount) / TimeInterval(sampleRate)
    }

    var didCompact: Bool { !removedRanges.isEmpty }

    func applying(to samples: [Float]) -> [Float] {
        guard samples.count == originalSampleCount, didCompact else { return samples }
        var output: [Float] = []
        output.reserveCapacity(outputSampleCount)
        var cursor = 0
        for range in removedRanges {
            if cursor < range.lowerBound {
                output.append(contentsOf: samples[cursor..<range.lowerBound])
            }
            cursor = range.upperBound
        }
        if cursor < samples.count {
            output.append(contentsOf: samples[cursor..<samples.count])
        }
        return output
    }
}

struct PreparedInferenceRecording: Sendable {
    let recording: LastRecordingRecovery.Recording
    let originalSampleCount: Int
    let inferenceSampleCount: Int
    let temporaryFileURL: URL?

    var sampleRate: Int { recording.sampleRate }

    var removedDuration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(originalSampleCount - inferenceSampleCount) / TimeInterval(sampleRate)
    }

    var didCompact: Bool { inferenceSampleCount < originalSampleCount }

    static func unchanged(_ recording: LastRecordingRecovery.Recording) -> Self {
        Self(
            recording: recording,
            originalSampleCount: recording.sampleCount,
            inferenceSampleCount: recording.sampleCount,
            temporaryFileURL: nil
        )
    }

    func removeTemporaryFile() {
        guard let temporaryFileURL else { return }
        try? FileManager.default.removeItem(at: temporaryFileURL)
    }
}

/// Conservatively shortens only very long, confidently quiet regions.
///
/// This is intentionally scoped to double-tap locked recordings by the caller.
/// Hold-to-talk and general file transcription keep their original audio and
/// timestamp timeline. Analysis is linear and bounded; it has no model download,
/// network request, or idle microphone cost.
enum LockedPauseCompactor {
    static let frameDuration: TimeInterval = 0.02
    static let minimumQuietDuration: TimeInterval = 5
    static let retainedInteriorDuration: TimeInterval = 1.5
    static let retainedEdgeDuration: TimeInterval = 1
    static let minimumSavedDuration: TimeInterval = 1
    /// Energy-only classification cannot prove that a sustained low signal is
    /// not whispered speech. Never trim above this near-silence ceiling.
    static let maximumQuietRMS: Float = 0.0015
    static let maximumInputBytes = 256 * 1_024 * 1_024
    private static let fileChunkSamples = 32_768

    static func plan(samples: [Float], sampleRate: Int) -> LockedPauseCompactionPlan {
        guard sampleRate > 0, !samples.isEmpty else {
            return .init(sampleRate: sampleRate, originalSampleCount: samples.count, removedRanges: [])
        }
        var analyzer = FrameEnergyAnalyzer(sampleRate: sampleRate)
        analyzer.consume(samples)
        return plan(
            frameRMS: analyzer.finish(),
            sampleRate: sampleRate,
            sampleCount: samples.count
        )
    }

    static func prepare(
        _ recording: LastRecordingRecovery.Recording
    ) throws -> PreparedInferenceRecording {
        switch recording {
        case .memory(let samples, let sampleRate, let recoveryURL):
            let plan = plan(samples: samples, sampleRate: sampleRate)
            guard plan.didCompact else { return .unchanged(recording) }
            let compacted = plan.applying(to: samples)
            return PreparedInferenceRecording(
                recording: .memory(
                    samples: compacted,
                    sampleRate: sampleRate,
                    fileURL: recoveryURL
                ),
                originalSampleCount: samples.count,
                inferenceSampleCount: compacted.count,
                temporaryFileURL: nil
            )

        case .file(let url, let sampleRate, let sampleCount):
            let byteCount = sampleCount.multipliedReportingOverflow(
                by: LiveRecordingSpool.bytesPerSample
            )
            guard !byteCount.overflow,
                  byteCount.partialValue + LiveRecordingSpool.headerSize <= maximumInputBytes
            else { return .unchanged(recording) }

            var analyzer = FrameEnergyAnalyzer(sampleRate: sampleRate)
            try forEachPCM16Chunk(at: url, expectedSampleCount: sampleCount) { samples, _ in
                analyzer.consume(samples)
            }
            let plan = plan(
                frameRMS: analyzer.finish(),
                sampleRate: sampleRate,
                sampleCount: sampleCount
            )
            guard plan.didCompact else { return .unchanged(recording) }

            let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
                ".parrot-inference-\(UUID().uuidString).wav"
            )
            let spool = try LiveRecordingSpool(fileURL: temporaryURL, sampleRate: sampleRate)
            var completed = false
            defer {
                if !completed { spool.cancel() }
            }
            var removedRangeIndex = 0
            try forEachPCM16Chunk(at: url, expectedSampleCount: sampleCount) { samples, start in
                try appendKeptSamples(
                    samples,
                    globalStart: start,
                    removedRanges: plan.removedRanges,
                    removedRangeIndex: &removedRangeIndex,
                    to: spool
                )
            }
            let summary = try spool.finish()
            completed = true
            guard summary.sampleCount == plan.outputSampleCount else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw LiveRecordingSpool.SpoolError.io("pause-compacted sample count did not match")
            }
            return PreparedInferenceRecording(
                recording: .file(
                    url: temporaryURL,
                    sampleRate: sampleRate,
                    sampleCount: summary.sampleCount
                ),
                originalSampleCount: sampleCount,
                inferenceSampleCount: summary.sampleCount,
                temporaryFileURL: temporaryURL
            )
        }
    }

    static func plan(
        frameRMS: [Float],
        sampleRate: Int,
        sampleCount: Int
    ) -> LockedPauseCompactionPlan {
        let unchanged = LockedPauseCompactionPlan(
            sampleRate: sampleRate,
            originalSampleCount: sampleCount,
            removedRanges: []
        )
        guard sampleRate > 0,
              sampleCount > 0,
              frameRMS.count >= 2,
              TimeInterval(sampleCount) / TimeInterval(sampleRate) >= minimumQuietDuration
        else { return unchanged }

        let sorted = frameRMS.sorted()
        let noise = percentile(0.20, in: sorted)
        let speech = percentile(0.98, in: sorted)
        // A flat signal, continuous fan noise, or all-silence capture is not
        // edited. The normal capture-quality gate handles unusable recordings.
        guard speech - noise >= 0.002,
              speech >= max(noise * 2.5, 0.0025)
        else { return unchanged }

        let adaptive = noise + ((speech - noise) * 0.08)
        let conservativeCeiling = max(noise * 1.8, noise + 0.0015)
        let quietThreshold = min(adaptive, conservativeCeiling, maximumQuietRMS)
        let frameSamples = max(1, Int((frameDuration * TimeInterval(sampleRate)).rounded()))
        let minimumQuietSamples = Int((minimumQuietDuration * TimeInterval(sampleRate)).rounded())
        let edgeSamples = Int((retainedEdgeDuration * TimeInterval(sampleRate)).rounded())
        let interiorSideSamples = Int(
            ((retainedInteriorDuration / 2) * TimeInterval(sampleRate)).rounded()
        )
        let minimumSavedSamples = Int((minimumSavedDuration * TimeInterval(sampleRate)).rounded())

        var ranges: [Range<Int>] = []
        var startFrame: Int?
        for frame in 0...frameRMS.count {
            let isQuiet = frame < frameRMS.count && frameRMS[frame] <= quietThreshold
            if isQuiet {
                if startFrame == nil { startFrame = frame }
                continue
            }
            guard let quietStartFrame = startFrame else { continue }
            startFrame = nil
            let quietStart = min(sampleCount, quietStartFrame * frameSamples)
            let quietEnd = min(sampleCount, frame * frameSamples)
            guard quietEnd - quietStart >= minimumQuietSamples else { continue }

            let removal: Range<Int>
            if quietStart == 0 {
                removal = quietStart..<max(quietStart, quietEnd - edgeSamples)
            } else if quietEnd == sampleCount {
                removal = min(quietEnd, quietStart + edgeSamples)..<quietEnd
            } else {
                let lower = min(quietEnd, quietStart + interiorSideSamples)
                let upper = max(quietStart, quietEnd - interiorSideSamples)
                removal = lower..<upper
            }
            if removal.count >= minimumSavedSamples { ranges.append(removal) }
        }
        return LockedPauseCompactionPlan(
            sampleRate: sampleRate,
            originalSampleCount: sampleCount,
            removedRanges: ranges
        )
    }

    private static func percentile(_ fraction: Double, in sorted: [Float]) -> Float {
        let index = min(
            sorted.count - 1,
            max(0, Int((Double(sorted.count - 1) * fraction).rounded()))
        )
        return sorted[index]
    }

    private static func appendKeptSamples(
        _ samples: [Float],
        globalStart: Int,
        removedRanges: [Range<Int>],
        removedRangeIndex: inout Int,
        to spool: LiveRecordingSpool
    ) throws {
        let globalEnd = globalStart + samples.count
        var cursor = globalStart
        while removedRangeIndex < removedRanges.count,
              removedRanges[removedRangeIndex].upperBound <= cursor {
            removedRangeIndex += 1
        }
        while cursor < globalEnd {
            guard removedRangeIndex < removedRanges.count else {
                try spool.append(samples[(cursor - globalStart)..<samples.count])
                return
            }
            let removed = removedRanges[removedRangeIndex]
            if removed.lowerBound >= globalEnd {
                try spool.append(samples[(cursor - globalStart)..<samples.count])
                return
            }
            if cursor < removed.lowerBound {
                let keptEnd = min(globalEnd, removed.lowerBound)
                try spool.append(samples[(cursor - globalStart)..<(keptEnd - globalStart)])
                cursor = keptEnd
            }
            if cursor >= removed.lowerBound {
                cursor = min(globalEnd, removed.upperBound)
                if cursor >= removed.upperBound { removedRangeIndex += 1 }
            }
        }
    }

    private static func forEachPCM16Chunk(
        at url: URL,
        expectedSampleCount: Int,
        body: ([Float], Int) throws -> Void
    ) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw LiveRecordingSpool.SpoolError.unsafeFile }
        defer { Darwin.close(descriptor) }

        var status = stat()
        let expectedBytes = LiveRecordingSpool.headerSize
            + expectedSampleCount * LiveRecordingSpool.bytesPerSample
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size == off_t(expectedBytes)
        else { throw LiveRecordingSpool.SpoolError.unsafeFile }

        var sampleOffset = 0
        while sampleOffset < expectedSampleCount {
            let count = min(fileChunkSamples, expectedSampleCount - sampleOffset)
            let byteCount = count * LiveRecordingSpool.bytesPerSample
            var data = Data(count: byteCount)
            var bytesRead = 0
            while bytesRead < byteCount {
                let readCount = data.withUnsafeMutableBytes { buffer -> Int in
                    guard let baseAddress = buffer.baseAddress else { return -1 }
                    return pread(
                        descriptor,
                        baseAddress.advanced(by: bytesRead),
                        byteCount - bytesRead,
                        off_t(LiveRecordingSpool.headerSize
                            + sampleOffset * LiveRecordingSpool.bytesPerSample + bytesRead)
                    )
                }
                if readCount < 0, errno == EINTR { continue }
                guard readCount > 0 else {
                    throw LiveRecordingSpool.SpoolError.io("couldn't read recovery audio")
                }
                bytesRead += readCount
            }

            var samples = [Float](repeating: 0, count: count)
            data.withUnsafeBytes { buffer in
                let bytes = buffer.bindMemory(to: UInt8.self)
                for index in 0..<count {
                    let offset = index * 2
                    let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                    samples[index] = Float(Int16(bitPattern: bits)) / 32_767
                }
            }
            try body(samples, sampleOffset)
            sampleOffset += count
        }
    }
}

enum LockedPausePolicy {
    static func shouldCompact(wasLatched: Bool, settingEnabled: Bool) -> Bool {
        wasLatched && settingEnabled
    }
}

private struct FrameEnergyAnalyzer {
    let frameSamples: Int
    private(set) var energies: [Float] = []
    private var squareSum: Double = 0
    private var sampleCount = 0

    init(sampleRate: Int) {
        frameSamples = max(
            1,
            Int((LockedPauseCompactor.frameDuration * TimeInterval(sampleRate)).rounded())
        )
    }

    mutating func consume<C: Collection>(_ samples: C) where C.Element == Float {
        for sample in samples {
            // Treat corrupt/non-finite input as active so it can never help
            // qualify a region for destructive omission from the inference copy.
            let finite = sample.isFinite ? max(-1, min(1, sample)) : 1
            squareSum += Double(finite * finite)
            sampleCount += 1
            if sampleCount == frameSamples {
                energies.append(Float((squareSum / Double(sampleCount)).squareRoot()))
                squareSum = 0
                sampleCount = 0
            }
        }
    }

    mutating func finish() -> [Float] {
        if sampleCount > 0 {
            energies.append(Float((squareSum / Double(sampleCount)).squareRoot()))
            squareSum = 0
            sampleCount = 0
        }
        return energies
    }
}

import AVFoundation
import Foundation

/// Refines coarse recognition boundaries with short, bounded reads around each
/// boundary. Energy thresholds are local and adaptive, so quiet microphones do
/// not need a device-specific amplitude setting.
enum AudioPauseDetector {
    private static let lookbackSeconds: TimeInterval = 2.8
    private static let lookaheadSeconds: TimeInterval = 0.35
    private static let frameSeconds: TimeInterval = 0.04
    private static let boundaryToleranceSeconds: TimeInterval = 0.20

    static func refining(
        _ segments: [TimedTranscriptSegment],
        samples: [Float],
        sampleRate: Double
    ) -> [TimedTranscriptSegment] {
        guard sampleRate > 0, !samples.isEmpty else { return segments }
        return refine(segments) { boundary in
            let start = max(0, boundary - lookbackSeconds)
            let end = min(Double(samples.count) / sampleRate, boundary + lookaheadSeconds)
            let lower = min(samples.count, max(0, Int((start * sampleRate).rounded(.down))))
            let upper = min(samples.count, max(lower, Int((end * sampleRate).rounded(.up))))
            return silenceStart(
                in: Array(samples[lower..<upper]),
                sampleRate: sampleRate,
                windowStart: start,
                boundary: boundary
            )
        }
    }

    static func refining(
        _ segments: [TimedTranscriptSegment],
        audioAt url: URL
    ) throws -> [TimedTranscriptSegment] {
        guard segments.count > 1 else { return segments }
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return segments }
        let duration = Double(file.length) / sampleRate

        return try refine(segments) { boundary in
            let start = max(0, boundary - lookbackSeconds)
            let end = min(duration, boundary + lookaheadSeconds)
            let startFrame = AVAudioFramePosition((start * sampleRate).rounded(.down))
            let requested = AVAudioFrameCount(max(0, (end - start) * sampleRate))
            guard requested > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: requested)
            else { return nil }
            file.framePosition = startFrame
            try file.read(into: buffer, frameCount: requested)
            return silenceStart(
                in: monoSamples(from: buffer),
                sampleRate: sampleRate,
                windowStart: Double(startFrame) / sampleRate,
                boundary: boundary
            )
        }
    }

    private static func refine(
        _ segments: [TimedTranscriptSegment],
        silenceStartAtBoundary: (TimeInterval) throws -> TimeInterval?
    ) rethrows -> [TimedTranscriptSegment] {
        guard segments.count > 1 else { return segments }
        var output = segments
        for index in 1..<output.count {
            let boundary = output[index].startSeconds
            guard boundary.isFinite,
                  boundary >= output[index - 1].startSeconds,
                  let silenceStart = try silenceStartAtBoundary(boundary),
                  silenceStart < boundary
            else { continue }
            let previous = output[index - 1]
            output[index - 1] = TimedTranscriptSegment(
                startSeconds: previous.startSeconds,
                endSeconds: max(
                    previous.startSeconds,
                    min(previous.endSeconds, silenceStart)
                ),
                text: previous.text
            )
        }
        return output
    }

    private static func silenceStart(
        in samples: [Float],
        sampleRate: Double,
        windowStart: TimeInterval,
        boundary: TimeInterval
    ) -> TimeInterval? {
        let frameLength = max(1, Int((frameSeconds * sampleRate).rounded()))
        guard samples.count >= frameLength * 4 else { return nil }
        var energies: [Float] = []
        energies.reserveCapacity((samples.count + frameLength - 1) / frameLength)
        for start in stride(from: 0, to: samples.count, by: frameLength) {
            let end = min(samples.count, start + frameLength)
            var sum: Double = 0
            for sample in samples[start..<end] {
                sum += Double(sample) * Double(sample)
            }
            energies.append(Float(sqrt(sum / Double(end - start))))
        }
        let sorted = energies.sorted()
        let quietCount = max(1, sorted.count / 4)
        let loudCount = max(1, sorted.count * 15 / 100)
        let noise = sorted.prefix(quietCount).reduce(0, +) / Float(quietCount)
        let speech = sorted.suffix(loudCount).reduce(0, +) / Float(loudCount)
        guard speech >= max(noise * 2.0, noise + 0.000_5) else { return nil }
        let threshold = noise + (speech - noise) * 0.20

        let boundaryFrame = min(
            energies.count,
            max(0, Int(((boundary - windowStart) / frameSeconds).rounded(.down)))
        )
        let toleranceFrames = Int((boundaryToleranceSeconds / frameSeconds).rounded(.up))
        let minimumSilentFrames = Int(
            (AutomaticParagraphFormatter.pauseThreshold / frameSeconds).rounded(.up)
        )
        guard boundaryFrame >= minimumSilentFrames else { return nil }

        var index = boundaryFrame - 1
        while index >= 0 {
            while index >= 0, energies[index] > threshold { index -= 1 }
            let runEnd = index + 1
            while index >= 0, energies[index] <= threshold { index -= 1 }
            let runStart = index + 1
            if runEnd >= boundaryFrame - toleranceFrames,
               runEnd - runStart >= minimumSilentFrames {
                return windowStart + Double(runStart) * frameSeconds
            }
            if runEnd < boundaryFrame - toleranceFrames { return nil }
        }
        return nil
    }

    private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return [] }
        var output = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var squared: Float = 0
            for channel in 0..<channelCount {
                let sample = channels[channel][frame]
                squared += sample * sample
            }
            output[frame] = sqrt(squared / Float(channelCount))
        }
        return output
    }
}

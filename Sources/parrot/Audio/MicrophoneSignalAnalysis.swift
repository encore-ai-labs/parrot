import Foundation

enum MicrophoneSignalRating: String, Codable, Equatable, Sendable {
    case noSignal = "no-signal"
    case quiet
    case healthy
    case clipping

    var summary: String {
        switch self {
        case .noSignal: return "no reliable microphone signal detected"
        case .quiet: return "voice signal is too quiet for dependable notes"
        case .healthy: return "voice signal looks healthy"
        case .clipping: return "input is too loud or clipping"
        }
    }

    var advice: String {
        switch self {
        case .noSignal:
            return "Check the hardware mute, selected input, and macOS microphone permission."
        case .quiet:
            return "Move closer or raise Input volume in System Settings → Sound → Input."
        case .healthy:
            return "This microphone should provide a dependable signal for local transcription."
        case .clipping:
            return "Move farther away or lower Input volume in System Settings → Sound → Input."
        }
    }
}

/// A bounded, deterministic signal check. It never retains audio beyond the
/// caller-owned sample collection and does no recognition or network work.
struct MicrophoneSignalAnalysis: Codable, Equatable, Sendable {
    static let frameDurationSeconds = 0.02
    static let activeFrameRMS: Double = 0.003
    static let noSignalRMS: Double = 0.0005
    static let quietRMS: Double = 0.008
    static let clippingAmplitude: Double = 0.99
    static let maximumClippedSampleFraction: Double = 0.001
    static let excessiveRMS: Double = 0.35

    let sampleCount: Int
    let sampleRate: Int
    let durationSeconds: Double
    let rms: Double
    let rmsDBFS: Double?
    let peak: Double
    let peakDBFS: Double?
    let activeFrameFraction: Double
    let clippedSampleFraction: Double
    let rating: MicrophoneSignalRating

    static func analyze<S: Collection>(
        _ samples: S,
        sampleRate: Int
    ) -> MicrophoneSignalAnalysis where S.Element == Float {
        let validSampleRate = max(1, sampleRate)
        let frameSize = max(1, Int(Double(validSampleRate) * frameDurationSeconds))
        var sumSquares = 0.0
        var peak = 0.0
        var clippedSamples = 0
        var frameSumSquares = 0.0
        var frameSamples = 0
        var activeFrames = 0
        var totalFrames = 0
        var sampleCount = 0

        func finishFrame() -> Bool {
            guard frameSamples > 0 else { return false }
            totalFrames += 1
            let frameRMS = sqrt(frameSumSquares / Double(frameSamples))
            if frameRMS >= activeFrameRMS { activeFrames += 1 }
            return true
        }

        for rawSample in samples {
            let finiteSample = rawSample.isFinite ? Double(rawSample) : 0
            let amplitude = abs(finiteSample)
            let square = finiteSample * finiteSample
            sumSquares += square
            frameSumSquares += square
            frameSamples += 1
            sampleCount += 1
            peak = max(peak, amplitude)
            if amplitude >= clippingAmplitude { clippedSamples += 1 }

            if frameSamples == frameSize {
                _ = finishFrame()
                frameSumSquares = 0
                frameSamples = 0
            }
        }
        _ = finishFrame()

        let rms = sampleCount > 0 ? sqrt(sumSquares / Double(sampleCount)) : 0
        let activeFraction = totalFrames > 0
            ? Double(activeFrames) / Double(totalFrames)
            : 0
        let clippedFraction = sampleCount > 0
            ? Double(clippedSamples) / Double(sampleCount)
            : 0
        let rating: MicrophoneSignalRating
        if rms < noSignalRMS || activeFrames == 0 {
            rating = .noSignal
        } else if clippedFraction >= maximumClippedSampleFraction || rms >= excessiveRMS {
            rating = .clipping
        } else if rms < quietRMS || activeFraction < 0.15 {
            rating = .quiet
        } else {
            rating = .healthy
        }

        return MicrophoneSignalAnalysis(
            sampleCount: sampleCount,
            sampleRate: validSampleRate,
            durationSeconds: Double(sampleCount) / Double(validSampleRate),
            rms: rms,
            rmsDBFS: decibelsFullScale(rms),
            peak: peak,
            peakDBFS: decibelsFullScale(peak),
            activeFrameFraction: activeFraction,
            clippedSampleFraction: clippedFraction,
            rating: rating
        )
    }

    private static func decibelsFullScale(_ amplitude: Double) -> Double? {
        guard amplitude > 0 else { return nil }
        return 20 * log10(amplitude)
    }
}

struct MicrophoneTestResult: Codable, Equatable, Sendable {
    let deviceName: String
    let deviceUID: String
    let transport: String
    let analysis: MicrophoneSignalAnalysis

    func textReport() -> String {
        let level = analysis.rmsDBFS.map { String(format: "%.1f dBFS", $0) } ?? "−∞ dBFS"
        let peak = analysis.peakDBFS.map { String(format: "%.1f dBFS", $0) } ?? "−∞ dBFS"
        let activity = Int((analysis.activeFrameFraction * 100).rounded())
        let clipping = analysis.clippedSampleFraction * 100
        let mark = analysis.rating == .healthy ? "✓" : "!"
        return [
            "microphone test",
            "  device     \(deviceName) · \(transport)",
            String(format: "  captured   %.2fs · %d Hz", analysis.durationSeconds, analysis.sampleRate),
            "  level      \(level)",
            "  peak       \(peak)",
            "  activity   \(activity)% of 20ms frames",
            String(format: "  clipping   %.3f%% of samples", clipping),
            "\(mark) \(analysis.rating.summary)",
            "  → \(analysis.rating.advice)",
        ].joined(separator: "\n")
    }
}

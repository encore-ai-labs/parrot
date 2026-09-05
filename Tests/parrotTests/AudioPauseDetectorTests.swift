import AVFoundation
import XCTest

@testable import parrot

final class AudioPauseDetectorTests: XCTestCase {
    private let sampleRate = 16_000.0

    func testRefinesCoarseBoundaryToStartOfDeliberateSilence() {
        let samples = noteAudio(silenceStart: 2.0, secondThoughtStart: 3.6)
        let refined = AudioPauseDetector.refining(
            coarseSegments(boundary: 3.6),
            samples: samples,
            sampleRate: sampleRate
        )

        XCTAssertEqual(refined[0].endSeconds, 2.0, accuracy: 0.05)
        XCTAssertEqual(
            AutomaticParagraphFormatter.format(
                "First thought. Second thought.",
                segments: refined
            ),
            "First thought.\n\nSecond thought."
        )
    }

    func testShortHesitationDoesNotBecomeParagraph() {
        let samples = noteAudio(silenceStart: 2.8, secondThoughtStart: 3.6)
        let coarse = coarseSegments(boundary: 3.6)

        XCTAssertEqual(
            AudioPauseDetector.refining(coarse, samples: samples, sampleRate: sampleRate),
            coarse
        )
    }

    func testAdaptiveEnergyWorksForQuietMicrophone() {
        let samples = noteAudio(
            silenceStart: 2.0,
            secondThoughtStart: 3.6,
            speechAmplitude: 0.004,
            noiseAmplitude: 0.000_2
        )
        let refined = AudioPauseDetector.refining(
            coarseSegments(boundary: 3.6),
            samples: samples,
            sampleRate: sampleRate
        )

        XCTAssertEqual(refined[0].endSeconds, 2.0, accuracy: 0.05)
    }

    func testUnchangingBackgroundDoesNotInventPause() {
        let samples = [Float](repeating: 0.003, count: Int(6 * sampleRate))
        let coarse = coarseSegments(boundary: 3.6)

        XCTAssertEqual(
            AudioPauseDetector.refining(coarse, samples: samples, sampleRate: sampleRate),
            coarse
        )
    }

    func testFileScanningReadsOnlyBoundaryWindowsAndFindsPause() throws {
        let samples = noteAudio(silenceStart: 2.0, secondThoughtStart: 3.6)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-pause-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(samples, to: url)

        let refined = try AudioPauseDetector.refining(
            coarseSegments(boundary: 3.6),
            audioAt: url
        )

        XCTAssertEqual(refined[0].endSeconds, 2.0, accuracy: 0.05)
    }

    func testStereoChannelsCannotCancelPauseDetection() throws {
        let samples = noteAudio(silenceStart: 2.0, secondThoughtStart: 3.6)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-pause-stereo-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(samples, to: url, oppositePhaseStereo: true)

        let refined = try AudioPauseDetector.refining(
            coarseSegments(boundary: 3.6),
            audioAt: url
        )

        XCTAssertEqual(refined[0].endSeconds, 2.0, accuracy: 0.05)
    }

    func testRefinementNeverExtendsAnAlreadyAccurateSegmentEnd() {
        let samples = noteAudio(silenceStart: 2.0, secondThoughtStart: 3.6)
        var segments = coarseSegments(boundary: 3.6)
        segments[0] = TimedTranscriptSegment(
            startSeconds: 0,
            endSeconds: 1.9,
            text: segments[0].text
        )

        let refined = AudioPauseDetector.refining(
            segments,
            samples: samples,
            sampleRate: sampleRate
        )

        XCTAssertEqual(refined[0].endSeconds, 1.9)
    }

    private func coarseSegments(boundary: Double) -> [TimedTranscriptSegment] {
        [
            TimedTranscriptSegment(
                startSeconds: 0,
                endSeconds: boundary,
                text: "First thought."
            ),
            TimedTranscriptSegment(
                startSeconds: boundary,
                endSeconds: 6,
                text: "Second thought."
            ),
        ]
    }

    private func noteAudio(
        silenceStart: Double,
        secondThoughtStart: Double,
        speechAmplitude: Float = 0.05,
        noiseAmplitude: Float = 0.001
    ) -> [Float] {
        (0..<Int(6 * sampleRate)).map { index in
            let time = Double(index) / sampleRate
            let amplitude = time < silenceStart || time >= secondThoughtStart
                ? speechAmplitude
                : noiseAmplitude
            return index.isMultiple(of: 2) ? amplitude : -amplitude
        }
    }

    private func write(
        _ samples: [Float],
        to url: URL,
        oppositePhaseStereo: Bool = false
    ) throws {
        let channelCount: AVAudioChannelCount = oppositePhaseStereo ? 2 : 1
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for index in samples.indices {
            channels[0][index] = samples[index]
            if oppositePhaseStereo { channels[1][index] = -samples[index] }
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }
}

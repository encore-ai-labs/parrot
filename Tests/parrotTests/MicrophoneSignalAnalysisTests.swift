import XCTest

@testable import parrot

final class MicrophoneSignalAnalysisTests: XCTestCase {
    func testDigitalSilenceHasNoSignalAndNoDecibelValues() {
        let result = MicrophoneSignalAnalysis.analyze(
            [Float](repeating: 0, count: 16_000),
            sampleRate: 16_000
        )

        XCTAssertEqual(result.rating, .noSignal)
        XCTAssertEqual(result.durationSeconds, 1, accuracy: 0.000_001)
        XCTAssertEqual(result.rms, 0)
        XCTAssertEqual(result.peak, 0)
        XCTAssertNil(result.rmsDBFS)
        XCTAssertNil(result.peakDBFS)
        XCTAssertEqual(result.activeFrameFraction, 0)
    }

    func testQuietVoiceIsDistinguishedFromNoSignal() {
        let samples = sine(amplitude: 0.006, seconds: 1)
        let result = MicrophoneSignalAnalysis.analyze(samples, sampleRate: 16_000)

        XCTAssertEqual(result.rating, .quiet)
        XCTAssertEqual(result.rms, 0.006 / sqrt(2), accuracy: 0.000_01)
        XCTAssertEqual(result.activeFrameFraction, 1, accuracy: 0.000_001)
    }

    func testHealthyVoiceReportsLevelPeakAndActivity() {
        let samples = sine(amplitude: 0.1, seconds: 1)
        let result = MicrophoneSignalAnalysis.analyze(samples, sampleRate: 16_000)

        XCTAssertEqual(result.rating, .healthy)
        XCTAssertEqual(result.rms, 0.1 / sqrt(2), accuracy: 0.000_1)
        XCTAssertEqual(result.peak, 0.1, accuracy: 0.000_1)
        XCTAssertEqual(result.activeFrameFraction, 1, accuracy: 0.000_001)
        XCTAssertEqual(result.clippedSampleFraction, 0)
    }

    func testClippedSamplesAreFlagged() {
        var samples = [Float](repeating: 0.1, count: 16_000)
        for index in stride(from: 0, to: samples.count, by: 100) {
            samples[index] = 1
        }

        let result = MicrophoneSignalAnalysis.analyze(samples, sampleRate: 16_000)

        XCTAssertEqual(result.rating, .clipping)
        XCTAssertEqual(result.clippedSampleFraction, 0.01, accuracy: 0.000_001)
    }

    func testNonFiniteSamplesDoNotPoisonAnalysisAndPartialFrameCounts() {
        var samples = [Float](repeating: 0.1, count: 321)
        samples[0] = .nan
        samples[1] = .infinity
        let result = MicrophoneSignalAnalysis.analyze(samples, sampleRate: 16_000)

        XCTAssertTrue(result.rms.isFinite)
        XCTAssertTrue(result.peak.isFinite)
        XCTAssertEqual(result.activeFrameFraction, 1)
        XCTAssertEqual(result.sampleCount, 321)
    }

    func testResultEncodesAndTextReportExplainsOutcome() throws {
        let analysis = MicrophoneSignalAnalysis.analyze(
            sine(amplitude: 0.1, seconds: 1),
            sampleRate: 16_000
        )
        let result = MicrophoneTestResult(
            deviceName: "Studio USB",
            deviceUID: "studio-1",
            transport: "usb",
            analysis: analysis
        )

        let encoded = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(MicrophoneTestResult.self, from: encoded), result)
        XCTAssertTrue(result.textReport().contains("Studio USB · usb"))
        XCTAssertTrue(result.textReport().contains("voice signal looks healthy"))
        XCTAssertTrue(result.textReport().contains("activity"))
    }

    func testDeviceTestCommandParsesAndBoundsDuration() throws {
        let command = try XCTUnwrap(
            try Devices.parseAsRoot([
                "test", "--input-device", "MacBook", "--seconds", "3", "--json",
            ]) as? Devices.Test
        )
        XCTAssertEqual(command.inputDevice, "MacBook")
        XCTAssertEqual(command.seconds, 3)
        XCTAssertTrue(command.json)

        XCTAssertThrowsError(try Devices.parseAsRoot(["test", "--seconds", "1"]))
        XCTAssertThrowsError(try Devices.parseAsRoot(["test", "--seconds", "16"]))
        XCTAssertThrowsError(try Devices.parseAsRoot(["test", "--seconds", "nan"]))
    }

    func testTenSecondSignalAnalysisStaysFast() {
        let samples = sine(amplitude: 0.1, seconds: 10)
        let start = ContinuousClock.now
        for _ in 0..<10 {
            XCTAssertEqual(
                MicrophoneSignalAnalysis.analyze(samples, sampleRate: 16_000).rating,
                .healthy
            )
        }
        let elapsed = start.duration(to: .now)

        // This is deliberately generous for shared CI. Ten full passes over a
        // ten-second sample should remain far below capture time.
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    private func sine(
        amplitude: Float,
        frequency: Double = 220,
        seconds: Double,
        sampleRate: Int = 16_000
    ) -> [Float] {
        let count = Int(seconds * Double(sampleRate))
        return (0..<count).map { index in
            amplitude * Float(sin(2 * .pi * frequency * Double(index) / Double(sampleRate)))
        }
    }
}

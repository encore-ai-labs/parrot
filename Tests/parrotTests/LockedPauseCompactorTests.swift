import Foundation
import XCTest

@testable import parrot

final class LockedPauseCompactorTests: XCTestCase {
    private let sampleRate = 16_000

    func testCompactsOnlyCenterOfLongInteriorQuietRun() {
        let samples = tone(seconds: 1)
            + silence(seconds: 6)
            + tone(seconds: 1)

        let plan = LockedPauseCompactor.plan(samples: samples, sampleRate: sampleRate)
        let output = plan.applying(to: samples)

        XCTAssertTrue(plan.didCompact)
        XCTAssertEqual(plan.removedRanges.count, 1)
        XCTAssertEqual(plan.removedDuration, 4.5, accuracy: 0.03)
        XCTAssertEqual(Double(output.count) / Double(sampleRate), 3.5, accuracy: 0.03)
        XCTAssertEqual(Array(output.prefix(sampleRate)), tone(seconds: 1))
        XCTAssertEqual(Array(output.suffix(sampleRate)), tone(seconds: 1))
    }

    func testRetainsOneSecondBesideSpeechAtRecordingEdges() {
        let leading = LockedPauseCompactor.plan(
            samples: silence(seconds: 6) + tone(seconds: 1),
            sampleRate: sampleRate
        )
        let trailing = LockedPauseCompactor.plan(
            samples: tone(seconds: 1) + silence(seconds: 6),
            sampleRate: sampleRate
        )

        XCTAssertEqual(leading.removedDuration, 5, accuracy: 0.03)
        XCTAssertEqual(trailing.removedDuration, 5, accuracy: 0.03)
        XCTAssertEqual(leading.outputSampleCount, 2 * sampleRate, accuracy: 640)
        XCTAssertEqual(trailing.outputSampleCount, 2 * sampleRate, accuracy: 640)
    }

    func testLeavesShortPausesAndFlatSignalsByteStable() {
        let shortPause = tone(seconds: 2)
            + silence(seconds: 4.98)
            + tone(seconds: 2)
        let flatSilence = silence(seconds: 10)
        let flatNoise = [Float](repeating: 0.004, count: 10 * sampleRate)

        for samples in [shortPause, flatSilence, flatNoise] {
            let plan = LockedPauseCompactor.plan(samples: samples, sampleRate: sampleRate)
            XCTAssertFalse(plan.didCompact)
            XCTAssertEqual(plan.applying(to: samples), samples)
        }
    }

    func testProtectsLowEnergyActivityAboveConservativeQuietCeiling() {
        let quietActivity = [Float](repeating: 0.002, count: 6 * sampleRate)
        let samples = tone(seconds: 1) + quietActivity + tone(seconds: 1)

        let plan = LockedPauseCompactor.plan(samples: samples, sampleRate: sampleRate)

        // This guard intentionally biases toward keeping questionable audio.
        // It is not a substitute for a learned VAD, so pause trimming remains
        // user-controllable and is exercised against real speech separately.
        XCTAssertFalse(plan.didCompact)
    }

    func testFilePreparationUsesPrivateTemporaryWAVAndNeverChangesRecovery() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("last-recording.wav")
        let samples = tone(seconds: 1) + silence(seconds: 6) + tone(seconds: 1)
        let spool = try LiveRecordingSpool(fileURL: originalURL, sampleRate: sampleRate)
        try spool.append(samples)
        let originalSummary = try spool.finish()
        let originalBytes = try Data(contentsOf: originalURL)

        let prepared = try LockedPauseCompactor.prepare(.file(
            url: originalURL,
            sampleRate: sampleRate,
            sampleCount: originalSummary.sampleCount
        ))
        defer { prepared.removeTemporaryFile() }

        XCTAssertTrue(prepared.didCompact)
        let temporaryURL = try XCTUnwrap(prepared.temporaryFileURL)
        XCTAssertNotEqual(temporaryURL, originalURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertEqual(permissions(temporaryURL), 0o600)
        XCTAssertEqual(permissions(directory), 0o700)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        let metadata = try LiveRecordingSpool.metadata(at: temporaryURL)
        XCTAssertEqual(metadata.sampleCount, prepared.inferenceSampleCount)

        prepared.removeTemporaryFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
    }

    func testThreeMinuteFileBackedPreparationStaysFarBelowRealtime() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("last-recording.wav")
        let speech = tone(seconds: 1)
        let pause = silence(seconds: 8)
        let spool = try LiveRecordingSpool(fileURL: originalURL, sampleRate: sampleRate)
        for _ in 0..<22 {
            try spool.append(speech)
            try spool.append(pause)
        }
        let summary = try spool.finish()

        let started = ContinuousClock.now
        let prepared = try LockedPauseCompactor.prepare(.file(
            url: originalURL,
            sampleRate: sampleRate,
            sampleCount: summary.sampleCount
        ))
        let elapsed = seconds(since: started)
        defer { prepared.removeTemporaryFile() }

        XCTAssertTrue(prepared.didCompact)
        XCTAssertGreaterThan(prepared.removedDuration, 140)
        XCTAssertLessThan(elapsed, 3)
        XCTAssertLessThan(elapsed / summary.duration, 0.02)
        print(String(format: "file-backed pause prep %.3fs for %.1fs audio", elapsed, summary.duration))
    }

    func testOneRunFlagsAreExclusiveAndBenchmarkIsOptIn() throws {
        let enabled = try XCTUnwrap(try Run.parseAsRoot(["--compact-pauses"]) as? Run)
        let disabled = try XCTUnwrap(try Run.parseAsRoot(["--no-compact-pauses"]) as? Run)
        XCTAssertTrue(enabled.compactPauses)
        XCTAssertTrue(disabled.noCompactPauses)
        XCTAssertThrowsError(try Run.parseAsRoot([
            "--compact-pauses", "--no-compact-pauses",
        ]))

        let benchmark = try XCTUnwrap(try ModelBenchmark.parseAsRoot([
            "whisper-base.en", "--audio", "/tmp/sample.wav", "--compact-pauses",
        ]) as? ModelBenchmark)
        XCTAssertTrue(benchmark.compactPauses)
    }

    func testPolicyNeverTouchesHoldToTalkOrDisabledSetting() {
        XCTAssertFalse(LockedPausePolicy.shouldCompact(wasLatched: false, settingEnabled: false))
        XCTAssertFalse(LockedPausePolicy.shouldCompact(wasLatched: false, settingEnabled: true))
        XCTAssertFalse(LockedPausePolicy.shouldCompact(wasLatched: true, settingEnabled: false))
        XCTAssertTrue(LockedPausePolicy.shouldCompact(wasLatched: true, settingEnabled: true))
    }

    private func tone(seconds: Double, amplitude: Float = 0.08) -> [Float] {
        let count = Int(seconds * Double(sampleRate))
        return (0..<count).map { index in
            index.isMultiple(of: 2) ? amplitude : -amplitude
        }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-pause-compactor-tests-\(UUID().uuidString)")
    }

    private func permissions(_ url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }
}

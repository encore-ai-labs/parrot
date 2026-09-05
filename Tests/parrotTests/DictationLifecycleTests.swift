import XCTest

@testable import parrot

final class DictationLifecycleTests: XCTestCase {
    func testBlocksAnotherRecordingUntilCurrentTranscriptionFinishes() throws {
        let lifecycle = DictationLifecycle()
        let first = try XCTUnwrap(lifecycle.start())
        XCTAssertNil(lifecycle.start())
        XCTAssertEqual(lifecycle.beginTranscription(), first)
        XCTAssertTrue(lifecycle.isTranscribing)
        XCTAssertNil(lifecycle.start())
        XCTAssertTrue(lifecycle.finish(first))

        let second = try XCTUnwrap(lifecycle.start())
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(lifecycle.finish(first))
    }

    func testStaleCompletionCannotFinishAnotherSession() throws {
        let lifecycle = DictationLifecycle()
        let first = try XCTUnwrap(lifecycle.start())
        XCTAssertEqual(lifecycle.beginTranscription(), first)
        XCTAssertTrue(lifecycle.finish(first))
        let second = try XCTUnwrap(lifecycle.start())
        XCTAssertEqual(lifecycle.beginTranscription(), second)

        XCTAssertFalse(lifecycle.finish(first))
        XCTAssertTrue(lifecycle.isTranscribing)
        XCTAssertTrue(lifecycle.finish(second))
    }

    func testCancelOnlyAppliesWhileRecording() throws {
        let lifecycle = DictationLifecycle()
        XCTAssertFalse(lifecycle.cancelRecording())
        _ = try XCTUnwrap(lifecycle.start())
        XCTAssertTrue(lifecycle.cancelRecording())
        XCTAssertFalse(lifecycle.cancelRecording())
        XCTAssertNotNil(lifecycle.start())
    }

    func testFailedStartReturnsLifecycleToIdle() throws {
        let lifecycle = DictationLifecycle()
        let id = try XCTUnwrap(lifecycle.start())
        lifecycle.failStart(id)
        XCTAssertNotNil(lifecycle.start())
    }

    func testCaptureQualityRejectsOnlyShortOrNearSilentAudio() {
        XCTAssertEqual(
            CaptureQuality.rejection(duration: 0.1, rms: 0.01),
            .tooShort
        )
        XCTAssertEqual(
            CaptureQuality.rejection(duration: 1, rms: 0.0001),
            .tooQuiet
        )
        XCTAssertNil(CaptureQuality.rejection(duration: 0.7, rms: 0.003))
        XCTAssertNil(CaptureQuality.rejection(duration: 0.1, rms: 0, enabled: false))
    }

    func testAudioGateDebugFlagParses() throws {
        let run = try XCTUnwrap(try Run.parseAsRoot(["--no-audio-gate"]) as? Run)
        XCTAssertTrue(run.noAudioGate)
    }
}

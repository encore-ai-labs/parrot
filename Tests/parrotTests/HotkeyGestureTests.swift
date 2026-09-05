import XCTest

@testable import parrot

final class HotkeyGestureTests: XCTestCase {
    func testHeldPressStopsImmediatelyOnRelease() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.4)

        XCTAssertEqual(gesture.handle(.hotkeyPressed, at: 1.0), [.startRecording])
        XCTAssertEqual(gesture.handle(.hotkeyReleased, at: 1.5), [.stopRecording])
    }

    func testQuickSingleTapStopsAfterDoubleTapWindow() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.4)

        XCTAssertEqual(gesture.handle(.hotkeyPressed, at: 1.0), [.startRecording])
        let releaseEffects = gesture.handle(.hotkeyReleased, at: 1.1)
        XCTAssertEqual(releaseEffects.count, 1)
        guard case .scheduleTimeout(let delay) = releaseEffects.first else {
            return XCTFail("a quick release should schedule the single-tap stop")
        }
        XCTAssertEqual(delay, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(
            gesture.handle(.timeout, at: 1.4),
            [.cancelTimeout, .stopRecording]
        )
    }

    func testDoubleTapLatchesUntilSelectedHotkeyIsPressed() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.4)

        XCTAssertEqual(gesture.handle(.hotkeyPressed, at: 1.0), [.startRecording])
        _ = gesture.handle(.hotkeyReleased, at: 1.1)
        XCTAssertEqual(
            gesture.handle(.hotkeyPressed, at: 1.25),
            [.cancelTimeout]
        )
        XCTAssertEqual(gesture.handle(.hotkeyReleased, at: 1.3), [.setLatched(true)])
        XCTAssertEqual(
            gesture.handle(.hotkeyPressed, at: 3.0),
            [.setLatched(false), .stopRecording]
        )
    }

    func testDoubleTapDoesNotRequireAnArtificiallyShortFirstPress() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.55)

        XCTAssertEqual(gesture.handle(.hotkeyPressed, at: 1.0), [.startRecording])
        let releaseEffects = gesture.handle(.hotkeyReleased, at: 1.30)
        XCTAssertEqual(releaseEffects.count, 1)
        XCTAssertEqual(gesture.handle(.hotkeyPressed, at: 1.42), [.cancelTimeout])
        XCTAssertEqual(gesture.handle(.hotkeyReleased, at: 1.48), [.setLatched(true)])
        XCTAssertEqual(
            gesture.handle(.hotkeyPressed, at: 3.0),
            [.setLatched(false), .stopRecording]
        )
    }

    func testHotkeyCanAlsoStopLatchedRecording() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.4)

        _ = gesture.handle(.hotkeyPressed, at: 1.0)
        _ = gesture.handle(.hotkeyReleased, at: 1.1)
        _ = gesture.handle(.hotkeyPressed, at: 1.2)
        _ = gesture.handle(.hotkeyReleased, at: 1.3)

        XCTAssertEqual(
            gesture.handle(.hotkeyPressed, at: 2.0),
            [.setLatched(false), .stopRecording]
        )
        XCTAssertEqual(gesture.handle(.hotkeyReleased, at: 2.1), [])
    }

    func testLateSecondPressStartsANewRecording() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.4)

        _ = gesture.handle(.hotkeyPressed, at: 1.0)
        _ = gesture.handle(.hotkeyReleased, at: 1.1)
        XCTAssertEqual(
            gesture.handle(.hotkeyPressed, at: 1.5),
            [.cancelTimeout, .stopRecording, .startRecording]
        )
    }

    func testEscapeCancelsAHeldRecording() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.4)

        _ = gesture.handle(.hotkeyPressed, at: 1.0)
        XCTAssertEqual(
            gesture.handle(.cancelKeyPressed, at: 1.2),
            [.cancelRecording]
        )
        XCTAssertEqual(gesture.handle(.hotkeyReleased, at: 1.3), [])
    }

    func testEscapeCancelsWhileWaitingForSecondTap() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.4)

        _ = gesture.handle(.hotkeyPressed, at: 1.0)
        _ = gesture.handle(.hotkeyReleased, at: 1.1)
        XCTAssertEqual(
            gesture.handle(.cancelKeyPressed, at: 1.2),
            [.cancelTimeout, .cancelRecording]
        )
        XCTAssertEqual(gesture.handle(.timeout, at: 1.4), [])
    }

    func testEscapeCancelsLatchedRecordingInsteadOfTranscribing() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.4)

        _ = gesture.handle(.hotkeyPressed, at: 1.0)
        _ = gesture.handle(.hotkeyReleased, at: 1.1)
        _ = gesture.handle(.hotkeyPressed, at: 1.2)
        _ = gesture.handle(.hotkeyReleased, at: 1.3)

        XCTAssertEqual(
            gesture.handle(.cancelKeyPressed, at: 2.0),
            [.setLatched(false), .cancelRecording]
        )
    }
}

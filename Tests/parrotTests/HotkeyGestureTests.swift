import XCTest

@testable import parrot

final class HotkeyGestureTests: XCTestCase {
    func testHeldPressStopsImmediatelyOnRelease() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.4)

        XCTAssertEqual(
            gesture.handle(.hotkeyPressed(source: "fn"), at: 1.0),
            [.startRecording(source: "fn")]
        )
        XCTAssertEqual(gesture.handle(.hotkeyReleased(source: "fn"), at: 1.5), [.stopRecording])
    }

    func testQuickSingleTapStopsAfterDoubleTapWindow() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.4)

        XCTAssertEqual(
            gesture.handle(.hotkeyPressed(source: "fn"), at: 1.0),
            [.startRecording(source: "fn")]
        )
        let releaseEffects = gesture.handle(.hotkeyReleased(source: "fn"), at: 1.1)
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

        XCTAssertEqual(
            gesture.handle(.hotkeyPressed(source: "fn"), at: 1.0),
            [.startRecording(source: "fn")]
        )
        _ = gesture.handle(.hotkeyReleased(source: "fn"), at: 1.1)
        XCTAssertEqual(
            gesture.handle(.hotkeyPressed(source: "fn"), at: 1.25),
            [.cancelTimeout]
        )
        XCTAssertEqual(
            gesture.handle(.hotkeyReleased(source: "fn"), at: 1.3),
            [.setLatched(true, source: "fn")]
        )
        XCTAssertEqual(
            gesture.handle(.hotkeyPressed(source: "fn"), at: 3.0),
            [.setLatched(false, source: "fn"), .stopRecording]
        )
    }

    func testDoubleTapDoesNotRequireAnArtificiallyShortFirstPress() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.55)

        XCTAssertEqual(
            gesture.handle(.hotkeyPressed(source: "fn"), at: 1.0),
            [.startRecording(source: "fn")]
        )
        let releaseEffects = gesture.handle(.hotkeyReleased(source: "fn"), at: 1.30)
        XCTAssertEqual(releaseEffects.count, 1)
        XCTAssertEqual(
            gesture.handle(.hotkeyPressed(source: "fn"), at: 1.42),
            [.cancelTimeout]
        )
        XCTAssertEqual(
            gesture.handle(.hotkeyReleased(source: "fn"), at: 1.48),
            [.setLatched(true, source: "fn")]
        )
        XCTAssertEqual(
            gesture.handle(.hotkeyPressed(source: "fn"), at: 3.0),
            [.setLatched(false, source: "fn"), .stopRecording]
        )
    }

    func testHotkeyCanAlsoStopLatchedRecording() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.4)

        _ = gesture.handle(.hotkeyPressed(source: "fn"), at: 1.0)
        _ = gesture.handle(.hotkeyReleased(source: "fn"), at: 1.1)
        _ = gesture.handle(.hotkeyPressed(source: "fn"), at: 1.2)
        _ = gesture.handle(.hotkeyReleased(source: "fn"), at: 1.3)

        XCTAssertEqual(
            gesture.handle(.hotkeyPressed(source: "fn"), at: 2.0),
            [.setLatched(false, source: "fn"), .stopRecording]
        )
        XCTAssertEqual(gesture.handle(.hotkeyReleased(source: "fn"), at: 2.1), [])
    }

    func testLateSecondPressStartsANewRecording() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.4)

        _ = gesture.handle(.hotkeyPressed(source: "fn"), at: 1.0)
        _ = gesture.handle(.hotkeyReleased(source: "fn"), at: 1.1)
        XCTAssertEqual(
            gesture.handle(.hotkeyPressed(source: "fn"), at: 1.5),
            [.cancelTimeout, .stopRecording, .startRecording(source: "fn")]
        )
    }

    func testEscapeCancelsAHeldRecording() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.4)

        _ = gesture.handle(.hotkeyPressed(source: "fn"), at: 1.0)
        XCTAssertEqual(
            gesture.handle(.cancelKeyPressed, at: 1.2),
            [.cancelRecording]
        )
        XCTAssertEqual(gesture.handle(.hotkeyReleased(source: "fn"), at: 1.3), [])
    }

    func testEscapeCancelsWhileWaitingForSecondTap() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.4)

        _ = gesture.handle(.hotkeyPressed(source: "fn"), at: 1.0)
        _ = gesture.handle(.hotkeyReleased(source: "fn"), at: 1.1)
        XCTAssertEqual(
            gesture.handle(.cancelKeyPressed, at: 1.2),
            [.cancelTimeout, .cancelRecording]
        )
        XCTAssertEqual(gesture.handle(.timeout, at: 1.4), [])
    }

    func testEscapeCancelsLatchedRecordingInsteadOfTranscribing() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.4)

        _ = gesture.handle(.hotkeyPressed(source: "fn"), at: 1.0)
        _ = gesture.handle(.hotkeyReleased(source: "fn"), at: 1.1)
        _ = gesture.handle(.hotkeyPressed(source: "fn"), at: 1.2)
        _ = gesture.handle(.hotkeyReleased(source: "fn"), at: 1.3)

        XCTAssertEqual(
            gesture.handle(.cancelKeyPressed, at: 2.0),
            [.setLatched(false, source: "fn"), .cancelRecording]
        )
    }

    func testOnlyTheInitiatingHotkeyCanCompleteOrStopALatchedRecording() {
        var gesture = HotkeyGesture(doubleTapInterval: 0.4)

        XCTAssertEqual(
            gesture.handle(.hotkeyPressed(source: "right-option"), at: 1.0),
            [.startRecording(source: "right-option")]
        )
        XCTAssertEqual(
            gesture.handle(.hotkeyReleased(source: "fn"), at: 1.05),
            []
        )
        _ = gesture.handle(.hotkeyReleased(source: "right-option"), at: 1.1)
        XCTAssertEqual(gesture.handle(.hotkeyPressed(source: "fn"), at: 1.2), [])
        XCTAssertEqual(gesture.handle(.hotkeyReleased(source: "fn"), at: 1.25), [])
        XCTAssertEqual(
            gesture.handle(.hotkeyPressed(source: "right-option"), at: 1.3),
            [.cancelTimeout]
        )
        XCTAssertEqual(
            gesture.handle(.hotkeyReleased(source: "right-option"), at: 1.35),
            [.setLatched(true, source: "right-option")]
        )
        XCTAssertEqual(gesture.handle(.hotkeyPressed(source: "fn"), at: 2.0), [])
        XCTAssertEqual(gesture.handle(.hotkeyReleased(source: "fn"), at: 2.1), [])
        XCTAssertEqual(
            gesture.handle(.hotkeyPressed(source: "right-option"), at: 2.2),
            [.setLatched(false, source: "right-option"), .stopRecording]
        )
    }
}

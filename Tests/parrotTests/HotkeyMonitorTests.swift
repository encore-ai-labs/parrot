import CoreGraphics
import XCTest

@testable import parrot

final class HotkeyMonitorTests: XCTestCase {
    func testOrdinaryKeysPassThroughWhileRecordingIsLocked() throws {
        let monitor = HotkeyMonitor(hotkey: .default)

        XCTAssertFalse(try monitor.handleExitKey(
            type: .keyDown,
            event: keyboardEvent(keyCode: 36) // Return
        ))
        XCTAssertFalse(try monitor.handleExitKey(
            type: .keyDown,
            event: keyboardEvent(keyCode: 0) // A
        ))
    }

    func testSelectedHotkeyCompanionEventStaysWithPrimaryMonitor() throws {
        let monitor = HotkeyMonitor(hotkey: .default)

        XCTAssertFalse(try monitor.handleExitKey(
            type: .keyDown,
            event: keyboardEvent(keyCode: 63) // Fn
        ))
    }

    func testEscapeDownAndMatchingUpAreConsumed() throws {
        let monitor = HotkeyMonitor(hotkey: .default)

        XCTAssertTrue(try monitor.handleExitKey(
            type: .keyDown,
            event: keyboardEvent(keyCode: 53)
        ))
        XCTAssertTrue(try monitor.handleExitKey(
            type: .keyUp,
            event: keyboardEvent(keyCode: 53)
        ))
    }

    private func keyboardEvent(keyCode: CGKeyCode) throws -> CGEvent {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: true
        ) else {
            throw XCTSkip("CoreGraphics could not create a keyboard event")
        }
        return event
    }
}

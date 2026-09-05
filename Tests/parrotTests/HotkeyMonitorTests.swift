import CoreGraphics
import XCTest

@testable import parrot

final class HotkeyMonitorTests: XCTestCase {
    func testSingleMonitorRoutesBothConfiguredHotkeysWithTheirSources() throws {
        let monitor = HotkeyMonitor(hotkeys: [
            try XCTUnwrap(Hotkey.parse("right-option")),
            try XCTUnwrap(Hotkey.parse("end")),
        ])
        let optionDown = try keyboardEvent(keyCode: 61)
        optionDown.flags = .maskAlternate
        let optionUp = try keyboardEvent(keyCode: 61)
        optionUp.flags = []

        XCTAssertEqual(
            monitor.route(type: .flagsChanged, event: optionDown),
            [.pressed(source: "right-option")]
        )
        XCTAssertEqual(
            monitor.route(type: .flagsChanged, event: optionUp),
            [.released(source: "right-option")]
        )
        XCTAssertEqual(
            monitor.route(type: .keyDown, event: try keyboardEvent(keyCode: 119)),
            [.pressed(source: "end")]
        )
        XCTAssertEqual(
            monitor.route(type: .keyUp, event: try keyboardEvent(keyCode: 119)),
            [.released(source: "end")]
        )
    }

    func testMultiHotkeyMonitorSwallowsOnlyConfiguredPlainKeys() throws {
        let monitor = HotkeyMonitor(hotkeys: [
            .default,
            try XCTUnwrap(Hotkey.parse("end")),
        ])

        XCTAssertTrue(monitor.shouldSwallow(
            type: .keyDown,
            event: try keyboardEvent(keyCode: 119)
        ))
        XCTAssertFalse(monitor.shouldSwallow(
            type: .keyDown,
            event: try keyboardEvent(keyCode: 36)
        ))
        XCTAssertFalse(monitor.shouldSwallow(
            type: .flagsChanged,
            event: try keyboardEvent(keyCode: 63)
        ))
        XCTAssertTrue(monitor.shouldRoute(
            type: .keyDown,
            event: try keyboardEvent(keyCode: 119)
        ))
        XCTAssertFalse(monitor.shouldRoute(
            type: .keyDown,
            event: try keyboardEvent(keyCode: 0)
        ))
        XCTAssertTrue(monitor.shouldRoute(
            type: .flagsChanged,
            event: try keyboardEvent(keyCode: 63)
        ))
    }

    func testTwoHotkeyRoutingCostStaysNegligible() throws {
        let monitor = HotkeyMonitor(hotkeys: [
            .default,
            try XCTUnwrap(Hotkey.parse("right-option")),
        ])
        let ordinaryKey = try keyboardEvent(keyCode: 0)

        measure {
            for _ in 0..<10_000 {
                _ = monitor.shouldRoute(type: .keyDown, event: ordinaryKey)
            }
        }
    }

    func testTapDisableResetsPressedStateAndSignalsWhetherCaptureWasInterrupted() throws {
        let monitor = HotkeyMonitor(hotkeys: [
            .default,
            try XCTUnwrap(Hotkey.parse("end")),
        ])

        XCTAssertFalse(monitor.resetPressedStateAfterTapDisable())
        XCTAssertEqual(
            monitor.route(type: .keyDown, event: try keyboardEvent(keyCode: 119)),
            [.pressed(source: "end")]
        )
        XCTAssertTrue(monitor.resetPressedStateAfterTapDisable())
        XCTAssertEqual(
            monitor.route(type: .keyUp, event: try keyboardEvent(keyCode: 119)),
            []
        )
        XCTAssertEqual(
            monitor.route(type: .keyDown, event: try keyboardEvent(keyCode: 119)),
            [.pressed(source: "end")]
        )
    }

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

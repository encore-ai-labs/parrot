import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Watches a single push-to-talk key (default: Fn) and emits press/release
/// edges. Requires Accessibility permission. If the tap fails to register,
/// callers will see an error from `start()`.
final class HotkeyMonitor {
    enum Event { case pressed, released, exitKeyPressed, cancelKeyPressed }
    enum HotkeyError: Error { case tapCreateFailed }

    private let hotkey: Hotkey
    private let debug: Bool
    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var exitKeyTap: CFMachPort?
    private var exitKeyRunLoopSource: CFRunLoopSource?
    private var swallowedExitKeyCode: Int64?
    private var exitOnAnyKey = false
    private var isPressed = false

    init(hotkey: Hotkey = .default, debug: Bool = false) {
        self.hotkey = hotkey
        self.debug = debug
    }

    func start(onEvent: @escaping (Event) -> Void) throws {
        self.onEvent = onEvent

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if !trusted {
            FileHandle.standardError.write(Data(
                "accessibility not granted — system prompt opened. Grant access, then quit and relaunch parrot.\n".utf8
            ))
            throw HotkeyError.tapCreateFailed
        }

        // Only subscribe to what this hotkey actually needs. A modifier is
        // reported entirely through flagsChanged, so staying off keyDown/keyUp
        // means we aren't copying every keystroke on the system — including
        // ones typed into password fields.
        var mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        if hotkey.needsKeyEvents || debug {
            mask |= (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // A plain key (End, F13, …) does something in the focused app, so we
        // need `.defaultTap` to be able to swallow it. Modifiers are inert on
        // their own, so they use `.listenOnly` — which is safer, and means we
        // can never accidentally eat someone's Option key.
        let options: CGEventTapOptions = hotkey.needsKeyEvents ? .defaultTap : .listenOnly

        // .cgSessionEventTap is the right level for an accessibility-granted
        // user process (.cghidEventTap requires root).
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: options,
                eventsOfInterest: mask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        else {
            throw HotkeyError.tapCreateFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    /// Re-arm after macOS disabled the tap. Called from the tap thread.
    fileprivate func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        // A stuck-down state would otherwise swallow the next press edge.
        isPressed = false
        FileHandle.standardError.write(Data("hotkey tap was disabled by the system — re-enabled\n".utf8))
    }

    func stop() {
        stopExitKeyMonitoring()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        onEvent = nil
    }

    /// While recording, consume Escape as a cancel key. In latched mode, also
    /// consume the first ordinary keypress so Return does not submit before the
    /// transcript is inserted. The tap exists only while the mic is recording.
    @discardableResult
    func startExitKeyMonitoring(exitOnAnyKey: Bool) -> Bool {
        self.exitOnAnyKey = exitOnAnyKey
        guard exitKeyTap == nil else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: exitKeyCallback,
            userInfo: userInfo
        ) else {
            FileHandle.standardError.write(Data(
                "failed to register the recording exit-key tap\n".utf8
            ))
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        exitKeyTap = tap
        exitKeyRunLoopSource = source
        swallowedExitKeyCode = nil
        return true
    }

    func stopExitKeyMonitoring() {
        // When an exit key is currently down, keep the tap just long enough to
        // consume its matching key-up as well.
        guard swallowedExitKeyCode == nil else { return }
        if let exitKeyTap {
            CGEvent.tapEnable(tap: exitKeyTap, enable: false)
        }
        if let source = exitKeyRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        exitKeyTap = nil
        exitKeyRunLoopSource = nil
        exitOnAnyKey = false
    }

    fileprivate func reenableExitKeyTap() {
        guard let exitKeyTap else { return }
        CGEvent.tapEnable(tap: exitKeyTap, enable: true)
    }

    fileprivate func handleExitKey(type: CGEventType, event: CGEvent) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)

        // The activation key itself remains under the primary monitor's
        // control, allowing one more press to end latched recording too.
        if keycode == hotkey.keyEventCode {
            return false
        }

        if let swallowedExitKeyCode {
            guard keycode == swallowedExitKeyCode else { return false }
            if type == .keyUp {
                self.swallowedExitKeyCode = nil
                DispatchQueue.main.async { [weak self] in
                    self?.stopExitKeyMonitoring()
                }
            }
            return true
        }

        let isEscape = keycode == 53
        guard isEscape || exitOnAnyKey else { return false }
        guard type == .keyDown else { return false }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
        if debug {
            FileHandle.standardError.write(Data(
                "  [debug] latched exit keycode=\(keycode)\n".utf8
            ))
        }
        swallowedExitKeyCode = keycode
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(isEscape ? .cancelKeyPressed : .exitKeyPressed)
        }
        return true
    }

    /// Whether this event should be withheld from the focused app. Decided
    /// synchronously on the tap thread — the callback has to return the verdict
    /// before it can hand off to the main queue.
    fileprivate func shouldSwallow(type: CGEventType, event: CGEvent) -> Bool {
        guard case .key(_, let wanted) = hotkey else { return false }
        guard type == .keyDown || type == .keyUp else { return false }
        return event.getIntegerValueField(.keyboardEventKeycode) == wanted
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if debug {
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            FileHandle.standardError.write(
                Data(
                    "  [debug] type=\(type.rawValue) keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))\n"
                        .utf8
                ))
        }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)

        switch hotkey {
        case .modifier(_, let wanted, let flag):
            guard type == .flagsChanged else { return }
            // Left/right pairs share a flag, so the physical keycode is what
            // tells them apart. Keys that exist only once (Fn, Caps Lock) pass
            // nil and match on the flag edge alone.
            if let wanted, keycode != wanted { return }
            let pressed = event.flags.contains(flag)
            guard pressed != isPressed else { return }
            isPressed = pressed
            onEvent?(pressed ? .pressed : .released)

        case .key(_, let wanted):
            guard keycode == wanted else { return }
            switch type {
            case .keyDown:
                // Holding a key auto-repeats; only the first one is a press.
                guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
                guard !isPressed else { return }
                isPressed = true
                onEvent?(.pressed)
            case .keyUp:
                guard isPressed else { return }
                isPressed = false
                onEvent?(.released)
            default:
                return
            }
        }
    }
}

private func exitKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.reenableExitKeyTap()
        return Unmanaged.passUnretained(event)
    }

    return monitor.handleExitKey(type: type, event: event)
        ? nil
        : Unmanaged.passUnretained(event)
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // macOS disables taps on its own schedule. Re-arm immediately —
        // otherwise parrot keeps running, menu bar icon and all, while the
        // hotkey silently stops working.
        monitor.reenable()
        return Unmanaged.passUnretained(event)
    }

    // Must be decided here, synchronously, before we hand off to the main queue.
    let swallow = monitor.shouldSwallow(type: type, event: event)

    let copy = event.copy()
    DispatchQueue.main.async {
        if let copy {
            monitor.handle(type: type, event: copy)
        }
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Watches one or more push-to-talk keys and emits source-labelled edges from
/// a single event tap. Requires Accessibility permission. If the tap fails to
/// register, callers will see an error from `start()`.
final class HotkeyMonitor {
    enum Event: Equatable {
        case pressed(source: String)
        case released(source: String)
        case cancelKeyPressed
    }
    enum HotkeyError: Error { case tapCreateFailed }

    private let hotkeys: [Hotkey]
    private let debug: Bool
    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var exitKeyTap: CFMachPort?
    private var exitKeyRunLoopSource: CFRunLoopSource?
    private var swallowedExitKeyCode: Int64?
    private var pressedHotkeys: Set<String> = []

    init(hotkey: Hotkey = .default, debug: Bool = false) {
        self.hotkeys = [hotkey]
        self.debug = debug
    }

    init(hotkeys: [Hotkey], debug: Bool = false) {
        precondition(!hotkeys.isEmpty, "HotkeyMonitor requires at least one hotkey")
        self.hotkeys = hotkeys
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

        // Only subscribe to what the configured hotkeys actually need. A
        // modifier is reported entirely through flagsChanged, so staying off
        // keyDown/keyUp means we aren't receiving every keystroke on the
        // system — including ones typed into password fields.
        var mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        if hotkeys.contains(where: \.needsKeyEvents) || debug {
            mask |= (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // A plain key (End, F13, …) does something in the focused app, so we
        // need `.defaultTap` to be able to swallow it. Modifiers are inert on
        // their own, so they use `.listenOnly` — which is safer, and means we
        // can never accidentally eat someone's Option key.
        let options: CGEventTapOptions = hotkeys.contains(where: \.needsKeyEvents)
            ? .defaultTap
            : .listenOnly

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
        // If macOS disabled the tap while a key was down, its release may be
        // gone forever. Cancel that partial recording instead of stranding it.
        let interruptedCapture = resetPressedStateAfterTapDisable()
        if interruptedCapture {
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(.cancelKeyPressed)
            }
        }
        FileHandle.standardError.write(Data("hotkey tap was disabled by the system — re-enabled\n".utf8))
    }

    @discardableResult
    func resetPressedStateAfterTapDisable() -> Bool {
        let interruptedCapture = !pressedHotkeys.isEmpty
        pressedHotkeys.removeAll()
        return interruptedCapture
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

    /// While recording, consume Escape as a cancel key. The tap exists only
    /// while the mic is recording; ordinary keystrokes pass through untouched
    /// to the focused application.
    @discardableResult
    func startExitKeyMonitoring() -> Bool {
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
    }

    fileprivate func reenableExitKeyTap() {
        guard let exitKeyTap else { return }
        CGEvent.tapEnable(tap: exitKeyTap, enable: true)
    }

    func handleExitKey(type: CGEventType, event: CGEvent) -> Bool {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)

        // Activation keys remain under the primary event tap's
        // control, allowing one more press to end latched recording too.
        if hotkeys.contains(where: { $0.keyEventCode == keycode }) {
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
        guard isEscape else { return false }
        guard type == .keyDown else { return false }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
        if debug {
            FileHandle.standardError.write(Data(
                "  [debug] recording cancel keycode=\(keycode)\n".utf8
            ))
        }
        swallowedExitKeyCode = keycode
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(.cancelKeyPressed)
        }
        return true
    }

    /// Whether this event should be withheld from the focused app. Decided
    /// synchronously on the tap thread — the callback has to return the verdict
    /// before it can hand off to the main queue.
    func shouldSwallow(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown || type == .keyUp else { return false }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        return hotkeys.contains { hotkey in
            guard case .key(_, let wanted) = hotkey else { return false }
            return keycode == wanted
        }
    }

    /// Even when a plain hotkey requires keyDown/keyUp subscription, ordinary
    /// keystrokes are neither copied nor dispatched onto the main queue.
    func shouldRoute(type: CGEventType, event: CGEvent) -> Bool {
        if debug { return true }
        if type == .flagsChanged {
            return hotkeys.contains { hotkey in
                if case .modifier = hotkey { return true }
                return false
            }
        }
        guard type == .keyDown || type == .keyUp else { return false }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        return hotkeys.contains { hotkey in
            guard case .key(_, let wanted) = hotkey else { return false }
            return keycode == wanted
        }
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
        for routedEvent in route(type: type, event: event) {
            onEvent?(routedEvent)
        }
    }

    /// Convert a CoreGraphics event into source-labelled hotkey edges. Kept
    /// separate from the tap callback so multi-key routing is deterministic
    /// and testable without installing a global event tap.
    func route(type: CGEventType, event: CGEvent) -> [Event] {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        var routedEvents: [Event] = []

        for hotkey in hotkeys {
            switch hotkey {
            case .modifier(_, let wanted, let flag):
                guard type == .flagsChanged else { continue }
                // Left/right pairs share a flag, so the physical keycode is what
                // tells them apart. Keys that exist only once (Fn, Caps Lock) pass
                // nil and match on the flag edge alone.
                if let wanted, keycode != wanted { continue }
                let pressed = event.flags.contains(flag)
                let wasPressed = pressedHotkeys.contains(hotkey.name)
                guard pressed != wasPressed else { continue }
                if pressed {
                    pressedHotkeys.insert(hotkey.name)
                    routedEvents.append(.pressed(source: hotkey.name))
                } else {
                    pressedHotkeys.remove(hotkey.name)
                    routedEvents.append(.released(source: hotkey.name))
                }

            case .key(_, let wanted):
                guard keycode == wanted else { continue }
                switch type {
                case .keyDown:
                    // Holding a key auto-repeats; only the first one is a press.
                    guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
                        continue
                    }
                    guard !pressedHotkeys.contains(hotkey.name) else { continue }
                    pressedHotkeys.insert(hotkey.name)
                    routedEvents.append(.pressed(source: hotkey.name))
                case .keyUp:
                    guard pressedHotkeys.contains(hotkey.name) else { continue }
                    pressedHotkeys.remove(hotkey.name)
                    routedEvents.append(.released(source: hotkey.name))
                default:
                    continue
                }
            }
        }
        return routedEvents
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
    guard monitor.shouldRoute(type: type, event: event) else {
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    let copy = event.copy()
    DispatchQueue.main.async {
        if let copy {
            monitor.handle(type: type, event: copy)
        }
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

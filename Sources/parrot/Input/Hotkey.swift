import CoreGraphics
import Foundation

/// A push-to-talk key.
///
/// Two kinds, because macOS reports them through different event types:
///
/// - `.modifier` — Fn, Option, Command, Control, Shift. Reported as
///   `flagsChanged` edges. These are the good choices: a modifier held on its
///   own does nothing, so the keypress leaking through to the focused app (our
///   tap is `.listenOnly`) is harmless.
/// - `.key` — F13–F20, End, Home, Page Up/Down. Reported as `keyDown`/`keyUp`.
///   Unlike modifiers, these *do* something in the focused app, so when one is
///   chosen the tap switches from `.listenOnly` to `.defaultTap` and swallows
///   that key's events. Otherwise dictating with End would jump your cursor to
///   end-of-line every time.
///
/// `keyCode` is nil for modifiers that exist only once on a keyboard (Fn, Caps
/// Lock); for the left/right pairs it's the physical key's virtual keycode,
/// which is what disambiguates them — `CGEventFlags` alone can't, since both
/// Options set `.maskAlternate`.
enum Hotkey {
    case modifier(name: String, keyCode: Int64?, flag: CGEventFlags)
    case key(name: String, keyCode: Int64)

    static let `default`: Hotkey = .modifier(name: "fn", keyCode: nil, flag: .maskSecondaryFn)

    var name: String {
        switch self {
        case .modifier(let n, _, _), .key(let n, _): return n
        }
    }

    /// True when the tap needs `keyDown`/`keyUp` in its event mask. Modifiers
    /// only need `flagsChanged`, and subscribing to less means we aren't copying
    /// every keystroke on the system.
    var needsKeyEvents: Bool {
        if case .key = self { return true }
        return false
    }

    static let all: [Hotkey] = [
        .modifier(name: "fn", keyCode: nil, flag: .maskSecondaryFn),
        .modifier(name: "right-option", keyCode: 61, flag: .maskAlternate),
        .modifier(name: "left-option", keyCode: 58, flag: .maskAlternate),
        .modifier(name: "right-command", keyCode: 54, flag: .maskCommand),
        .modifier(name: "left-command", keyCode: 55, flag: .maskCommand),
        .modifier(name: "right-control", keyCode: 62, flag: .maskControl),
        .modifier(name: "left-control", keyCode: 59, flag: .maskControl),
        .modifier(name: "right-shift", keyCode: 60, flag: .maskShift),
        .modifier(name: "left-shift", keyCode: 56, flag: .maskShift),
        .modifier(name: "caps-lock", keyCode: nil, flag: .maskAlphaShift),
        .key(name: "f13", keyCode: 105),
        .key(name: "f14", keyCode: 107),
        .key(name: "f15", keyCode: 113),
        .key(name: "f16", keyCode: 106),
        .key(name: "f17", keyCode: 64),
        .key(name: "f18", keyCode: 79),
        .key(name: "f19", keyCode: 80),
        .key(name: "f20", keyCode: 90),
        .key(name: "end", keyCode: 119),
        .key(name: "home", keyCode: 115),
        .key(name: "page-up", keyCode: 116),
        .key(name: "page-down", keyCode: 121),
        .key(name: "forward-delete", keyCode: 117),
    ]

    /// Spellings people reach for that aren't the canonical name.
    private static let aliases: [String: String] = [
        "globe": "fn",
        "right-alt": "right-option", "ralt": "right-option", "ropt": "right-option",
        "left-alt": "left-option", "lalt": "left-option", "lopt": "left-option",
        "right-cmd": "right-command", "rcmd": "right-command",
        "left-cmd": "left-command", "lcmd": "left-command",
        "right-ctrl": "right-control", "rctrl": "right-control",
        "left-ctrl": "left-control", "lctrl": "left-control",
        "capslock": "caps-lock", "caps": "caps-lock",
        "pgup": "page-up", "pageup": "page-up",
        "pgdn": "page-down", "pagedown": "page-down",
        "fwd-delete": "forward-delete", "del": "forward-delete",
    ]

    static func parse(_ raw: String) -> Hotkey? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        s = aliases[s] ?? s

        if let match = all.first(where: { $0.name == s }) { return match }

        // Escape hatch for keyboards with keys we don't have names for.
        // Find the number with `parrot run --debug-hotkey`.
        if s.hasPrefix("keycode:"), let n = Int64(s.dropFirst("keycode:".count)) {
            return .key(name: "keycode:\(n)", keyCode: n)
        }
        return nil
    }

    static var names: [String] { all.map(\.name) }
}

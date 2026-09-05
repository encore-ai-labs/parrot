import AppKit
import ApplicationServices
import Foundation

/// Explicit, local-only context used to bias Whisper recognition for one capture.
/// Off remains the default so Parrot never reads surrounding text unexpectedly.
enum RecognitionContextSource: String, Codable, CaseIterable, Sendable {
    case off
    case selectedText = "selected-text"
    case clipboard
    case both

    static func parse(_ raw: String) -> RecognitionContextSource? {
        switch raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "off", "none": return .off
        case "selected", "selection", "selected-text": return .selectedText
        case "clipboard", "pasteboard": return .clipboard
        case "both": return .both
        default: return nil
        }
    }

    var usesSelectedText: Bool { self == .selectedText || self == .both }
    var usesClipboard: Bool { self == .clipboard || self == .both }
}

/// Pure preparation kept separate from macOS APIs for privacy and bound tests.
enum RecognitionContextBuilder {
    static let maximumCharacters = 2_048

    static func prepare(
        selectedText: String?,
        clipboardText: String?,
        source: RecognitionContextSource
    ) -> String? {
        guard source != .off else { return nil }
        // Reserve the separator when both values are present so the assembled
        // prompt is bounded too, not just each individual source.
        let perSourceLimit = source == .both
            ? (maximumCharacters - 2) / 2
            : maximumCharacters
        var parts: [String] = []

        // Selection is more closely tied to the focused writing task. Put it
        // last so Whisper's suffix-preserving prompt trim favors it over a
        // clipboard value when both sources are enabled.
        if source.usesClipboard,
           let clipboard = normalized(clipboardText, maximumCharacters: perSourceLimit) {
            parts.append(clipboard)
        }
        if source.usesSelectedText,
           let selection = normalized(selectedText, maximumCharacters: perSourceLimit) {
            parts.append(selection)
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ". ")
    }

    private static func normalized(
        _ value: String?,
        maximumCharacters: Int
    ) -> String? {
        guard let value else { return nil }
        let bounded = value.count > maximumCharacters
            ? String(value.suffix(maximumCharacters))
            : value
        let normalized = bounded
            .map { $0.isWhitespace || $0.isASCII && $0.asciiValue.map({ $0 < 0x20 }) == true
                ? " "
                : String($0)
            }
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}

/// Snapshots clipboard content and the focused process immediately on the main
/// actor, then performs the potentially cross-process Accessibility read away
/// from the hotkey/audio path. AX messaging has a short timeout and failures
/// simply yield no context; dictation itself never depends on another app.
enum RecognitionContextCapture {
    @MainActor
    static func start(
        source: RecognitionContextSource
    ) -> Task<String?, Never>? {
        guard source != .off else { return nil }
        let clipboardText = source.usesClipboard
            ? NSPasteboard.general.string(forType: .string)
            : nil
        let processID = source.usesSelectedText
            ? NSWorkspace.shared.frontmostApplication?.processIdentifier
            : nil

        return Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil }
            let selectedText = source.usesSelectedText
                ? readSelectedText(processID: processID)
                : nil
            guard !Task.isCancelled else { return nil }
            return RecognitionContextBuilder.prepare(
                selectedText: selectedText,
                clipboardText: clipboardText,
                source: source
            )
        }
    }

    private nonisolated static func readSelectedText(processID: pid_t?) -> String? {
        guard let processID else { return nil }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.05)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue
        else { return nil }

        let focusedElement = focusedValue as! AXUIElement
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success
        else { return nil }
        return selectedValue as? String
    }
}

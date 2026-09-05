import Foundation

/// Selects the processing mode for one live capture from an explicit leading
/// phrase. This is intentionally prefix-only: an ordinary sentence that ends
/// with “note mode” must remain ordinary dictated text.
enum SpokenModeTrigger {
    struct Selection: Equatable {
        let text: String
        let mode: DictationMode
        let wasTriggered: Bool
    }

    private static let phrasePattern =
        #"(?:notes?[ \t\r\n]+mode|dictation[ \t\r\n]+mode)"#
    private static let separatorPattern =
        #"(?:[ \t\r\n]*[,:;.!?][ \t\r\n]*|[ \t\r\n]+|\z)"#

    private static let triggerRegex = try! NSRegularExpression(
        pattern: #"\A[ \t\r\n]*(\#(phrasePattern))\#(separatorPattern)"#,
        options: .caseInsensitive
    )
    private static let literalRegex = try! NSRegularExpression(
        pattern: #"\A[ \t\r\n]*literal[ \t\r\n]+(?=\#(phrasePattern)\#(separatorPattern))"#,
        options: .caseInsensitive
    )

    static func resolve(_ text: String, fallbackMode: DictationMode) -> Selection {
        guard !text.isEmpty else {
            return Selection(text: text, mode: fallbackMode, wasTriggered: false)
        }

        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)

        // Match literal first so escaping is valid in both fallback modes.
        if let match = literalRegex.firstMatch(in: text, range: fullRange) {
            return Selection(
                text: source.substring(from: NSMaxRange(match.range)),
                mode: fallbackMode,
                wasTriggered: false
            )
        }

        guard let match = triggerRegex.firstMatch(in: text, range: fullRange) else {
            return Selection(text: text, mode: fallbackMode, wasTriggered: false)
        }
        let phrase = source.substring(with: match.range(at: 1))
        let normalized = phrase
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
        let selectedMode: DictationMode = normalized.hasPrefix("dictation")
            ? .dictation
            : .notes
        return Selection(
            text: source.substring(from: NSMaxRange(match.range)),
            mode: selectedMode,
            wasTriggered: true
        )
    }
}

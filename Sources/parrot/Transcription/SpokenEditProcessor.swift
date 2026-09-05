import Foundation

/// Deterministic, local backtracking for note-mode dictation.
///
/// Commands remove only a mechanically defined suffix. They never infer what
/// the speaker meant, inspect another application, or invoke a language model.
/// Prefix a command with “literal” to keep the spoken words.
enum SpokenEditProcessor {
    private enum Command {
        case deletePhrase
        case deleteWord
        case deleteSentence
        case undo
    }

    private struct UndoAction {
        let prefixUTF16Length: Int
        let removedSuffix: String
    }

    private static let phraseCommands: [String: Command] = [
        "scratch that": .deletePhrase,
        "delete that": .deletePhrase,
        "never mind": .deletePhrase,
        "delete last word": .deleteWord,
        "delete previous word": .deleteWord,
        "delete last sentence": .deleteSentence,
        "delete previous sentence": .deleteSentence,
        "undo that": .undo,
    ]

    private static let alternatives = phraseCommands.keys
        .sorted { $0.count > $1.count }
        .map(NSRegularExpression.escapedPattern)
        .joined(separator: "|")

    private static let boundary = #"[\p{L}\p{N}_'’\-‐‑–—./@#]"#
    private static let commandRegex = try! NSRegularExpression(
        pattern: #"(?<!\#(boundary))(?:(literal)[ \t]+)?(\#(alternatives))(?:[ \t]*([,.!?;:]))?(?!\#(boundary))"#,
        options: .caseInsensitive
    )

    private static let lastWordRegex = try! NSRegularExpression(
        pattern: #"\S+[ \t\r\n]*$"#
    )

    private static let markdownPrefixRegex = try! NSRegularExpression(
        pattern: #"^(?:- \[[ xX]\]|#{1,6}|\d+\.|[-*+])[ \t]+"#
    )

    private static let spacesRegex = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    private static let beforePunctuationRegex = try! NSRegularExpression(
        pattern: #"[ \t]+([,.!?;:])"#
    )
    private static let lineEdgesRegex = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]+|[ \t]+$"#
    )

    static func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let source = text as NSString
        let matches = commandRegex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { return text }

        var output = ""
        var cursor = 0
        var undoActions: [UndoAction] = []
        for match in matches {
            output += source.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))
            let phrase = source.substring(with: match.range(at: 2))
            let punctuationRange = match.range(at: 3)
            let punctuation = punctuationRange.location == NSNotFound
                ? ""
                : source.substring(with: punctuationRange)

            if match.range(at: 1).location != NSNotFound {
                output += phrase + punctuation
            } else if let command = phraseCommands[phrase.lowercased()] {
                switch command {
                case .deletePhrase:
                    record(
                        deletionFrom: &output,
                        startingAt: phraseStart(in: output),
                        undoActions: &undoActions
                    )
                case .deleteWord:
                    record(
                        deletionFrom: &output,
                        startingAt: lastWordStart(in: output),
                        undoActions: &undoActions
                    )
                case .deleteSentence:
                    record(
                        deletionFrom: &output,
                        startingAt: sentenceStart(in: output),
                        undoActions: &undoActions
                    )
                case .undo:
                    undo(&output, actions: &undoActions)
                }
            }
            cursor = NSMaxRange(match.range)
        }
        output += source.substring(from: cursor)
        return tidy(output)
    }

    private static func record(
        deletionFrom text: inout String,
        startingAt location: Int?,
        undoActions: inout [UndoAction]
    ) {
        guard let location else { return }
        let source = text as NSString
        let clamped = min(max(0, location), source.length)
        guard clamped < source.length else { return }
        let removed = source.substring(from: clamped)
        text = source.substring(to: clamped)
        undoActions.append(UndoAction(
            prefixUTF16Length: clamped,
            removedSuffix: removed
        ))
        // An utterance should never need this many edits, and bounding the
        // stack keeps adversarial input from retaining repeated text forever.
        if undoActions.count > 32 { undoActions.removeFirst() }
    }

    private static func undo(_ text: inout String, actions: inout [UndoAction]) {
        guard let action = actions.popLast() else { return }
        let source = text as NSString
        let prefixLength = min(action.prefixUTF16Length, source.length)
        text = source.substring(to: prefixLength) + action.removedSuffix
    }

    /// “Scratch that” removes the current clause. If recognition has already
    /// punctuated that clause, the punctuation is treated as part of it and
    /// the previous boundary is used instead.
    private static func phraseStart(in text: String) -> Int? {
        suffixStart(
            in: text,
            boundaries: [10, 13, 33, 44, 46, 58, 59, 63, 0x2014], // \n \r ! , . : ; ? —
            terminalPunctuation: [33, 44, 46, 58, 59, 63, 0x2014]
        )
    }

    private static func sentenceStart(in text: String) -> Int? {
        suffixStart(
            in: text,
            boundaries: [10, 13, 33, 46, 63], // \n \r ! . ?
            terminalPunctuation: [33, 46, 63]
        )
    }

    private static func suffixStart(
        in text: String,
        boundaries: Set<unichar>,
        terminalPunctuation: Set<unichar>
    ) -> Int? {
        let source = text as NSString
        var contentEnd = source.length
        while contentEnd > 0, isWhitespace(source.character(at: contentEnd - 1)) {
            contentEnd -= 1
        }
        guard contentEnd > 0 else { return nil }

        var searchEnd = contentEnd
        if terminalPunctuation.contains(source.character(at: searchEnd - 1)) {
            searchEnd -= 1
            while searchEnd > 0, isHorizontalWhitespace(source.character(at: searchEnd - 1)) {
                searchEnd -= 1
            }
        }

        var start = 0
        if searchEnd > 0 {
            for location in stride(from: searchEnd - 1, through: 0, by: -1) {
                if isBoundary(
                    source.character(at: location),
                    at: location,
                    in: source,
                    allowed: boundaries
                ) {
                    start = location + 1
                    break
                }
            }
        }
        start = max(start, markdownPrefixEnd(in: source, contentEnd: contentEnd))
        return start
    }

    private static func markdownPrefixEnd(in source: NSString, contentEnd: Int) -> Int {
        var lineStart = 0
        if contentEnd > 0 {
            for location in stride(from: contentEnd - 1, through: 0, by: -1) {
                let character = source.character(at: location)
                if character == 10 || character == 13 {
                    lineStart = location + 1
                    break
                }
            }
        }
        let line = source.substring(with: NSRange(
            location: lineStart,
            length: max(0, contentEnd - lineStart)
        ))
        let match = markdownPrefixRegex.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        )
        return match.map { lineStart + NSMaxRange($0.range) } ?? lineStart
    }

    private static func lastWordStart(in text: String) -> Int? {
        let source = text as NSString
        return lastWordRegex.firstMatch(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )?.range.location
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 9 || character == 10 || character == 13 || character == 32
    }

    private static func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == 9 || character == 32
    }

    private static func isBoundary(
        _ character: unichar,
        at location: Int,
        in source: NSString,
        allowed: Set<unichar>
    ) -> Bool {
        guard allowed.contains(character) else { return false }
        if character == 10 || character == 13 || character == 0x2014 { return true }

        let previous = location > 0 ? source.character(at: location - 1) : nil
        let next = location + 1 < source.length ? source.character(at: location + 1) : nil
        if [44, 46, 58].contains(character), // comma, period, colon
           let previous, let next,
           isASCIIDigit(previous), isASCIIDigit(next) {
            return false
        }
        if [33, 46, 63].contains(character), // ! . ?
           let next, !isWhitespace(next) {
            return false
        }
        return true
    }

    private static func isASCIIDigit(_ character: unichar) -> Bool {
        (48...57).contains(character)
    }

    private static func tidy(_ text: String) -> String {
        var output = replace(spacesRegex, in: text, with: " ")
        output = replace(beforePunctuationRegex, in: output, with: "$1")
        output = replace(lineEdgesRegex, in: output, with: "")
        output = output.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(
        _ regex: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template
        )
    }
}

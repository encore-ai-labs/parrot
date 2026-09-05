import Foundation

/// Deterministic spoken-command formatting for opt-in Markdown note capture.
/// No text is inferred or rewritten: only explicit, documented command phrases
/// are transformed. Prefix any command with "literal" to dictate its words.
enum NoteFormatter {
    static let promptTerms = [
        "new paragraph", "new line", "bullet point", "next bullet",
        "numbered item", "new task", "heading one", "heading two", "heading three",
    ]

    private struct Command {
        let phrases: [String]
        let marker: String
    }

    private static let commands = [
        Command(phrases: ["new paragraph"], marker: "\u{E000}"),
        Command(phrases: ["new line"], marker: "\u{E001}"),
        Command(
            phrases: [
                "bullet point", "bullet points", "new bullet", "next bullet", "next bullet point",
            ],
            marker: "\u{E002}"
        ),
        Command(
            phrases: ["numbered item", "new numbered item", "next numbered item"],
            marker: "\u{E003}"
        ),
        Command(phrases: ["checkbox", "check box", "new task", "task item"], marker: "\u{E004}"),
        Command(phrases: ["heading one", "heading won", "heading 1"], marker: "\u{E005}"),
        Command(
            phrases: ["heading two", "heading to", "heading too", "heading 2", "heading"],
            marker: "\u{E006}"
        ),
        Command(phrases: ["heading three", "heading tree", "heading 3"], marker: "\u{E007}"),
        Command(phrases: ["full stop", "period"], marker: "\u{E008}"),
        Command(phrases: ["comma"], marker: "\u{E009}"),
        Command(phrases: ["colon"], marker: "\u{E00A}"),
        Command(phrases: ["semicolon"], marker: "\u{E00B}"),
        Command(phrases: ["question mark"], marker: "\u{E00C}"),
        Command(phrases: ["exclamation mark", "exclamation point"], marker: "\u{E00D}"),
        Command(phrases: ["em dash"], marker: "\u{E00E}"),
    ]

    private static let phraseToMarker: [String: String] = {
        Dictionary(uniqueKeysWithValues: commands.flatMap { command in
            command.phrases.map { ($0, command.marker) }
        })
    }()

    private static let alternatives: String = {
        phraseToMarker.keys
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern)
            .joined(separator: "|")
    }()

    private static let commandRegex = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}_])(?:\(alternatives))(?:[.,!?;:])?(?![\\p{L}\\p{N}_])",
        options: .caseInsensitive
    )

    private static let literalRegex = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}_])literal[ \\t]+(\(alternatives))(?![\\p{L}\\p{N}_])",
        options: .caseInsensitive
    )

    static func format(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var output = protectLiteralCommands(in: text)
        output = replaceCommands(in: output)
        output.text = renderMarkers(in: output.text)
        for literal in output.literals {
            output.text = output.text.replacingOccurrences(of: literal.marker, with: literal.phrase)
        }
        return tidy(output.text)
    }

    private struct ProtectedText {
        var text: String
        let literals: [(marker: String, phrase: String)]
    }

    private static func protectLiteralCommands(in text: String) -> ProtectedText {
        let source = text as NSString
        let matches = literalRegex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )
        var output = text
        var literals: [(marker: String, phrase: String)] = []
        for (index, match) in matches.enumerated().reversed() {
            let phrase = source.substring(with: match.range(at: 1))
            let marker = "\u{E100}literal-\(index)\u{E101}"
            output = (output as NSString).replacingCharacters(in: match.range, with: marker)
            literals.append((marker, phrase))
        }
        return ProtectedText(text: output, literals: literals)
    }

    private static func replaceCommands(in protected: ProtectedText) -> ProtectedText {
        let source = protected.text as NSString
        let matches = commandRegex.matches(
            in: protected.text,
            range: NSRange(location: 0, length: source.length)
        )
        var output = protected.text
        for match in matches.reversed() {
            var phrase = source.substring(with: match.range).lowercased()
            while let last = phrase.last, last.isPunctuation { phrase.removeLast() }
            phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let marker = phraseToMarker[phrase] else { continue }
            output = (output as NSString).replacingCharacters(in: match.range, with: marker)
        }
        return ProtectedText(text: output, literals: protected.literals)
    }

    private static func renderMarkers(in raw: String) -> String {
        var text = raw
        let structural: [(String, String)] = [
            ("\u{E000}", "\n\n"),
            ("\u{E001}", "\n"),
            ("\u{E002}", "\n- "),
            ("\u{E003}", "\n1. "),
            ("\u{E004}", "\n- [ ] "),
            ("\u{E005}", "\n\n# "),
            ("\u{E006}", "\n\n## "),
            ("\u{E007}", "\n\n### "),
        ]
        for (marker, replacement) in structural {
            let pattern = "[ \\t]*[,;:]?[ \\t]*\(marker)[ \\t]*"
            text = text.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }

        let punctuation: [(String, String)] = [
            ("\u{E008}", "."), ("\u{E009}", ","), ("\u{E00A}", ":"),
            ("\u{E00B}", ";"), ("\u{E00C}", "?"), ("\u{E00D}", "!"),
            ("\u{E00E}", "—"),
        ]
        for (marker, replacement) in punctuation {
            text = text.replacingOccurrences(
                of: "[ \\t]*\(marker)[ \\t]*",
                with: replacement + " ",
                options: .regularExpression
            )
        }
        return text
    }

    private static func tidy(_ text: String) -> String {
        var output = text.replacingOccurrences(
            of: #"[ \t]+([,.!?;:])"#,
            with: "$1",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        output = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        output = output.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

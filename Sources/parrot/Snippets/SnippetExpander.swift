import Foundation

/// A compiled, deterministic one-pass expander. Only explicit commands match,
/// and inserted content is never scanned again, so snippets cannot cascade.
struct SnippetExpander: @unchecked Sendable {
    private let replacements: [String: String]
    private let commandRegex: NSRegularExpression?
    private let literalRegex: NSRegularExpression?

    init(entries: [SnippetEntry]) {
        var replacements: [String: String] = [:]
        for entry in entries.reversed() where replacements[entry.trigger.lowercased()] == nil {
            replacements[entry.trigger.lowercased()] = entry.content
        }
        self.replacements = replacements

        guard !replacements.isEmpty else {
            commandRegex = nil
            literalRegex = nil
            return
        }
        let alternatives = replacements.keys
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern)
            .joined(separator: "|")
        let command = "insert[ \\t]+snippet[ \\t]+(\(alternatives))(?:[.,!?;:])?"
        commandRegex = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}_])\(command)(?![\\p{L}\\p{N}_])",
            options: .caseInsensitive
        )
        literalRegex = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}_])literal[ \\t]+(\(command))(?![\\p{L}\\p{N}_])",
            options: .caseInsensitive
        )
    }

    func applying(to text: String) -> String {
        guard let commandRegex, let literalRegex else { return text }

        var protected = text
        var literals: [(marker: String, phrase: String)] = []
        let literalSource = text as NSString
        let literalMatches = literalRegex.matches(
            in: text,
            range: NSRange(location: 0, length: literalSource.length)
        )
        for (index, match) in literalMatches.enumerated().reversed() {
            let marker = "\u{E200}snippet-literal-\(index)\u{E201}"
            let phrase = literalSource.substring(with: match.range(at: 1))
            protected = (protected as NSString).replacingCharacters(in: match.range, with: marker)
            literals.append((marker, phrase))
        }

        let source = protected as NSString
        let matches = commandRegex.matches(
            in: protected,
            range: NSRange(location: 0, length: source.length)
        )
        var output = protected
        for match in matches.reversed() {
            let trigger = source.substring(with: match.range(at: 1)).lowercased()
            guard let replacement = replacements[trigger] else { continue }
            output = (output as NSString).replacingCharacters(in: match.range, with: replacement)
        }

        for literal in literals {
            output = output.replacingOccurrences(of: literal.marker, with: literal.phrase)
        }
        return output
    }
}

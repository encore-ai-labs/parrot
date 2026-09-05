import Foundation

/// A compiled, case-insensitive, one-pass remover for user-selected filler
/// words and phrases. Matching is whole-word only and never touches saved
/// snippet bodies because it runs before snippet expansion.
struct PersonalFillerRemover: @unchecked Sendable {
    let count: Int
    private let regex: NSRegularExpression?

    init(entries: [PersonalFillerEntry]) {
        var seen = Set<String>()
        let phrases = entries.reversed().compactMap { entry -> String? in
            let phrase = PersonalFillerLibrary.normalize(entry.phrase)
            guard !phrase.isEmpty else { return nil }
            let key = phrase.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return phrase
        }
        count = phrases.count
        guard !phrases.isEmpty else {
            regex = nil
            return
        }

        let alternatives = phrases
            .sorted { $0.count > $1.count }
            .map { phrase in
                phrase.split(separator: " ")
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: #"[ \t]+"#)
            }
            .joined(separator: "|")
        let leftBoundary = #"[\p{L}\p{N}_'’\-‐‑‒–—./@#]"#
        let rightBoundary = #"[\p{L}\p{N}_'’\-‐‑‒–—/@#]"#
        regex = try? NSRegularExpression(
            pattern: #"(?<!\#(leftBoundary))(?:\#(alternatives))(?!\#(rightBoundary))(?!\.(?=[\p{L}\p{N}]))"#,
            options: .caseInsensitive
        )
    }

    func applying(to text: String) -> String {
        guard let regex, !text.isEmpty else { return text }
        let source = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { return text }

        var output = text
        for match in matches.reversed() {
            let current = output as NSString
            if let escapeRange = Self.literalEscapeRange(
                before: match.range.location,
                in: current
            ) {
                let sentenceStart = Self.isSentenceStart(
                    current.substring(to: escapeRange.location)
                )
                output = current.replacingCharacters(in: escapeRange, with: "")
                if sentenceStart {
                    output = Self.capitalizingFirstLetter(
                        atOrAfter: escapeRange.location,
                        in: output
                    )
                }
                continue
            }
            let sentenceStart = Self.isSentenceStart(
                current.substring(to: match.range.location)
            )
            let removal = Self.extendedRemoval(match.range, in: current)
            output = current.replacingCharacters(
                in: removal.range,
                with: removal.replacement
            )
            if sentenceStart {
                output = Self.capitalizingFirstLetter(
                    atOrAfter: removal.range.location,
                    in: output
                )
            }
        }

        output = Self.replacing(Self.spacesRegex, in: output, with: " ")
        output = Self.replacing(Self.beforePunctuationRegex, in: output, with: "$1")
        output = Self.replacing(Self.lineEdgesRegex, in: output, with: "")
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.contains(where: { $0.isLetter || $0.isNumber }) ? output : ""
    }

    /// “literal <configured phrase>” removes only the escape word. This gives
    /// users a deterministic way to dictate a phrase they normally discard.
    private static func literalEscapeRange(
        before location: Int,
        in text: NSString
    ) -> NSRange? {
        guard location > 0 else { return nil }
        let prefix = text.substring(to: location)
        let range = NSRange(location: 0, length: (prefix as NSString).length)
        return literalPrefixRegex.firstMatch(in: prefix, range: range)?.range
    }

    /// Consume horizontal space and an adjacent clause separator after a
    /// filler. Sentence-ending punctuation remains, preserving boundaries when
    /// a filler happens to be the final audible word.
    private static func extendedRemoval(
        _ range: NSRange,
        in text: NSString
    ) -> (range: NSRange, replacement: String) {
        var start = range.location
        var end = NSMaxRange(range)
        while end < text.length, isHorizontalSpace(text.character(at: end)) {
            end += 1
        }
        var consumedTrailingSeparator = false
        if end < text.length, isClauseSeparator(text.character(at: end)) {
            consumedTrailingSeparator = true
            end += 1
            while end < text.length, isHorizontalSpace(text.character(at: end)) {
                end += 1
            }
        }

        // A parenthetical filler often arrives as “because, you know, we”.
        // When both separators are present, remove the pair so cleanup cannot
        // leave an ungrammatical comma between a subject and its predicate.
        if consumedTrailingSeparator {
            var cursor = start
            while cursor > 0, isHorizontalSpace(text.character(at: cursor - 1)) {
                cursor -= 1
            }
            if cursor > 0, isClauseSeparator(text.character(at: cursor - 1)) {
                start = cursor - 1
            }
        }

        let joinsWords = start > 0
            && end < text.length
            && isWordCharacter(text.character(at: start - 1))
            && isWordCharacter(text.character(at: end))
        return (
            NSRange(location: start, length: end - start),
            joinsWords ? " " : ""
        )
    }

    private static func isSentenceStart(_ prefix: String) -> Bool {
        let currentLine = prefix.lastIndex(of: "\n")
            .map { String(prefix[prefix.index(after: $0)...]) }
            ?? prefix
        let trimmed = currentLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        return trimmed.last.map { ".!?".contains($0) } ?? true
    }

    private static func capitalizingFirstLetter(atOrAfter location: Int, in text: String) -> String {
        let source = text as NSString
        guard location < source.length else { return text }
        let searchRange = NSRange(location: location, length: source.length - location)
        let letterRange = source.rangeOfCharacter(from: .letters, options: [], range: searchRange)
        guard letterRange.location != NSNotFound else { return text }
        let letter = source.substring(with: letterRange)
        return source.replacingCharacters(in: letterRange, with: letter.uppercased())
    }

    private static func isHorizontalSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    private static func isClauseSeparator(_ character: unichar) -> Bool {
        character == 0x2C || character == 0x3B || character == 0x3A
    }

    private static func isWordCharacter(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(Int(character)) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func replacing(
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

    private static let spacesRegex = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    private static let beforePunctuationRegex = try! NSRegularExpression(
        pattern: #"[ \t]+([,.!?;:])"#
    )
    private static let lineEdgesRegex = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]+|[ \t]+$"#
    )
    private static let literalPrefixRegex = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}_'’\-‐‑‒–—])literal[ \t]+$"#
    )
}

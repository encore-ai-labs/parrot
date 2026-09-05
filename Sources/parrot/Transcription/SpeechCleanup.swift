import Foundation

/// Conservative, deterministic cleanup for spoken drafts.
///
/// This intentionally handles only patterns with strong evidence of a
/// disfluency. It never removes conversational words such as "like", "right",
/// or "okay", and it leaves repeated content words alone. The implementation
/// is a fixed number of precompiled regex passes: no model, network request, or
/// transcript-sized auxiliary token graph is involved.
enum SpeechCleanup {
    private static let word = #"[\p{L}\p{N}'’]"#
    private static let boundary = #"[\p{L}\p{N}_'’\-‐‑–—./@#]"#
    private static let hesitation = #"(?:u+h+|u+m+|u+h+m+|e+r+m+)"#

    private static let hesitationRegex = try! NSRegularExpression(
        pattern: #"(?<!\#(boundary))\#(hesitation)(?:[,.])?(?!\#(boundary))"#,
        options: .caseInsensitive
    )

    /// Exact multi-word phrases repeated around a comma are characteristic
    /// false starts: "I wanted to, I wanted to check". Requiring at least two
    /// words preserves emphatic single-word speech such as "very, very" and
    /// "no, no". Limit the phrase to six words so the regex stays bounded and
    /// cannot rewrite repeated sentences or sections.
    private static let commaRepeatedPhraseRegex = try! NSRegularExpression(
        pattern: #"(?<!\#(boundary))((?:\#(word)+[ \t]+){1,5}\#(word)+)[ \t]*,[ \t]*\1(?!\#(boundary))"#,
        options: .caseInsensitive
    )

    /// A deliberately small set for punctuation-free stutters. Content-word
    /// emphasis ("very very") and grammatical repetitions ("had had",
    /// "that that") must survive.
    private static let repeatedFunctionWordRegex = try! NSRegularExpression(
        pattern: #"(?<!\#(boundary))(I|we|you|he|she|they|it|and|but|so|to|a|an|the)(?:[ \t]*,[ \t]*|[ \t]+)\1(?!\#(boundary))"#,
        options: .caseInsensitive
    )

    /// Whisper sometimes preserves an audible prefix restart as "w- want".
    /// Requiring the completed word to begin with the same 1–4 letter prefix
    /// keeps ordinary hyphenated words and dash-separated prose unchanged.
    private static let prefixStutterRegex = try! NSRegularExpression(
        pattern: #"(?<!\#(boundary))([\p{L}]{1,4})-[ \t]+(\1[\p{L}]+)(?!\#(boundary))"#,
        options: .caseInsensitive
    )

    private static let spacesRegex = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    private static let beforePunctuationRegex = try! NSRegularExpression(
        pattern: #"[ \t]+([,.!?;:])"#
    )
    private static let lineEdgesRegex = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]+|[ \t]+$"#
    )

    static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var output = removingHesitations(in: text)
        // A speaker can restart the same phrase more than twice. Four bounded
        // passes collapse that case without an input-dependent loop.
        for _ in 0..<4 {
            let collapsed = replacing(commaRepeatedPhraseRegex, in: output, with: "$1")
            if collapsed == output { break }
            output = collapsed
        }
        output = replacing(repeatedFunctionWordRegex, in: output, with: "$1")
        output = replacing(prefixStutterRegex, in: output, with: "$2")
        output = replacing(spacesRegex, in: output, with: " ")
        output = replacing(beforePunctuationRegex, in: output, with: "$1")
        output = replacing(lineEdgesRegex, in: output, with: "")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingHesitations(in text: String) -> String {
        let source = text as NSString
        let matches = hesitationRegex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { return text }

        var output = text
        for match in matches.reversed() {
            let matched = source.substring(with: match.range)
            let letters = String(matched.filter(\.isLetter))
            // Preserve explicit acronyms such as "UM" (University of
            // Michigan). Whisper's hesitation output is lowercase or
            // sentence-cased, never an intentional all-caps token.
            if letters.count > 1, letters == letters.uppercased() { continue }
            output = (output as NSString).replacingCharacters(in: match.range, with: "")
        }
        return output
    }

    private static func replacing(
        _ regex: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}

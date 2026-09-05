import Foundation

struct VocabularyEntry: Codable, Equatable {
    let spoken: String
    let written: String
}

/// User-owned recognition hints and deterministic text replacements.
///
/// Entries stay in insertion order so the most recently taught terms can be
/// prioritized when Whisper's finite prompt budget is built. Applying the
/// replacements is deliberately one pass over the original transcript: a
/// replacement can never trigger a second entry by accident.
struct PersonalVocabulary: Codable, Equatable {
    enum VocabularyError: LocalizedError {
        case emptySpokenForm
        case emptyWrittenForm

        var errorDescription: String? {
            switch self {
            case .emptySpokenForm:
                return "the spoken form cannot be empty"
            case .emptyWrittenForm:
                return "the written form cannot be empty"
            }
        }
    }

    private(set) var entries: [VocabularyEntry] = []

    static var url: URL {
        Config.directory.appendingPathComponent("vocabulary.json")
    }

    static func load(from url: URL = Self.url) throws -> PersonalVocabulary {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PersonalVocabulary()
        }
        return try JSONDecoder().decode(
            PersonalVocabulary.self,
            from: Data(contentsOf: url)
        )
    }

    func save(to url: URL = Self.url) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// Add a term or replace the existing entry with the same spoken form.
    /// Returns true when an existing entry was updated.
    @discardableResult
    mutating func set(spoken rawSpoken: String, written rawWritten: String) throws -> Bool {
        let spoken = Self.normalizedSpoken(rawSpoken)
        let written = rawWritten.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { throw VocabularyError.emptySpokenForm }
        guard !written.isEmpty else { throw VocabularyError.emptyWrittenForm }

        let updated = entries.contains {
            $0.spoken.compare(spoken, options: .caseInsensitive) == .orderedSame
        }
        entries.removeAll {
            $0.spoken.compare(spoken, options: .caseInsensitive) == .orderedSame
        }
        entries.append(VocabularyEntry(spoken: spoken, written: written))
        return updated
    }

    @discardableResult
    mutating func remove(spoken rawSpoken: String) -> Bool {
        let spoken = Self.normalizedSpoken(rawSpoken)
        let oldCount = entries.count
        entries.removeAll {
            $0.spoken.compare(spoken, options: .caseInsensitive) == .orderedSame
        }
        return entries.count != oldCount
    }

    /// Preferred spellings suitable for Whisper's initial prompt. Long-form
    /// snippets remain valid replacements but are excluded from recognition
    /// hints so they cannot consume the model's context window.
    var promptTerms: [String] {
        var seen = Set<String>()
        return entries.reversed().compactMap { entry in
            guard entry.written.count <= 64,
                  !entry.written.contains(where: { $0.isNewline })
            else { return nil }
            let key = entry.written.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return entry.written
        }
    }

    func applying(to text: String) -> String {
        VocabularyReplacer(entries: entries).applying(to: text)
    }

    private static func normalizedSpoken(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Compiled once when the daemon starts, keeping the per-dictation path to one
/// regex scan plus only the string edits that actually matched.
struct VocabularyReplacer {
    private let replacements: [String: String]
    private let regex: NSRegularExpression?

    init(entries: [VocabularyEntry]) {
        // Most-recent entry wins if a hand-edited file contains duplicates.
        var replacements: [String: String] = [:]
        for entry in entries.reversed() {
            let spoken = entry.spoken.replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty, spoken != entry.written else { continue }
            replacements[spoken.lowercased(), default: entry.written] = entry.written
        }
        self.replacements = replacements
        guard !replacements.isEmpty else {
            regex = nil
            return
        }

        // Longest alternatives first makes overlapping phrases predictable.
        let alternatives = replacements.keys
            .sorted { $0.count > $1.count }
            .map {
                let escaped = NSRegularExpression.escapedPattern(for: $0)
                return "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])"
            }
        regex = try? NSRegularExpression(
            pattern: alternatives.joined(separator: "|"),
            options: .caseInsensitive
        )
    }

    func applying(to text: String) -> String {
        guard let regex else { return text }

        let original = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: original.length)
        )
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            let key = original.substring(with: match.range).lowercased()
            guard let replacement = replacements[key] else { continue }
            result = (result as NSString).replacingCharacters(
                in: match.range,
                with: replacement
            )
        }
        return result
    }
}

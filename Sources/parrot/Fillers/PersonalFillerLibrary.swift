import Foundation

struct PersonalFillerEntry: Codable, Equatable, Sendable {
    let phrase: String
}

/// Explicit words and short phrases a user is comfortable removing from every
/// transcript. The list is separate from conservative built-in cleanup because
/// entries such as “like” or “you know” can carry meaning for another speaker.
struct PersonalFillerLibrary: Codable, Equatable, Sendable {
    enum FillerError: LocalizedError {
        case emptyPhrase
        case phraseTooLong
        case tooManyWords
        case unsupportedCharacters
        case tooManyEntries

        var errorDescription: String? {
            switch self {
            case .emptyPhrase:
                return "the filler phrase cannot be empty"
            case .phraseTooLong:
                return "the filler phrase cannot exceed 80 characters"
            case .tooManyWords:
                return "the filler phrase cannot exceed 6 words"
            case .unsupportedCharacters:
                return "use only words, numbers, apostrophes, and hyphens in a filler phrase"
            case .tooManyEntries:
                return "personal fillers are limited to 128 phrases"
            }
        }
    }

    static let maximumEntries = 128
    private(set) var entries: [PersonalFillerEntry] = []

    static var url: URL {
        Config.directory.appendingPathComponent("fillers.json")
    }

    static func load(from url: URL = Self.url) throws -> PersonalFillerLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PersonalFillerLibrary()
        }
        let decoded = try JSONDecoder().decode(
            PersonalFillerLibrary.self,
            from: Data(contentsOf: url)
        )
        try decoded.validate()
        return decoded
    }

    func save(to url: URL = Self.url) throws {
        try validate()
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

    /// Adds a phrase or replaces its casing case-insensitively.
    /// Returns true when an existing phrase was updated.
    @discardableResult
    mutating func set(_ rawPhrase: String) throws -> Bool {
        let phrase = try Self.validatedPhrase(rawPhrase)
        let updated = entries.contains { Self.matches($0.phrase, phrase) }
        guard updated || entries.count < Self.maximumEntries else {
            throw FillerError.tooManyEntries
        }
        entries.removeAll { Self.matches($0.phrase, phrase) }
        entries.append(PersonalFillerEntry(phrase: phrase))
        return updated
    }

    @discardableResult
    mutating func remove(_ rawPhrase: String) -> Bool {
        let phrase = Self.normalize(rawPhrase)
        let oldCount = entries.count
        entries.removeAll { Self.matches($0.phrase, phrase) }
        return entries.count != oldCount
    }

    private func validate() throws {
        guard entries.count <= Self.maximumEntries else {
            throw FillerError.tooManyEntries
        }
        for entry in entries {
            _ = try Self.validatedPhrase(entry.phrase)
        }
    }

    static func normalize(_ phrase: String) -> String {
        phrase.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validatedPhrase(_ rawPhrase: String) throws -> String {
        let phrase = normalize(rawPhrase)
        guard !phrase.isEmpty else { throw FillerError.emptyPhrase }
        guard phrase.count <= 80 else { throw FillerError.phraseTooLong }
        guard phrase.split(separator: " ").count <= 6 else { throw FillerError.tooManyWords }
        let range = NSRange(location: 0, length: (phrase as NSString).length)
        guard phraseRegex.firstMatch(in: phrase, range: range)?.range == range else {
            throw FillerError.unsupportedCharacters
        }
        return phrase
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        normalize(lhs).compare(normalize(rhs), options: .caseInsensitive) == .orderedSame
    }

    private static let phraseRegex = try! NSRegularExpression(
        pattern: #"^[\p{L}\p{N}'’\-‐‑‒–—]+(?: [\p{L}\p{N}'’\-‐‑‒–—]+){0,5}$"#
    )
}

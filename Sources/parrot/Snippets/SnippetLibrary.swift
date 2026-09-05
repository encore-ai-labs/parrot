import Foundation

struct SnippetEntry: Codable, Equatable, Sendable {
    let trigger: String
    let content: String
}

/// User-owned, reusable text blocks invoked with “insert snippet <trigger>”.
/// Stored independently from vocabulary because snippet bodies may be large,
/// multiline Markdown and must never be used as Whisper prompt context.
struct SnippetLibrary: Codable, Equatable, Sendable {
    enum SnippetError: LocalizedError {
        case emptyTrigger
        case triggerTooLong
        case emptyContent
        case contentTooLong

        var errorDescription: String? {
            switch self {
            case .emptyTrigger:
                return "the snippet trigger cannot be empty"
            case .triggerTooLong:
                return "the snippet trigger cannot exceed 80 characters"
            case .emptyContent:
                return "the snippet content cannot be empty"
            case .contentTooLong:
                return "the snippet content cannot exceed 100,000 characters"
            }
        }
    }

    private(set) var entries: [SnippetEntry] = []

    static var url: URL {
        Config.directory.appendingPathComponent("snippets.json")
    }

    static func load(from url: URL = Self.url) throws -> SnippetLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SnippetLibrary()
        }
        return try JSONDecoder().decode(SnippetLibrary.self, from: Data(contentsOf: url))
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

    /// Adds a snippet or replaces an existing trigger case-insensitively.
    /// Returns true when an existing entry was updated.
    @discardableResult
    mutating func set(trigger rawTrigger: String, content: String) throws -> Bool {
        let trigger = Self.normalizedTrigger(rawTrigger)
        guard !trigger.isEmpty else { throw SnippetError.emptyTrigger }
        guard trigger.count <= 80 else { throw SnippetError.triggerTooLong }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SnippetError.emptyContent
        }
        guard content.count <= 100_000 else { throw SnippetError.contentTooLong }

        let updated = entries.contains { Self.matches($0.trigger, trigger) }
        entries.removeAll { Self.matches($0.trigger, trigger) }
        entries.append(SnippetEntry(trigger: trigger, content: content))
        return updated
    }

    @discardableResult
    mutating func remove(trigger rawTrigger: String) -> Bool {
        let trigger = Self.normalizedTrigger(rawTrigger)
        let oldCount = entries.count
        entries.removeAll { Self.matches($0.trigger, trigger) }
        return entries.count != oldCount
    }

    func entry(matching rawTrigger: String) -> SnippetEntry? {
        let trigger = Self.normalizedTrigger(rawTrigger)
        return entries.last { Self.matches($0.trigger, trigger) }
    }

    /// Only short spoken commands enter Whisper's bounded prompt budget.
    /// Snippet bodies stay completely outside model context. Limit hints to the
    /// newest four so snippets cannot crowd vocabulary out of the 96-token cap.
    var promptTerms: [String] {
        entries.reversed().prefix(4).map { "insert snippet \($0.trigger)" }
    }

    private static func normalizedTrigger(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .caseInsensitive) == .orderedSame
    }
}

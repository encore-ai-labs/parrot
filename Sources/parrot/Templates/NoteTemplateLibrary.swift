import Foundation

struct NoteTemplateEntry: Codable, Equatable, Sendable {
    let name: String
    let body: String
}

/// Private, deterministic Markdown shapes for recurring notes. Bodies never
/// enter recognition context and rendering performs fixed placeholder
/// substitution only—there is no prompt, model, or network path here.
struct NoteTemplateLibrary: Codable, Equatable, Sendable {
    enum TemplateError: LocalizedError {
        case emptyName
        case invalidName
        case nameTooLong
        case tooManyTemplates
        case emptyBody
        case bodyTooLong
        case missingTranscript
        case repeatedTranscript
        case unknownPlaceholder(String)
        case malformedPlaceholder

        var errorDescription: String? {
            switch self {
            case .emptyName:
                return "the template name cannot be empty"
            case .invalidName:
                return "template names may contain letters, numbers, spaces, and hyphens"
            case .nameTooLong:
                return "the template name cannot exceed 60 characters"
            case .tooManyTemplates:
                return "note templates are limited to \(NoteTemplateLibrary.maximumEntries)"
            case .emptyBody:
                return "the template body cannot be empty"
            case .bodyTooLong:
                return "the template body cannot exceed 32,000 characters"
            case .missingTranscript:
                return "the template must contain {{transcript}} exactly once"
            case .repeatedTranscript:
                return "the template may contain {{transcript}} only once"
            case .unknownPlaceholder(let placeholder):
                return "unknown template placeholder {{\(placeholder)}}"
            case .malformedPlaceholder:
                return "template placeholders must use {{name}} with matching braces"
            }
        }
    }

    static let maximumEntries = 32
    static let maximumBodyCharacters = 32_000
    static let supportedPlaceholders = ["transcript", "date", "time", "datetime"]

    private(set) var entries: [NoteTemplateEntry] = []

    static var url: URL {
        Config.directory.appendingPathComponent("note-templates.json")
    }

    static func load(from url: URL = Self.url) throws -> NoteTemplateLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return NoteTemplateLibrary()
        }
        let decoded = try JSONDecoder().decode(
            NoteTemplateLibrary.self,
            from: Data(contentsOf: url)
        )
        var validated = NoteTemplateLibrary()
        for entry in decoded.entries {
            try validated.set(name: entry.name, body: entry.body)
        }
        return validated
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

    @discardableResult
    mutating func set(name rawName: String, body: String) throws -> Bool {
        let name = Self.normalizedName(rawName)
        guard !name.isEmpty else { throw TemplateError.emptyName }
        guard name.count <= 60 else { throw TemplateError.nameTooLong }
        guard Self.isValidName(name) else { throw TemplateError.invalidName }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TemplateError.emptyBody
        }
        guard body.count <= Self.maximumBodyCharacters else {
            throw TemplateError.bodyTooLong
        }
        try Self.validatePlaceholders(in: body)

        let existing = entries.firstIndex { Self.matches($0.name, name) }
        guard existing != nil || entries.count < Self.maximumEntries else {
            throw TemplateError.tooManyTemplates
        }
        if let existing {
            entries.remove(at: existing)
        }
        entries.append(NoteTemplateEntry(name: name, body: body))
        return existing != nil
    }

    @discardableResult
    mutating func remove(name rawName: String) -> Bool {
        let name = Self.normalizedName(rawName)
        let oldCount = entries.count
        entries.removeAll { Self.matches($0.name, name) }
        return oldCount != entries.count
    }

    func entry(matching rawName: String) -> NoteTemplateEntry? {
        let name = Self.normalizedName(rawName)
        return entries.last { Self.matches($0.name, name) }
    }

    func canonicalName(matching rawName: String) -> String? {
        entry(matching: rawName)?.name
    }

    /// Only short names enter the bounded recognition prompt. Template bodies
    /// can contain private long-form structure and never enter model context.
    var promptTerms: [String] {
        entries.reversed().prefix(4).map { "template \($0.name)" }
    }

    private static func validatePlaceholders(in body: String) throws {
        let transcriptCount = body.components(separatedBy: "{{transcript}}").count - 1
        guard transcriptCount > 0 else { throw TemplateError.missingTranscript }
        guard transcriptCount == 1 else { throw TemplateError.repeatedTranscript }

        let regex = try! NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#)
        let source = body as NSString
        let matches = regex.matches(
            in: body,
            range: NSRange(location: 0, length: source.length)
        )
        for match in matches {
            let placeholder = source.substring(with: match.range(at: 1))
            guard supportedPlaceholders.contains(placeholder) else {
                throw TemplateError.unknownPlaceholder(placeholder)
            }
        }
        var withoutPlaceholders = body
        for placeholder in supportedPlaceholders {
            withoutPlaceholders = withoutPlaceholders.replacingOccurrences(
                of: "{{\(placeholder)}}",
                with: ""
            )
        }
        guard !withoutPlaceholders.contains("{{"), !withoutPlaceholders.contains("}}") else {
            throw TemplateError.malformedPlaceholder
        }
    }

    private static func normalizedName(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValidName(_ name: String) -> Bool {
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-"))
        return name.unicodeScalars.allSatisfy(allowed.contains)
            && name.unicodeScalars.first.map {
                CharacterSet.letters.union(.decimalDigits).contains($0)
            } == true
            && name.unicodeScalars.last.map {
                CharacterSet.letters.union(.decimalDigits).contains($0)
            } == true
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .caseInsensitive) == .orderedSame
    }
}

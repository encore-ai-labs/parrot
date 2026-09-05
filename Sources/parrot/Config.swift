import Foundation

/// Settings that persist between runs, at `~/.config/parrot/config.json`.
///
/// JSON rather than the TOML the original design called for: Codable gives it
/// to us for free, and pulling in a TOML parser for this small settings file isn't
/// worth a dependency.
///
/// Every field is optional and means "not yet decided" when nil — that's what
/// distinguishes a first run (ask the user) from a later one (respect that they
/// already chose, including choosing "no").
struct Config: Codable, Equatable {
    /// Lowercase everything before injecting it.
    var lowercase: Bool?
    /// CoreAudio UID of the last microphone chosen, used to preselect it.
    var inputDeviceUID: String?
    /// Set once first-run setup completes, so we don't re-ask every launch.
    var setupCompleted: Bool?
    /// Default push-to-talk key. Command-line options remain one-run overrides.
    var hotkey: String?
    /// Default transcription model id.
    var model: String?
    /// Whisper language code, or `auto` for per-recording detection.
    var language: String?
    /// Default text-processing mode.
    var mode: DictationMode?
    /// Explicit local mappings from application bundle ids to text mode.
    var appRules: [AppModeRule]?
    /// Optional Markdown destination. When set, finished dictations append
    /// here instead of being injected at the cursor.
    var journalPath: String?
    /// Optional user-owned local command. Final text is written to its stdin
    /// instead of being injected at the cursor.
    var deliveryCommand: String?
    /// Remove conservative, deterministic speech disfluencies after local
    /// transcription. Nil preserves the built-in off default.
    var cleanup: Bool?
    /// Insert paragraphs at deliberate pauses while note mode is active.
    /// Nil preserves the built-in on default for notes.
    var automaticParagraphs: Bool?
    /// Add one boundary space after cursor-injected text. This never changes
    /// history, journal, command, or stored-file output.
    var spaceAfterPaste: Bool?
    /// Keep the microphone warm for a 300 ms pre-roll. Turning this off avoids
    /// an idle mic session at the cost of clipping the start of captures.
    var warmMicrophone: Bool?

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/parrot", isDirectory: true)
    }

    static var url: URL { directory.appendingPathComponent("config.json") }

    /// Missing or unreadable config is not an error — it's a first run.
    static func load(from url: URL = Self.url) -> Config {
        tightenPermissionsIfPresent(at: url)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return decoded
    }

    /// Throwing form used by settings commands and tests, where claiming a
    /// setting was saved when it was not would be worse than surfacing an error.
    func write(to url: URL = Self.url) throws {
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

    func save() {
        do {
            try write()
        } catch {
            // Losing a preference is not worth failing a launch over.
            FileHandle.standardError.write(Data(
                "warning: couldn't save config to \(Self.url.path): \(error)\n".utf8
            ))
        }
    }

    /// Older releases wrote the config with the process umask (commonly
    /// 0755/0644). Upgrade it in place on first read without rewriting data.
    private static func tightenPermissionsIfPresent(at url: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.deletingLastPathComponent().path
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

enum DictationMode: String, Codable, CaseIterable {
    case dictation
    case notes

    static func parse(_ raw: String) -> DictationMode? {
        DictationMode(rawValue: raw.lowercased().trimmingCharacters(in: .whitespaces))
    }
}

/// Resolves launch settings without touching hardware. Keeping this pure makes
/// the CLI > saved config > built-in precedence explicit and regression-testable.
struct RuntimeDefaults: Equatable {
    let hotkey: String
    let model: String
    let language: String
    let mode: DictationMode
    let journalPath: String?
    let deliveryCommand: String?
    let cleanup: Bool
    let automaticParagraphs: Bool
    let spaceAfterPaste: Bool
    let warmMicrophone: Bool

    static func resolve(
        config: Config,
        hotkeyOverride: String?,
        modelOverride: String?,
        languageOverride: String? = nil,
        notes: Bool,
        dictation: Bool,
        journalOverride: String? = nil,
        commandOverride: String? = nil,
        paste: Bool = false,
        cleanupOverride: Bool? = nil,
        automaticParagraphsOverride: Bool? = nil,
        spaceAfterPasteOverride: Bool? = nil,
        warmMicrophoneOverride: Bool? = nil,
        recommendedModel: String
    ) throws -> RuntimeDefaults {
        guard !(notes && dictation) else {
            throw RuntimeDefaultsError.conflictingModes
        }
        let destinationOverrides = [journalOverride != nil, commandOverride != nil, paste]
            .filter { $0 }.count
        guard destinationOverrides <= 1 else {
            throw RuntimeDefaultsError.conflictingDestinations
        }
        let requestedLanguage = languageOverride ?? config.language ?? RecognitionLanguage.automatic
        guard let resolvedLanguage = RecognitionLanguage.canonicalize(requestedLanguage) else {
            throw RuntimeDefaultsError.invalidLanguage(requestedLanguage)
        }
        let resolvedMode: DictationMode
        if notes {
            resolvedMode = .notes
        } else if dictation {
            resolvedMode = .dictation
        } else {
            resolvedMode = config.mode ?? .dictation
        }
        let resolvedJournalPath: String?
        let resolvedDeliveryCommand: String?
        if paste {
            resolvedJournalPath = nil
            resolvedDeliveryCommand = nil
        } else if let journalOverride {
            resolvedJournalPath = journalOverride
            resolvedDeliveryCommand = nil
        } else if let commandOverride {
            resolvedJournalPath = nil
            resolvedDeliveryCommand = commandOverride
        } else {
            guard config.journalPath == nil || config.deliveryCommand == nil else {
                throw RuntimeDefaultsError.conflictingSavedDestinations
            }
            resolvedJournalPath = config.journalPath
            resolvedDeliveryCommand = config.deliveryCommand
        }
        return RuntimeDefaults(
            hotkey: hotkeyOverride ?? config.hotkey ?? Hotkey.default.name,
            model: modelOverride ?? config.model ?? recommendedModel,
            language: resolvedLanguage,
            mode: resolvedMode,
            journalPath: resolvedJournalPath,
            deliveryCommand: resolvedDeliveryCommand,
            cleanup: cleanupOverride ?? config.cleanup ?? false,
            automaticParagraphs: automaticParagraphsOverride
                ?? config.automaticParagraphs
                ?? true,
            spaceAfterPaste: spaceAfterPasteOverride ?? config.spaceAfterPaste ?? true,
            warmMicrophone: warmMicrophoneOverride ?? config.warmMicrophone ?? true
        )
    }
}

enum RuntimeDefaultsError: LocalizedError {
    case conflictingModes
    case conflictingDestinations
    case conflictingSavedDestinations
    case invalidLanguage(String)

    var errorDescription: String? {
        switch self {
        case .conflictingModes:
            return "pass at most one of --notes or --dictation"
        case .conflictingDestinations:
            return "pass at most one of --journal, --command, or --paste"
        case .conflictingSavedDestinations:
            return "saved delivery has both journal and command destinations; "
                + "run `parrot settings set --paste` to repair it"
        case .invalidLanguage(let language):
            return "unknown language '\(language)'; run `parrot languages`"
        }
    }
}

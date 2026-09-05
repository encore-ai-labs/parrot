import ArgumentParser
import Foundation

struct Settings: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or change persistent local daemon defaults.",
        subcommands: [Show.self, Set.self, Reset.self],
        defaultSubcommand: Show.self
    )

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show effective saved defaults."
        )

        func run() throws {
            let config = Config.load()
            let recommended = ModelRegistry.recommended()?.id ?? "unavailable"
            let defaults = try RuntimeDefaults.resolve(
                config: config,
                hotkeyOverride: nil,
                modelOverride: nil,
                notes: false,
                dictation: false,
                recommendedModel: recommended
            )
            print("hotkey      \(defaults.hotkey)\(config.hotkey == nil ? "  (default)" : "")")
            print("note key    \(defaults.noteHotkey ?? "off")")
            print(
                "note inbox  "
                    + (defaults.noteJournalPath.map {
                        StartupTUI.displayPath(URL(fileURLWithPath: $0))
                    } ?? "off")
                    + (defaults.noteHotkey == nil && defaults.noteJournalPath != nil
                        ? "  (inactive without note key)"
                        : "")
            )
            print("context     \(defaults.recognitionContext.rawValue)  (local Whisper hint)")
            print("model       \(defaults.model)\(config.model == nil ? "  (recommended)" : "")")
            print("language    \(defaults.language)\(config.language == nil ? "  (default)" : "")")
            print("mode        \(defaults.mode.rawValue)\(config.mode == nil ? "  (default)" : "")")
            print("cleanup     \(defaults.cleanup ? "on" : "off")\(config.cleanup == nil ? "  (default)" : "")")
            print(
                "paragraphs   \(defaults.automaticParagraphs ? "on in notes" : "off")"
                    + "\(config.automaticParagraphs == nil ? "  (default)" : "")"
            )
            print(
                "paste space  \(defaults.spaceAfterPaste ? "on" : "off")"
                    + "\(config.spaceAfterPaste == nil ? "  (default)" : "")"
            )
            print(
                "capture      \(defaults.warmMicrophone ? "warm · 300ms pre-roll" : "cold · opens on press")"
                    + "\(config.warmMicrophone == nil ? "  (default)" : "")"
            )
            print(
                "history      "
                    + (defaults.historyRetentionDays.map { "keep \($0) days" } ?? "keep forever")
                    + "\(config.historyRetentionDays == nil ? "  (default)" : "")"
            )
            print(
                "audio history "
                    + (defaults.audioHistoryRetentionDays.map { "keep \($0) days" } ?? "off")
                    + "\(config.audioHistoryRetentionDays == nil ? "  (default)" : "")"
            )
            if let journalPath = defaults.journalPath {
                print("delivery    journal → \(StartupTUI.displayPath(URL(fileURLWithPath: journalPath)))")
            } else if defaults.deliveryCommand != nil {
                print("delivery    local command ← transcript on stdin")
            } else {
                print("delivery    paste at cursor  (default)")
            }
            print("app rules   \(config.savedAppRules.count)")
            print("lowercase   \((config.lowercase ?? false) ? "on" : "off")")
            let microphones = config.savedInputDeviceUIDs
            print(
                "microphones "
                    + (microphones.isEmpty ? "automatic" : microphones.joined(separator: " → "))
            )
            print("config      \(Config.url.path)")
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save one or more daemon defaults."
        )

        @Option(name: .long, help: "Push-to-talk key from `parrot hotkeys`.")
        var hotkey: String?

        @Option(
            name: .customLong("note-hotkey"),
            help: "Optional second key that always records in note mode."
        )
        var noteHotkey: String?

        @Flag(
            name: .customLong("no-note-hotkey"),
            help: "Disable the dedicated note-mode shortcut."
        )
        var noNoteHotkey: Bool = false

        @Option(
            name: .customLong("note-journal"),
            help: "Append dedicated note-key captures to this Markdown file."
        )
        var noteJournal: String?

        @Flag(
            name: .customLong("no-note-journal"),
            help: "Restore the primary delivery destination for the note key."
        )
        var noNoteJournal: Bool = false

        @Option(
            name: .customLong("context"),
            help: "Local Whisper hint: off, selected-text, clipboard, or both."
        )
        var recognitionContext: String?

        @Option(name: .long, help: "Model id from `parrot models list`.")
        var model: String?

        @Option(name: .long, help: "Language code/name from `parrot languages`, or auto.")
        var language: String?

        @Option(name: .long, help: "Text-processing mode: dictation or notes.")
        var mode: String?

        @Option(name: .long, help: "Append dictations to this Markdown file instead of pasting.")
        var journal: String?

        @Option(
            name: .long,
            help: "Run a local zsh command with final text on stdin instead of pasting."
        )
        var command: String?

        @Flag(name: .long, help: "Restore paste-at-cursor delivery.")
        var paste: Bool = false

        @Flag(name: .long, help: "Remove conservative speech fillers and false starts locally.")
        var cleanup: Bool = false

        @Flag(name: .customLong("no-cleanup"), help: "Preserve speech disfluencies.")
        var noCleanup: Bool = false

        @Flag(
            name: .customLong("auto-paragraphs"),
            help: "Insert paragraphs at deliberate pauses in note mode."
        )
        var automaticParagraphs: Bool = false

        @Flag(
            name: .customLong("no-auto-paragraphs"),
            help: "Disable pause-aware paragraphs in note mode."
        )
        var noAutomaticParagraphs: Bool = false

        @Flag(
            name: .customLong("space-after-paste"),
            help: "Add a boundary space after cursor-injected text."
        )
        var spaceAfterPaste: Bool = false

        @Flag(
            name: .customLong("no-space-after-paste"),
            help: "Inject exact text with no trailing boundary space."
        )
        var noSpaceAfterPaste: Bool = false

        @Flag(
            name: .customLong("warm-mic"),
            help: "Keep the microphone warm for a 300 ms pre-roll."
        )
        var warmMicrophone: Bool = false

        @Flag(
            name: .customLong("cold-mic"),
            help: "Open the microphone only while recording; capture starts may clip."
        )
        var coldMicrophone: Bool = false

        @Option(
            name: .customLong("history-retention-days"),
            help: "Automatically remove transcript history older than 1...3650 rolling days."
        )
        var historyRetentionDays: Int?

        @Flag(
            name: .customLong("keep-history-forever"),
            help: "Disable automatic transcript-history cleanup."
        )
        var keepHistoryForever: Bool = false

        @Option(
            name: .customLong("audio-history-days"),
            help: "Retain private local recording audio for 1...3650 rolling days."
        )
        var audioHistoryRetentionDays: Int?

        @Flag(
            name: .customLong("no-audio-history"),
            help: "Stop saving delivered recording audio; existing files remain until cleared."
        )
        var noAudioHistory: Bool = false

        func validate() throws {
            guard hotkey != nil || noteHotkey != nil || noNoteHotkey
                    || noteJournal != nil || noNoteJournal
                    || recognitionContext != nil
                    || model != nil || language != nil || mode != nil
                    || journal != nil || command != nil || paste
                    || cleanup || noCleanup || automaticParagraphs || noAutomaticParagraphs
                    || spaceAfterPaste || noSpaceAfterPaste
                    || warmMicrophone || coldMicrophone
                    || historyRetentionDays != nil || keepHistoryForever
                    || audioHistoryRetentionDays != nil || noAudioHistory else {
                throw ValidationError(
                    "provide at least one setting to change"
                )
            }
            guard [journal != nil, command != nil, paste].filter({ $0 }).count <= 1 else {
                throw ValidationError("pass at most one of --journal, --command, or --paste")
            }
            guard !(cleanup && noCleanup) else {
                throw ValidationError("pass at most one of --cleanup or --no-cleanup")
            }
            guard !(automaticParagraphs && noAutomaticParagraphs) else {
                throw ValidationError(
                    "pass at most one of --auto-paragraphs or --no-auto-paragraphs"
                )
            }
            guard !(spaceAfterPaste && noSpaceAfterPaste) else {
                throw ValidationError(
                    "pass at most one of --space-after-paste or --no-space-after-paste"
                )
            }
            guard !(warmMicrophone && coldMicrophone) else {
                throw ValidationError("pass at most one of --warm-mic or --cold-mic")
            }
            guard !(historyRetentionDays != nil && keepHistoryForever) else {
                throw ValidationError(
                    "pass at most one of --history-retention-days or --keep-history-forever"
                )
            }
            guard !(audioHistoryRetentionDays != nil && noAudioHistory) else {
                throw ValidationError(
                    "pass at most one of --audio-history-days or --no-audio-history"
                )
            }
            guard !(noteHotkey != nil && noNoteHotkey) else {
                throw ValidationError(
                    "pass at most one of --note-hotkey or --no-note-hotkey"
                )
            }
            guard !(noteJournal != nil && noNoteJournal) else {
                throw ValidationError(
                    "pass at most one of --note-journal or --no-note-journal"
                )
            }
            if let historyRetentionDays {
                _ = try HistoryRetentionPolicy(days: historyRetentionDays)
            }
            if let audioHistoryRetentionDays {
                _ = try HistoryRetentionPolicy(days: audioHistoryRetentionDays)
            }
            if let hotkey, Hotkey.parse(hotkey) == nil {
                throw ValidationError("unknown hotkey '\(hotkey)'; run `parrot hotkeys`")
            }
            if let noteHotkey, Hotkey.parse(noteHotkey) == nil {
                throw ValidationError("unknown note hotkey '\(noteHotkey)'; run `parrot hotkeys`")
            }
            if let noteJournal {
                _ = try MarkdownJournal.resolveURL(noteJournal)
            }
            if let recognitionContext,
               RecognitionContextSource.parse(recognitionContext) == nil {
                throw ValidationError(
                    "unknown context '\(recognitionContext)'; use off, selected-text, clipboard, or both"
                )
            }
            if let hotkey = hotkey.flatMap(Hotkey.parse),
               let noteHotkey = noteHotkey.flatMap(Hotkey.parse),
               hotkey.conflicts(with: noteHotkey) {
                throw ValidationError("the primary and note hotkeys must be different")
            }
            if let model, ModelRegistry.find(model) == nil {
                throw ValidationError("unknown model '\(model)'; run `parrot models list`")
            }
            if let language, RecognitionLanguage.canonicalize(language) == nil {
                throw ValidationError("unknown language '\(language)'; run `parrot languages`")
            }
            if let mode, DictationMode.parse(mode) == nil {
                throw ValidationError("unknown mode '\(mode)'; use dictation or notes")
            }
            if let journal {
                _ = try MarkdownJournal.resolveURL(journal)
            }
            if let command {
                _ = try LocalCommandDelivery(command: command)
            }
        }

        func run() throws {
            guard hotkey != nil || noteHotkey != nil || noNoteHotkey
                    || noteJournal != nil || noNoteJournal
                    || recognitionContext != nil
                    || model != nil || language != nil || mode != nil
                    || journal != nil || command != nil || paste
                    || cleanup || noCleanup || automaticParagraphs || noAutomaticParagraphs
                    || spaceAfterPaste || noSpaceAfterPaste
                    || warmMicrophone || coldMicrophone
                    || historyRetentionDays != nil || keepHistoryForever
                    || audioHistoryRetentionDays != nil || noAudioHistory else {
                throw ValidationError(
                    "provide at least one setting to change"
                )
            }
            var config = Config.load()
            if let hotkey {
                guard let parsed = Hotkey.parse(hotkey) else {
                    throw ValidationError("unknown hotkey '\(hotkey)'; run `parrot hotkeys`")
                }
                config.hotkey = parsed.name
            }
            if let noteHotkey {
                guard let parsed = Hotkey.parse(noteHotkey) else {
                    throw ValidationError(
                        "unknown note hotkey '\(noteHotkey)'; run `parrot hotkeys`"
                    )
                }
                config.noteHotkey = parsed.name
            } else if noNoteHotkey {
                config.noteHotkey = nil
            }
            if let noteJournal {
                guard config.noteHotkey != nil else {
                    throw ValidationError(
                        "--note-journal requires a dedicated note key; also pass --note-hotkey"
                    )
                }
                let url = try MarkdownJournal.resolveURL(noteJournal)
                try MarkdownJournal(url: url).prepare()
                config.noteJournalPath = url.path
            } else if noNoteJournal {
                config.noteJournalPath = nil
            }
            if let recognitionContext {
                guard let parsed = RecognitionContextSource.parse(recognitionContext) else {
                    throw ValidationError(
                        "unknown context '\(recognitionContext)'; use off, selected-text, clipboard, or both"
                    )
                }
                config.recognitionContext = parsed.rawValue
            }
            if let noteHotkey = config.noteHotkey.flatMap(Hotkey.parse),
               let primaryHotkey = Hotkey.parse(config.hotkey ?? Hotkey.default.name),
               noteHotkey.conflicts(with: primaryHotkey) {
                throw ValidationError("the primary and note hotkeys must be different")
            }
            if let model {
                guard let registered = ModelRegistry.find(model) else {
                    throw ValidationError("unknown model '\(model)'; run `parrot models list`")
                }
                config.model = registered.id
            }
            if let language {
                guard let canonical = RecognitionLanguage.canonicalize(language) else {
                    throw ValidationError("unknown language '\(language)'; run `parrot languages`")
                }
                config.language = canonical
            }
            if let mode {
                guard let parsed = DictationMode.parse(mode) else {
                    throw ValidationError("unknown mode '\(mode)'; use dictation or notes")
                }
                config.mode = parsed
            }
            if let journal {
                let url = try MarkdownJournal.resolveURL(journal)
                try MarkdownJournal(url: url).prepare()
                config.journalPath = url.path
                config.deliveryCommand = nil
            } else if let command {
                let delivery = try LocalCommandDelivery(command: command)
                config.deliveryCommand = delivery.command
                config.journalPath = nil
            } else if paste {
                config.journalPath = nil
                config.deliveryCommand = nil
            }
            if cleanup || noCleanup {
                config.cleanup = cleanup
            }
            if automaticParagraphs || noAutomaticParagraphs {
                config.automaticParagraphs = automaticParagraphs
            }
            if spaceAfterPaste || noSpaceAfterPaste {
                config.spaceAfterPaste = spaceAfterPaste
            }
            if warmMicrophone || coldMicrophone {
                config.warmMicrophone = warmMicrophone
            }
            if let historyRetentionDays {
                _ = try HistoryRetentionPolicy(days: historyRetentionDays)
                config.historyRetentionDays = historyRetentionDays
            } else if keepHistoryForever {
                config.historyRetentionDays = nil
            }
            if let audioHistoryRetentionDays {
                _ = try HistoryRetentionPolicy(days: audioHistoryRetentionDays)
                config.audioHistoryRetentionDays = audioHistoryRetentionDays
            } else if noAudioHistory {
                config.audioHistoryRetentionDays = nil
            }
            let effectiveModelID = config.model ?? ModelRegistry.recommended()?.id ?? ""
            guard let effectiveModel = ModelRegistry.find(effectiveModelID) else {
                throw ValidationError("no transcription model is available")
            }
            let effectiveLanguage = config.language ?? RecognitionLanguage.automatic
            guard RecognitionLanguage.isSupported(effectiveLanguage, by: effectiveModel) else {
                throw ValidationError(
                    "\(effectiveModel.id) cannot transcribe \(effectiveLanguage); "
                        + "choose whisper-base/whisper-small or set --language en"
                )
            }
            try config.write()
            print("✓ saved Parrot defaults")
            try Show().run()
            print("restart a running Parrot daemon to apply the change")
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reset transcription, formatting, capture, and delivery defaults."
        )

        func run() throws {
            var config = Config.load()
            config.hotkey = nil
            config.noteHotkey = nil
            config.noteJournalPath = nil
            config.recognitionContext = nil
            config.model = nil
            config.language = nil
            config.mode = nil
            config.journalPath = nil
            config.deliveryCommand = nil
            config.cleanup = nil
            config.automaticParagraphs = nil
            config.spaceAfterPaste = nil
            config.warmMicrophone = nil
            config.historyRetentionDays = nil
            config.audioHistoryRetentionDays = nil
            try config.write()
            print("✓ reset transcription, formatting, capture, history, and delivery defaults")
            print("restart a running Parrot daemon to apply the change")
        }
    }
}

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
            if let journalPath = defaults.journalPath {
                print("delivery    journal → \(StartupTUI.displayPath(URL(fileURLWithPath: journalPath)))")
            } else if defaults.deliveryCommand != nil {
                print("delivery    local command ← transcript on stdin")
            } else {
                print("delivery    paste at cursor  (default)")
            }
            print("app rules   \(config.savedAppRules.count)")
            print("lowercase   \((config.lowercase ?? false) ? "on" : "off")")
            print("microphone  \(config.inputDeviceUID ?? "automatic")")
            print("config      \(Config.url.path)")
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save one or more daemon defaults."
        )

        @Option(name: .long, help: "Push-to-talk key from `parrot hotkeys`.")
        var hotkey: String?

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

        func validate() throws {
            guard hotkey != nil || model != nil || language != nil || mode != nil
                    || journal != nil || command != nil || paste
                    || cleanup || noCleanup || automaticParagraphs || noAutomaticParagraphs
                    || spaceAfterPaste || noSpaceAfterPaste
                    || warmMicrophone || coldMicrophone else {
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
            if let hotkey, Hotkey.parse(hotkey) == nil {
                throw ValidationError("unknown hotkey '\(hotkey)'; run `parrot hotkeys`")
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
            guard hotkey != nil || model != nil || language != nil || mode != nil
                    || journal != nil || command != nil || paste
                    || cleanup || noCleanup || automaticParagraphs || noAutomaticParagraphs
                    || spaceAfterPaste || noSpaceAfterPaste
                    || warmMicrophone || coldMicrophone else {
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
            config.model = nil
            config.language = nil
            config.mode = nil
            config.journalPath = nil
            config.deliveryCommand = nil
            config.cleanup = nil
            config.automaticParagraphs = nil
            config.spaceAfterPaste = nil
            config.warmMicrophone = nil
            try config.write()
            print("✓ reset transcription, formatting, capture, and delivery defaults")
            print("restart a running Parrot daemon to apply the change")
        }
    }
}

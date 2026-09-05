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
            if let journalPath = defaults.journalPath {
                print("delivery    journal → \(StartupTUI.displayPath(URL(fileURLWithPath: journalPath)))")
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

        @Flag(name: .long, help: "Restore paste-at-cursor delivery.")
        var paste: Bool = false

        @Flag(name: .long, help: "Remove conservative speech fillers and false starts locally.")
        var cleanup: Bool = false

        @Flag(name: .customLong("no-cleanup"), help: "Preserve speech disfluencies.")
        var noCleanup: Bool = false

        func validate() throws {
            guard hotkey != nil || model != nil || language != nil || mode != nil || journal != nil || paste
                    || cleanup || noCleanup else {
                throw ValidationError(
                    "provide at least one setting to change"
                )
            }
            guard !(journal != nil && paste) else {
                throw ValidationError("pass at most one of --journal or --paste")
            }
            guard !(cleanup && noCleanup) else {
                throw ValidationError("pass at most one of --cleanup or --no-cleanup")
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
        }

        func run() throws {
            guard hotkey != nil || model != nil || language != nil || mode != nil || journal != nil || paste
                    || cleanup || noCleanup else {
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
            } else if paste {
                config.journalPath = nil
            }
            if cleanup || noCleanup {
                config.cleanup = cleanup
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
            abstract: "Reset hotkey, model, language, mode, cleanup, and delivery defaults."
        )

        func run() throws {
            var config = Config.load()
            config.hotkey = nil
            config.model = nil
            config.language = nil
            config.mode = nil
            config.journalPath = nil
            config.cleanup = nil
            try config.write()
            print("✓ reset hotkey, model, language, mode, cleanup, and delivery defaults")
            print("restart a running Parrot daemon to apply the change")
        }
    }
}

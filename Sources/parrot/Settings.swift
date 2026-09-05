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
            print("mode        \(defaults.mode.rawValue)\(config.mode == nil ? "  (default)" : "")")
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

        @Option(name: .long, help: "Text-processing mode: dictation or notes.")
        var mode: String?

        @Option(name: .long, help: "Append dictations to this Markdown file instead of pasting.")
        var journal: String?

        @Flag(name: .long, help: "Restore paste-at-cursor delivery.")
        var paste: Bool = false

        func validate() throws {
            guard hotkey != nil || model != nil || mode != nil || journal != nil || paste else {
                throw ValidationError(
                    "provide at least one of --hotkey, --model, --mode, --journal, or --paste"
                )
            }
            guard !(journal != nil && paste) else {
                throw ValidationError("pass at most one of --journal or --paste")
            }
            if let hotkey, Hotkey.parse(hotkey) == nil {
                throw ValidationError("unknown hotkey '\(hotkey)'; run `parrot hotkeys`")
            }
            if let model, ModelRegistry.find(model) == nil {
                throw ValidationError("unknown model '\(model)'; run `parrot models list`")
            }
            if let mode, DictationMode.parse(mode) == nil {
                throw ValidationError("unknown mode '\(mode)'; use dictation or notes")
            }
            if let journal {
                _ = try MarkdownJournal.resolveURL(journal)
            }
        }

        func run() throws {
            guard hotkey != nil || model != nil || mode != nil || journal != nil || paste else {
                throw ValidationError(
                    "provide at least one of --hotkey, --model, --mode, --journal, or --paste"
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
            try config.write()
            print("✓ saved Parrot defaults")
            try Show().run()
            print("restart a running Parrot daemon to apply the change")
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reset hotkey, model, mode, and delivery to built-in defaults."
        )

        func run() throws {
            var config = Config.load()
            config.hotkey = nil
            config.model = nil
            config.mode = nil
            config.journalPath = nil
            try config.write()
            print("✓ reset hotkey, model, mode, and delivery defaults")
            print("restart a running Parrot daemon to apply the change")
        }
    }
}

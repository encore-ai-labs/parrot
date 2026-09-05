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

        func validate() throws {
            guard hotkey != nil || model != nil || mode != nil else {
                throw ValidationError("provide at least one of --hotkey, --model, or --mode")
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
        }

        func run() throws {
            guard hotkey != nil || model != nil || mode != nil else {
                throw ValidationError("provide at least one of --hotkey, --model, or --mode")
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
            try config.write()
            print("✓ saved Parrot defaults")
            try Show().run()
            print("restart a running Parrot daemon to apply the change")
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reset hotkey, model, and mode to built-in defaults."
        )

        func run() throws {
            var config = Config.load()
            config.hotkey = nil
            config.model = nil
            config.mode = nil
            try config.write()
            print("✓ reset hotkey, model, and mode defaults")
            print("restart a running Parrot daemon to apply the change")
        }
    }
}

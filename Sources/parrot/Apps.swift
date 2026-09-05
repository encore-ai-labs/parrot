import AppKit
import ArgumentParser
import Foundation

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Switch dictation mode locally based on the frontmost application.",
        subcommands: [List.self, Add.self, Remove.self, Clear.self, Current.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List app-mode rules.")

        func run() {
            let rules = Config.load().savedAppRules
            guard !rules.isEmpty else {
                print("no app-mode rules")
                print("add one with `parrot apps add Notes --mode notes`")
                return
            }
            for rule in rules {
                let name = rule.applicationName ?? rule.bundleIdentifier
                print("\(name)  \(rule.bundleIdentifier)  → \(rule.mode.rawValue)")
            }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add or replace a rule using a running app name or bundle id."
        )

        @Argument(help: "Running app name (for example Notes) or bundle identifier.")
        var application: String

        @Option(name: .long, help: "Mode to activate: dictation or notes.")
        var mode: String

        func validate() throws {
            guard DictationMode.parse(mode) != nil else {
                throw ValidationError("unknown mode '\(mode)'; use dictation or notes")
            }
        }

        func run() throws {
            guard let identity = ApplicationIdentity.resolve(application) else {
                throw ValidationError(
                    "couldn't find '\(application)'; open the app or pass its bundle identifier"
                )
            }
            guard let parsedMode = DictationMode.parse(mode) else {
                throw ValidationError("unknown mode '\(mode)'; use dictation or notes")
            }
            var config = Config.load()
            config.setAppRule(AppModeRule(
                bundleIdentifier: identity.bundleIdentifier,
                applicationName: identity.name,
                mode: parsedMode
            ))
            try config.write()
            print("✓ \(identity.name ?? identity.bundleIdentifier) → \(parsedMode.rawValue)")
            print("applies on the next recording; no daemon restart needed")
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a rule by saved app name or bundle id."
        )

        @Argument(help: "Saved app name or bundle identifier.")
        var application: String

        func run() throws {
            var config = Config.load()
            guard let removed = config.removeAppRule(matching: application) else {
                throw ValidationError("no app-mode rule matches '\(application)'")
            }
            try config.write()
            print("✓ removed \(removed.applicationName ?? removed.bundleIdentifier)")
        }
    }

    struct Clear: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove every app-mode rule.")

        func run() throws {
            var config = Config.load()
            let count = config.savedAppRules.count
            config.appRules = nil
            try config.write()
            print("✓ removed \(count) app-mode rule\(count == 1 ? "" : "s")")
        }
    }

    struct Current: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the currently frontmost application's identity."
        )

        func run() throws {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  let bundleIdentifier = app.bundleIdentifier
            else { throw ValidationError("no frontmost application was found") }
            print("\(app.localizedName ?? "unknown")  \(bundleIdentifier)")
        }
    }
}

struct ApplicationIdentity: Equatable {
    let bundleIdentifier: String
    let name: String?

    static func resolve(
        _ query: String,
        runningApplications: [NSRunningApplication] = NSWorkspace.shared.runningApplications
    ) -> ApplicationIdentity? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let app = runningApplications.first(where: { application in
            application.bundleIdentifier?.caseInsensitiveCompare(normalized) == .orderedSame
                || application.localizedName?.caseInsensitiveCompare(normalized) == .orderedSame
        }), let bundleIdentifier = app.bundleIdentifier {
            return ApplicationIdentity(
                bundleIdentifier: bundleIdentifier,
                name: app.localizedName
            )
        }
        guard looksLikeBundleIdentifier(normalized) else { return nil }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: normalized)
        let name = url.flatMap { Bundle(url: $0)?.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String } ?? url?.deletingPathExtension().lastPathComponent
        return ApplicationIdentity(bundleIdentifier: normalized, name: name)
    }

    static func looksLikeBundleIdentifier(_ value: String) -> Bool {
        value.contains(".")
            && value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
            }
    }
}

import ArgumentParser
import Foundation

struct Fillers: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage personal words and phrases removed from dictation locally.",
        subcommands: [List.self, Add.self, Remove.self, Path.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        func run() throws {
            let library = try PersonalFillerLibrary.load()
            guard !library.entries.isEmpty else {
                print("no personal fillers yet")
                print("add one with: parrot fillers add 'you know'")
                return
            }
            for entry in library.entries.sorted(by: {
                $0.phrase.localizedCaseInsensitiveCompare($1.phrase) == .orderedAscending
            }) {
                print("  \(entry.phrase)")
            }
            print("\nlocal file: \(PersonalFillerLibrary.url.path)")
            print("these explicit phrases are removed even when general cleanup is off")
        }
    }

    struct Add: ParsableCommand {
        @Argument(help: "Standalone word or phrase to remove (up to 6 words).")
        var phrase: String

        func run() throws {
            var library = try PersonalFillerLibrary.load()
            let updated = try library.set(phrase)
            try library.save()
            print("✓ \(updated ? "updated" : "added") personal filler: \(phrase)")
            print("active on the next recording — no daemon restart needed")
        }
    }

    struct Remove: ParsableCommand {
        @Argument(help: "Personal filler word or phrase to keep again.")
        var phrase: String

        func run() throws {
            var library = try PersonalFillerLibrary.load()
            guard library.remove(phrase) else {
                throw ValidationError("no personal filler matches '\(phrase)'")
            }
            try library.save()
            print("✓ removed personal filler: \(phrase)")
            print("active on the next recording — no daemon restart needed")
        }
    }

    struct Path: ParsableCommand {
        func run() {
            print(PersonalFillerLibrary.url.path)
        }
    }
}

import ArgumentParser
import Foundation

struct Snippets: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage reusable local text expanded by voice.",
        subcommands: [List.self, Add.self, Show.self, Remove.self, Path.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        func run() throws {
            let library = try SnippetLibrary.load()
            guard !library.entries.isEmpty else {
                print("no snippets yet")
                print("add one with: parrot snippets add signature --text 'Thanks, Parth'")
                return
            }
            for entry in library.entries.sorted(by: {
                $0.trigger.localizedCaseInsensitiveCompare($1.trigger) == .orderedAscending
            }) {
                print("  \(entry.trigger)  →  \(snippetPreview(entry.content))")
            }
            print("\nsay: insert snippet <trigger>")
            print("local file: \(SnippetLibrary.url.path)")
        }
    }

    struct Add: ParsableCommand {
        @Argument(help: "Short words to say after 'insert snippet'.")
        var trigger: String

        @Option(name: .long, help: "Exact text to insert.")
        var text: String?

        @Option(name: .long, help: "UTF-8 file whose contents should be inserted; use - for stdin.")
        var file: String?

        mutating func validate() throws {
            guard (text == nil) != (file == nil) else {
                throw ValidationError("pass exactly one of --text or --file")
            }
        }

        func run() throws {
            let content: String
            if let text {
                content = text
            } else if let file {
                content = try readSnippetFile(file)
            } else {
                throw ValidationError("pass exactly one of --text or --file")
            }
            var library = try SnippetLibrary.load()
            let updated = try library.set(trigger: trigger, content: content)
            try library.save()
            print("✓ \(updated ? "updated" : "added") snippet \(trigger)")
            print("say: insert snippet \(trigger)")
            print("active on the next recording — no daemon restart needed")
        }
    }

    struct Show: ParsableCommand {
        @Argument(help: "Snippet trigger to print.")
        var trigger: String

        func run() throws {
            let library = try SnippetLibrary.load()
            guard let entry = library.entry(matching: trigger) else {
                throw ValidationError("no snippet matches '\(trigger)'")
            }
            print(entry.content)
        }
    }

    struct Remove: ParsableCommand {
        @Argument(help: "Snippet trigger to remove.")
        var trigger: String

        func run() throws {
            var library = try SnippetLibrary.load()
            guard library.remove(trigger: trigger) else {
                throw ValidationError("no snippet matches '\(trigger)'")
            }
            try library.save()
            print("✓ removed snippet \(trigger)")
            print("active on the next recording — no daemon restart needed")
        }
    }

    struct Path: ParsableCommand {
        func run() {
            print(SnippetLibrary.url.path)
        }
    }
}

private func readSnippetFile(_ path: String) throws -> String {
    let data: Data
    if path == "-" {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ValidationError("couldn't read \(url.path): \(error.localizedDescription)")
        }
    }
    guard let content = String(data: data, encoding: .utf8) else {
        throw ValidationError("snippet file must be UTF-8 text")
    }
    return content
}

private func snippetPreview(_ content: String, maximumLength: Int = 72) -> String {
    let singleLine = content.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    guard singleLine.count > maximumLength else { return singleLine }
    return String(singleLine.prefix(maximumLength - 1)) + "…"
}

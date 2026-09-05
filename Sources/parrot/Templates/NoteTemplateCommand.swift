import ArgumentParser
import Foundation

enum NoteTemplatePreset: String, CaseIterable, ExpressibleByArgument {
    case daily
    case meeting
    case standup
    case research

    var body: String {
        switch self {
        case .daily:
            return "# Daily note — {{date}}\n\n{{transcript}}"
        case .meeting:
            return "# Meeting — {{date}}\n\n## Notes\n\n{{transcript}}\n\n## Follow-ups\n\n- [ ] "
        case .standup:
            return "# Standup — {{date}}\n\n{{transcript}}\n\n## Blockers\n\n- None"
        case .research:
            return "# Research note — {{date}}\n\n{{transcript}}\n\n## Open questions\n\n- "
        }
    }
}

struct Templates: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage deterministic local Markdown note templates.",
        subcommands: [List.self, Add.self, Show.self, Use.self, Off.self, Remove.self, Path.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        func run() throws {
            let library = try NoteTemplateLibrary.load()
            let active = Config.load().noteTemplate
            guard !library.entries.isEmpty else {
                print("no note templates yet")
                print("add a starter: parrot templates add daily --preset daily")
                return
            }
            for entry in library.entries.sorted(by: {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }) {
                let mark = active.flatMap { library.canonicalName(matching: $0) } == entry.name
                    ? "★" : " "
                print("\(mark) \(entry.name)  →  \(templatePreview(entry.body))")
            }
            print("\nsay: template <name>, then dictate the note")
            print("★ = saved default for note mode")
            print("local file: \(NoteTemplateLibrary.url.path)")
        }
    }

    struct Add: ParsableCommand {
        @Argument(help: "Short name to say after 'template'.")
        var name: String

        @Option(name: .long, help: "Exact template text containing {{transcript}}.")
        var text: String?

        @Option(name: .long, help: "UTF-8 template file; use - for stdin.")
        var file: String?

        @Option(name: .long, help: "Starter structure: daily, meeting, standup, or research.")
        var preset: NoteTemplatePreset?

        func validate() throws {
            guard [text != nil, file != nil, preset != nil].filter({ $0 }).count == 1 else {
                throw ValidationError("pass exactly one of --text, --file, or --preset")
            }
        }

        func run() throws {
            let body: String
            if let text {
                body = text
            } else if let file {
                body = try readTemplateFile(file)
            } else if let preset {
                body = preset.body
            } else {
                throw ValidationError("pass exactly one of --text, --file, or --preset")
            }
            var library = try NoteTemplateLibrary.load()
            let updated = try library.set(name: name, body: body)
            try library.save()
            let canonical = library.canonicalName(matching: name) ?? name
            print("✓ \(updated ? "updated" : "added") note template \(canonical)")
            print("say: template \(canonical), then dictate the note")
            print("active on the next recording — no daemon restart needed")
        }
    }

    struct Show: ParsableCommand {
        @Argument(help: "Template name to print.")
        var name: String

        func run() throws {
            let library = try NoteTemplateLibrary.load()
            guard let entry = library.entry(matching: name) else {
                throw ValidationError("no note template matches '\(name)'")
            }
            print(entry.body)
        }
    }

    struct Use: ParsableCommand {
        @Argument(help: "Template to make the note-mode default.")
        var name: String

        func run() throws {
            let library = try NoteTemplateLibrary.load()
            guard let canonical = library.canonicalName(matching: name) else {
                throw ValidationError("no note template matches '\(name)'")
            }
            var config = Config.load()
            config.noteTemplate = canonical
            config.mode = .notes
            try config.write()
            print("✓ using \(canonical) for note mode")
            print("restart a running Parrot daemon to change its saved default")
        }
    }

    struct Off: ParsableCommand {
        func run() throws {
            var config = Config.load()
            config.noteTemplate = nil
            try config.write()
            print("✓ note template default disabled; note mode remains unchanged")
            print("restart a running Parrot daemon to apply the change")
        }
    }

    struct Remove: ParsableCommand {
        @Argument(help: "Template name to remove.")
        var name: String

        func run() throws {
            var library = try NoteTemplateLibrary.load()
            guard let canonical = library.canonicalName(matching: name) else {
                throw ValidationError("no note template matches '\(name)'")
            }
            if let active = Config.load().noteTemplate,
               library.canonicalName(matching: active) == canonical {
                throw ValidationError("\(canonical) is active; run `parrot templates off` first")
            }
            _ = library.remove(name: canonical)
            try library.save()
            print("✓ removed note template \(canonical)")
            print("active on the next recording — no daemon restart needed")
        }
    }

    struct Path: ParsableCommand {
        func run() {
            print(NoteTemplateLibrary.url.path)
        }
    }
}

private func readTemplateFile(_ path: String) throws -> String {
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
        throw ValidationError("template file must be UTF-8 text")
    }
    return content
}

private func templatePreview(_ content: String, maximumLength: Int = 72) -> String {
    let singleLine = content.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard singleLine.count > maximumLength else { return singleLine }
    return String(singleLine.prefix(maximumLength - 1)) + "…"
}

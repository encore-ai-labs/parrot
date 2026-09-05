import AppKit
import ArgumentParser
import Foundation

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find and recover locally saved dictations.",
        subcommands: [
            List.self, Search.self, Show.self, Last.self, Copy.self, Audio.self, Path.self, Prune.self,
        ],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        @Option(name: [.short, .long], help: "Maximum entries to show (1...200).")
        var limit: Int = 20

        func run() throws {
            let records = try TranscriptHistoryReader().recent(limit: validatedLimit(limit))
            printRecords(records, emptyMessage: "no saved transcripts yet")
        }
    }

    struct Search: ParsableCommand {
        @Argument(help: "Words or phrase to find.")
        var query: [String]

        @Option(name: [.short, .long], help: "Maximum matches to show (1...200).")
        var limit: Int = 20

        func run() throws {
            let phrase = query.joined(separator: " ")
            guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("provide one or more search words")
            }
            let records = try TranscriptHistoryReader().search(
                phrase,
                limit: validatedLimit(limit)
            )
            printRecords(records, emptyMessage: "no transcripts matched '\(phrase)'")
        }
    }

    struct Show: ParsableCommand {
        @Argument(help: "Entry ID from list/search, or 'latest'.")
        var id: String = "latest"

        func run() throws {
            let record = try requireRecord(id)
            print("# \(record.id)\n")
            print(record.text)
        }
    }

    /// Print only transcript text, making command substitution and pipes clean.
    struct Last: ParsableCommand {
        func run() throws {
            print(try requireRecord("latest").text)
        }
    }

    struct Copy: ParsableCommand {
        @Argument(help: "Entry ID from list/search, or 'latest'.")
        var id: String = "latest"

        func run() throws {
            let record = try requireRecord(id)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(record.text, forType: .string) else {
                throw ValidationError("macOS did not accept the transcript on the clipboard")
            }
            print("✓ copied \(record.id)")
        }
    }

    struct Path: ParsableCommand {
        func run() throws {
            print(TranscriptHistory.defaultDirectory.path)
        }
    }

    struct Audio: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Review or reprocess explicitly retained local recording audio.",
            subcommands: [List.self, Path.self, Play.self, Reprocess.self, Delete.self, Clear.self],
            defaultSubcommand: List.self
        )

        struct List: ParsableCommand {
            @Option(name: [.short, .long], help: "Maximum recordings to show (1...200).")
            var limit: Int = 20

            func run() throws {
                let recordings = try HistoryAudioArchive().recordings()
                let records = try TranscriptHistoryReader().all()
                var textByID: [String: String] = [:]
                for record in records { textByID[record.id] = record.text }
                let selected = recordings.prefix(try validatedLimit(limit))
                guard !selected.isEmpty else {
                    print("no retained recording audio")
                    print("enable it with: parrot settings set --audio-history-days 7")
                    return
                }
                for recording in selected {
                    let size = ByteCountFormatter.string(
                        fromByteCount: recording.bytes,
                        countStyle: .file
                    )
                    let summary = textByID[recording.id].map { "  \(excerpt($0))" } ?? ""
                    print("\(recording.id)  \(size)\(summary)")
                }
            }
        }

        struct Path: ParsableCommand {
            func run() {
                print(HistoryAudioArchive.defaultDirectory.path)
            }
        }

        struct Play: ParsableCommand {
            @Argument(help: "Recording ID from `parrot history audio`, or 'latest'.")
            var id: String = "latest"

            func run() throws {
                let recording = try requireArchivedRecording(id)
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                task.arguments = [recording.url.path]
                try task.run()
                task.waitUntilExit()
                guard task.terminationStatus == 0 else {
                    throw ValidationError("macOS could not open recording \(recording.id)")
                }
            }
        }

        struct Reprocess: ParsableCommand {
            @Argument(help: "Recording ID from `parrot history audio`, or 'latest'.")
            var id: String = "latest"

            @Option(name: .long, help: "Model id; defaults to the current saved model.")
            var model: String?

            @Option(name: .long, help: "Language code/name, or auto; defaults to the saved value.")
            var language: String?

            @Flag(name: .long, help: "Reprocess with local Markdown note formatting.")
            var notes = false

            @Flag(name: .long, help: "Reprocess with plain dictation formatting.")
            var dictation = false

            @Flag(name: .long, help: "Apply deterministic local speech cleanup.")
            var cleanup = false

            @Flag(name: .customLong("no-cleanup"), help: "Preserve speech disfluencies.")
            var noCleanup = false

            @Flag(name: .long, help: "Lowercase the reprocessed text.")
            var lowercase = false

            @Flag(name: .customLong("no-lowercase"), help: "Preserve transcript casing.")
            var noLowercase = false

            @Flag(name: .customLong("auto-paragraphs"), help: "Use pause-aware note paragraphs.")
            var automaticParagraphs = false

            @Flag(name: .customLong("no-auto-paragraphs"), help: "Keep note output continuous.")
            var noAutomaticParagraphs = false

            @Flag(name: .customLong("no-vocabulary"), help: "Ignore saved personal vocabulary.")
            var noVocabulary = false

            @Flag(name: .customLong("no-fillers"), help: "Preserve saved personal filler phrases.")
            var noFillers = false

            @Flag(name: .customLong("no-snippets"), help: "Ignore saved voice snippets.")
            var noSnippets = false

            func validate() throws {
                guard !(notes && dictation) else {
                    throw ValidationError("pass at most one of --notes or --dictation")
                }
                guard !(cleanup && noCleanup) else {
                    throw ValidationError("pass at most one of --cleanup or --no-cleanup")
                }
                guard !(lowercase && noLowercase) else {
                    throw ValidationError("pass at most one of --lowercase or --no-lowercase")
                }
                guard !(automaticParagraphs && noAutomaticParagraphs) else {
                    throw ValidationError(
                        "pass at most one of --auto-paragraphs or --no-auto-paragraphs"
                    )
                }
            }

            func run() throws {
                let recording = try requireArchivedRecording(id)
                let arguments = transcriptionArguments(for: recording.url)
                guard var command = try Transcribe.parseAsRoot(arguments) as? Transcribe else {
                    throw ValidationError("couldn't prepare local reprocessing")
                }
                try command.run()
            }

            func transcriptionArguments(for url: URL) -> [String] {
                var arguments = [url.path, "--stdout", "--format", "text"]
                if let model { arguments.append(contentsOf: ["--model", model]) }
                if let language { arguments.append(contentsOf: ["--language", language]) }
                if notes { arguments.append("--notes") }
                if dictation { arguments.append("--dictation") }
                if cleanup { arguments.append("--cleanup") }
                if noCleanup { arguments.append("--no-cleanup") }
                if lowercase { arguments.append("--lowercase") }
                if noLowercase { arguments.append("--no-lowercase") }
                if automaticParagraphs { arguments.append("--auto-paragraphs") }
                if noAutomaticParagraphs { arguments.append("--no-auto-paragraphs") }
                if noVocabulary { arguments.append("--no-vocabulary") }
                if noFillers { arguments.append("--no-fillers") }
                if noSnippets { arguments.append("--no-snippets") }
                return arguments
            }
        }

        struct Clear: ParsableCommand {
            @Flag(name: .long, help: "Delete retained audio while keeping transcript text.")
            var confirm = false

            func run() throws {
                guard confirm else {
                    let count = try HistoryAudioArchive().recordings().count
                    print("preview: delete \(count) retained recording\(count == 1 ? "" : "s")")
                    print("transcript Markdown remains · rerun with --confirm to apply")
                    return
                }
                let result = try HistoryAudioArchive().clear()
                let bytes = ByteCountFormatter.string(
                    fromByteCount: result.bytesRemoved,
                    countStyle: .file
                )
                print(
                    "✓ deleted \(result.recordingsRemoved) retained recording"
                        + "\(result.recordingsRemoved == 1 ? "" : "s") · \(bytes)"
                )
            }
        }

        struct Delete: ParsableCommand {
            @Argument(help: "Recording ID from `parrot history audio`, or 'latest'.")
            var id: String = "latest"

            @Flag(name: .long, help: "Delete this audio while keeping transcript text.")
            var confirm = false

            func run() throws {
                let recording = try requireArchivedRecording(id)
                guard confirm else {
                    print("preview: delete retained audio \(recording.id)")
                    print("transcript Markdown remains · rerun with --confirm to apply")
                    return
                }
                guard let deleted = try HistoryAudioArchive().delete(recording.id) else {
                    throw ValidationError("retained recording disappeared before deletion")
                }
                let size = ByteCountFormatter.string(
                    fromByteCount: deleted.bytes,
                    countStyle: .file
                )
                print("✓ deleted retained audio \(deleted.id) · \(size)")
            }
        }
    }

    struct Prune: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Preview or remove transcript history outside a rolling retention window."
        )

        @Option(
            name: .customLong("keep-days"),
            help: "Keep the newest 1...3650 rolling days; defaults to the saved policy."
        )
        var keepDays: Int?

        @Flag(
            name: .long,
            help: "Apply the cleanup. Without this flag, Parrot only previews it."
        )
        var confirm: Bool = false

        func validate() throws {
            if let keepDays {
                _ = try HistoryRetentionPolicy(days: keepDays)
            }
        }

        func run() throws {
            let configured = Config.load().historyRetentionDays
            guard let days = keepDays ?? configured else {
                throw ValidationError(
                    "no retention is saved; pass --keep-days or configure "
                        + "`parrot settings set --history-retention-days <days>`"
                )
            }
            let policy = try HistoryRetentionPolicy(days: days)
            let pruner = HistoryRetentionPruner()
            let plan = try confirm
                ? pruner.prune(policy: policy)
                : pruner.preview(policy: policy)
            printPrunePlan(plan, confirmed: confirm)
            if confirm {
                do {
                    let validIDs = Set(try TranscriptHistoryReader().all().map(\.id))
                    let audio = try HistoryAudioArchive().pruneOrphans(
                        validTranscriptIDs: validIDs
                    )
                    if audio.recordingsRemoved > 0 {
                        let bytes = ByteCountFormatter.string(
                            fromByteCount: audio.bytesRemoved,
                            countStyle: .file
                        )
                        print(
                            "✓ deleted \(audio.recordingsRemoved) paired audio recording"
                                + "\(audio.recordingsRemoved == 1 ? "" : "s") · \(bytes)"
                        )
                    }
                } catch {
                    FileHandle.standardError.write(Data(
                        "warning: couldn't prune paired audio: \(error.localizedDescription)\n".utf8
                    ))
                }
            }
        }
    }
}

private func printPrunePlan(_ plan: HistoryPrunePlan, confirmed: Bool) {
    guard !plan.actions.isEmpty else {
        print("✓ no transcript history is older than the retention cutoff")
        return
    }
    for action in plan.actions {
        let verb: String
        switch action {
        case .delete:
            verb = confirmed ? "deleted" : "delete"
        case .rewrite:
            verb = confirmed ? "trimmed" : "trim"
        }
        let noun = action.entries == 1 ? "entry" : "entries"
        print("  \(verb) \(action.url.lastPathComponent)  ·  \(action.entries) \(noun)")
    }
    let bytes = ByteCountFormatter.string(
        fromByteCount: Int64(plan.bytesRemoved),
        countStyle: .file
    )
    if confirmed {
        print(
            "✓ removed \(plan.entriesRemoved) "
                + "\(plan.entriesRemoved == 1 ? "entry" : "entries") from "
                + "\(plan.filesAffected) "
                + "\(plan.filesAffected == 1 ? "file" : "files") · \(bytes)"
        )
    } else {
        print(
            "preview: \(plan.entriesRemoved) "
                + "\(plan.entriesRemoved == 1 ? "entry" : "entries") · \(bytes)"
        )
        print("no transcript files changed · rerun with --confirm to apply")
    }
}

private func validatedLimit(_ limit: Int) throws -> Int {
    guard (1...200).contains(limit) else {
        throw ValidationError("--limit must be between 1 and 200")
    }
    return limit
}

private func requireRecord(_ id: String) throws -> TranscriptRecord {
    guard let record = try TranscriptHistoryReader().resolve(id) else {
        throw ValidationError("no unique transcript matches '\(id)'")
    }
    return record
}

private func requireArchivedRecording(_ id: String) throws -> ArchivedRecording {
    guard let recording = try HistoryAudioArchive().resolve(id) else {
        throw ValidationError("no unique retained recording matches '\(id)'")
    }
    return recording
}

private func printRecords(_ records: [TranscriptRecord], emptyMessage: String) {
    guard !records.isEmpty else {
        print(emptyMessage)
        return
    }
    for record in records {
        let language = record.language.map { " [\($0)]" } ?? ""
        print("\(record.id)\(language)  \(excerpt(record.text))")
    }
}

private func excerpt(_ text: String, maximumLength: Int = 88) -> String {
    let singleLine = text.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    guard singleLine.count > maximumLength else { return singleLine }
    return String(singleLine.prefix(maximumLength - 1)) + "…"
}

import AppKit
import ArgumentParser
import Foundation

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find and recover locally saved dictations.",
        subcommands: [List.self, Search.self, Show.self, Last.self, Copy.self, Path.self, Prune.self],
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

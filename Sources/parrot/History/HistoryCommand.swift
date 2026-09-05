import AppKit
import ArgumentParser
import Foundation

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find and recover locally saved dictations.",
        subcommands: [List.self, Search.self, Show.self, Last.self, Copy.self, Path.self],
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

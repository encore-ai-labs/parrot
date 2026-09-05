import Foundation
import XCTest

@testable import parrot

final class HistoryExportTests: XCTestCase {
    func testExportCommandParsesDateSearchFormatAndRecoveryOptions() throws {
        let command = try XCTUnwrap(
            try History.parseAsRoot([
                "export",
                "--since", "2024-09-01",
                "--until", "2024-09-05",
                "--query", "project roadmap",
                "--format", "jsonl",
                "--original",
                "--output", "/tmp/notes.jsonl",
                "--force",
            ]) as? History.Export
        )

        XCTAssertEqual(command.since, "2024-09-01")
        XCTAssertEqual(command.until, "2024-09-05")
        XCTAssertNil(command.period)
        XCTAssertEqual(command.query, "project roadmap")
        XCTAssertEqual(command.format, .jsonl)
        XCTAssertTrue(command.original)
        XCTAssertEqual(command.output, "/tmp/notes.jsonl")
        XCTAssertTrue(command.force)
        XCTAssertThrowsError(try History.parseAsRoot(["export", "--format", "xml"]))
        XCTAssertThrowsError(try History.parseAsRoot(["export", "--force"]))
        XCTAssertThrowsError(try History.parseAsRoot([
            "export", "--period", "week", "--since", "2024-09-01",
        ]))

        let weekly = try XCTUnwrap(
            try History.parseAsRoot(["export", "--period", "week"]) as? History.Export
        )
        XCTAssertEqual(weekly.period, .week)
    }

    func testDateRangeIsStrictAndIncludesTheWholeUntilDay() throws {
        let calendar = utcCalendar()
        let range = try HistoryExportRange(
            since: "2024-09-04",
            until: "2024-09-05",
            calendar: calendar
        )

        XCTAssertFalse(range.contains(try date(2024, 9, 3, 23, 59, 59, calendar)))
        XCTAssertTrue(range.contains(try date(2024, 9, 4, 0, 0, 0, calendar)))
        XCTAssertTrue(range.contains(try date(2024, 9, 5, 23, 59, 59, calendar)))
        XCTAssertFalse(range.contains(try date(2024, 9, 6, 0, 0, 0, calendar)))

        XCTAssertThrowsError(try HistoryExportRange(
            since: "2024-02-30", until: nil, calendar: calendar
        ))
        XCTAssertThrowsError(try HistoryExportRange(
            since: "09/04/2024", until: nil, calendar: calendar
        ))
        XCTAssertThrowsError(try HistoryExportRange(
            since: "2024-09-06", until: "2024-09-05", calendar: calendar
        ))
    }

    func testConveniencePeriodUsesLocalCalendarBoundaries() throws {
        var calendar = utcCalendar()
        calendar.firstWeekday = 2
        let now = try date(2024, 9, 5, 12, 0, 0, calendar)

        let today = HistoryExportRange(period: .today, now: now, calendar: calendar)
        XCTAssertTrue(today.contains(try date(2024, 9, 5, 0, 0, 0, calendar)))
        XCTAssertFalse(today.contains(try date(2024, 9, 4, 23, 59, 59, calendar)))
        XCTAssertFalse(today.contains(try date(2024, 9, 6, 0, 0, 0, calendar)))

        let week = HistoryExportRange(period: .week, now: now, calendar: calendar)
        XCTAssertTrue(week.contains(try date(2024, 9, 2, 0, 0, 0, calendar)))
        XCTAssertFalse(week.contains(try date(2024, 9, 1, 23, 59, 59, calendar)))
        XCTAssertFalse(week.contains(try date(2024, 9, 9, 0, 0, 0, calendar)))

        let month = HistoryExportRange(period: .month, now: now, calendar: calendar)
        XCTAssertTrue(month.contains(try date(2024, 9, 1, 0, 0, 0, calendar)))
        XCTAssertFalse(month.contains(try date(2024, 8, 31, 23, 59, 59, calendar)))
        XCTAssertFalse(month.contains(try date(2024, 10, 1, 0, 0, 0, calendar)))
    }

    func testSelectionMatchesDeliveredOrOriginalTextAndReturnsChronologicalNotes() throws {
        let calendar = utcCalendar()
        let records = [
            record(
                id: "newest", date: try date(2024, 9, 6, 9, 0, 0, calendar),
                text: "unrelated"
            ),
            record(
                id: "second", date: try date(2024, 9, 5, 12, 0, 0, calendar),
                text: "Café launch roadmap"
            ),
            record(
                id: "first", date: try date(2024, 9, 4, 8, 0, 0, calendar),
                text: "Clean final note", original: "Um project roadmap draft"
            ),
        ]
        let range = try HistoryExportRange(
            since: "2024-09-04", until: "2024-09-05", calendar: calendar
        )

        XCTAssertEqual(
            try HistoryExporter.select(records, range: range, query: "ROADMAP").map(\.id),
            ["first", "second"]
        )
        XCTAssertEqual(
            try HistoryExporter.select(records, range: range, query: "cafe launch").map(\.id),
            ["second"]
        )
        XCTAssertThrowsError(try HistoryExporter.select(records, range: range, query: "  \n"))
        XCTAssertThrowsError(try HistoryExporter.select(
            records,
            range: range,
            query: String(repeating: "x", count: HistoryExporter.maximumQueryLength + 1)
        ))
    }

    func testRangedReaderSkipsDailyFilesThatCannotMatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-export-reader-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = utcCalendar()
        let store = TranscriptHistory(directory: directory, calendar: calendar)
        _ = try await store.appendEntry(
            "September note",
            at: try date(2024, 9, 4, 8, 0, 0, calendar)
        )
        try Data([0xFF, 0xFE]).write(
            to: directory.appendingPathComponent("2024-08-01.md")
        )
        let range = try HistoryExportRange(
            since: "2024-09-04", until: "2024-09-04", calendar: calendar
        )

        let records = try TranscriptHistoryReader(
            directory: directory, calendar: calendar
        ).records(startingAt: range.start, endingBefore: range.endExclusive)
        XCTAssertEqual(records.map(\.text), ["September note"])
    }

    func testMarkdownExportGroupsDaysAndCanRecoverOriginalRecognition() throws {
        let calendar = utcCalendar()
        let records = [
            record(
                id: "one", date: try date(2024, 9, 4, 8, 30, 0, calendar),
                text: "Clean first note.", original: "Um clean first note."
            ),
            record(
                id: "two", date: try date(2024, 9, 4, 9, 45, 2, calendar),
                text: "- [ ] Ship it"
            ),
            record(
                id: "three", date: try date(2024, 9, 5, 7, 0, 0, calendar),
                text: "## Existing heading\n\nBody"
            ),
        ]

        let final = String(decoding: try HistoryExporter.render(
            records, format: .markdown, original: false, calendar: calendar
        ), as: UTF8.self)
        XCTAssertTrue(final.hasPrefix("# Parrot history export\n\n- Entries: 3\n- Text: delivered\n"))
        XCTAssertEqual(final.components(separatedBy: "\n## 2024-09-04\n").count - 1, 1)
        XCTAssertEqual(final.components(separatedBy: "\n## 2024-09-05\n").count - 1, 1)
        XCTAssertTrue(final.contains("### 09:45:02\n<!-- parrot-entry: two -->"))
        XCTAssertTrue(final.contains("- [ ] Ship it"))
        XCTAssertTrue(final.contains("## Existing heading\n\nBody"))
        XCTAssertFalse(final.contains("Um clean first note."))

        let original = String(decoding: try HistoryExporter.render(
            records, format: .markdown, original: true, calendar: calendar
        ), as: UTF8.self)
        XCTAssertTrue(original.contains("- Text: original recognition when available"))
        XCTAssertTrue(original.contains("Um clean first note."))
        XCTAssertTrue(original.contains("- [ ] Ship it"))
    }

    func testJSONLinesAreRoundTrippableAndCarryTimingMetadata() throws {
        let calendar = utcCalendar()
        let records = [record(
            id: "entry-1",
            date: try date(2024, 9, 4, 20, 38, 27, calendar),
            text: "Clean \"note\"\nwith two lines",
            original: "Um, clean note",
            audio: 3.364,
            processing: 0.084,
            language: "en",
            model: "whisper-base.en",
            mode: .notes
        )]

        let data = try HistoryExporter.render(
            records, format: .jsonl, original: false, calendar: calendar
        )
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["id"] as? String, "entry-1")
        XCTAssertEqual(json["recordedAt"] as? String, "2024-09-04T20:38:27.000Z")
        XCTAssertEqual(json["text"] as? String, "Clean \"note\"\nwith two lines")
        XCTAssertEqual(json["textSource"] as? String, "delivered")
        XCTAssertEqual(json["originalText"] as? String, "Um, clean note")
        XCTAssertEqual(json["language"] as? String, "en")
        XCTAssertEqual(json["model"] as? String, "whisper-base.en")
        XCTAssertEqual(json["mode"] as? String, "notes")
        XCTAssertEqual(try XCTUnwrap(json["realtimeFactor"] as? Double), 0.084 / 3.364, accuracy: 0.000_001)

        let recovered = try HistoryExporter.render(
            records, format: .jsonl, original: true, calendar: calendar
        )
        let recoveredJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(String(decoding: recovered, as: UTF8.self).dropLast().utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(recoveredJSON["text"] as? String, "Um, clean note")
        XCTAssertEqual(recoveredJSON["textSource"] as? String, "original")
        XCTAssertEqual(recoveredJSON["deliveredText"] as? String, records[0].text)
        XCTAssertNil(recoveredJSON["originalText"])
    }

    func testExportFileIsPrivateAtomicAndNoClobberByDefault() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-export-writer-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("nested/notes.md")

        try SafeTranscriptWriter.write(Data("first".utf8), to: output, force: false)
        XCTAssertEqual(try String(contentsOf: output), "first")
        XCTAssertEqual(permissions(at: output), 0o600)
        XCTAssertEqual(permissions(at: output.deletingLastPathComponent()), 0o700)

        XCTAssertThrowsError(try SafeTranscriptWriter.write(
            Data("must not replace".utf8), to: output, force: false
        ))
        XCTAssertEqual(try String(contentsOf: output), "first")

        try SafeTranscriptWriter.write(Data("replacement".utf8), to: output, force: true)
        XCTAssertEqual(try String(contentsOf: output), "replacement")
        XCTAssertEqual(permissions(at: output), 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: output.deletingLastPathComponent().path
        ).filter { $0.hasPrefix(".parrot-transcript.") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testExportSelectionAndRenderingCostAcrossFiveThousandNotes() throws {
        let calendar = utcCalendar()
        let start = try date(2024, 9, 1, 0, 0, 0, calendar)
        let records = (0..<5_000).map { index in
            record(
                id: "entry-\(index)",
                date: start.addingTimeInterval(TimeInterval(index)),
                text: index.isMultiple(of: 17)
                    ? "project roadmap note \(index)"
                    : "ordinary private note \(index)"
            )
        }
        let range = try HistoryExportRange(since: nil, until: nil, calendar: calendar)
        var output = Data()

        measure {
            let selected = try! HistoryExporter.select(
                records, range: range, query: "project roadmap"
            )
            output = try! HistoryExporter.render(
                selected, format: .jsonl, original: false, calendar: calendar
            )
        }
        XCTAssertFalse(output.isEmpty)
    }

    private func record(
        id: String,
        date: Date,
        text: String,
        original: String? = nil,
        audio: TimeInterval? = nil,
        processing: TimeInterval? = nil,
        language: String? = nil,
        model: String? = nil,
        mode: DictationMode? = nil
    ) -> TranscriptRecord {
        TranscriptRecord(
            id: id,
            recordedAt: date,
            text: text,
            originalText: original,
            fileURL: URL(fileURLWithPath: "/history/2024-09-04.md"),
            audioDuration: audio,
            processingDuration: processing,
            language: language,
            modelID: model,
            mode: mode
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ second: Int,
        _ calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )))
    }
}

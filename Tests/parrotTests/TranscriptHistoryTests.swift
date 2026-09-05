import XCTest

@testable import parrot

final class TranscriptHistoryTests: XCTestCase {
    func testHistorySearchAcceptsMultipleWordsAndTrailingOptions() throws {
        let parsed = try History.Search.parseAsRoot([
            "project", "roadmap", "--limit", "7",
        ])
        let command = try XCTUnwrap(parsed as? History.Search)

        XCTAssertEqual(command.query, ["project", "roadmap"])
        XCTAssertEqual(command.limit, 7)
    }

    func testAppendsTranscriptsToPrivateDailyMarkdownFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-history-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = TranscriptHistory(directory: directory, calendar: calendar)
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2024, month: 9, day: 4, hour: 20, minute: 38, second: 27
        )))

        let firstURL = try await store.append("first transcript", at: date)
        let secondURL = try await store.append("second transcript", at: date.addingTimeInterval(5))

        XCTAssertEqual(firstURL, secondURL)
        let url = try XCTUnwrap(firstURL)
        XCTAssertEqual(url.lastPathComponent, "2024-09-04.md")
        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(markdown, """
        # Parrot transcripts — 2024-09-04

        <!-- parrot-entry: 20240904-203827-000 -->
        ## 20:38:27

        first transcript

        <!-- parrot-entry: 20240904-203832-000 -->
        ## 20:38:32

        second transcript

        """)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(fileAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
    }

    func testReadsSearchesAndResolvesMarkedHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-history-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = TranscriptHistory(directory: directory, calendar: calendar)
        let first = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2024, month: 9, day: 4, hour: 20, minute: 38, second: 27,
            nanosecond: 123_000_000
        )))
        try await store.append("RustPond planning\n\n## 12:34:56\n\nThis is note content.", at: first)
        try await store.append("Café follow-up with the design team", at: first.addingTimeInterval(5))

        let reader = TranscriptHistoryReader(directory: directory, calendar: calendar)
        let all = try reader.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].id, "20240904-203832-123")
        XCTAssertEqual(all[1].id, "20240904-203827-123")
        XCTAssertTrue(all[1].text.contains("## 12:34:56"))
        XCTAssertEqual(try reader.search("CAFE design", limit: 20).map(\.id), [all[0].id])
        XCTAssertEqual(try reader.resolve("203827-123")?.text, all[1].text)
        XCTAssertEqual(try reader.resolve("latest")?.id, all[0].id)
    }

    func testReadsLegacyHistoryAndDisambiguatesSameSecond() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-history-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("2024-09-04.md")
        try """
        # Parrot transcripts — 2024-09-04

        ## 20:38:27

        first

        ## 20:38:27

        second
        """.write(to: url, atomically: true, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let records = try TranscriptHistoryReader(directory: directory, calendar: calendar).all()

        XCTAssertEqual(Set(records.map(\.id)), ["20240904-203827", "20240904-203827-2"])
        XCTAssertEqual(Set(records.map(\.text)), ["first", "second"])
    }

    func testLocalSearchPerformanceAcrossTwoThousandEntries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-history-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var markdown = "# Parrot transcripts — 2024-09-04\n"
        for index in 0..<2_000 {
            let hour = index / 3_600
            let minute = (index % 3_600) / 60
            let second = index % 60
            let time = String(format: "%02d:%02d:%02d", hour, minute, second)
            let id = "20240904-\(time.replacingOccurrences(of: ":", with: ""))-000"
            let searchable = index == 1_337 ? "needle project roadmap" : "ordinary local note"
            markdown += "\n<!-- parrot-entry: \(id) -->\n## \(time)\n\n\(searchable) \(index)\n"
        }
        try markdown.write(
            to: directory.appendingPathComponent("2024-09-04.md"),
            atomically: true,
            encoding: .utf8
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reader = TranscriptHistoryReader(directory: directory, calendar: calendar)
        var matches: [TranscriptRecord] = []
        measure {
            matches = try! reader.search("project roadmap", limit: 20)
        }
        XCTAssertEqual(matches.map(\.text), ["needle project roadmap 1337"])
    }

    func testDoesNotCreateAFileForEmptyTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-history-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = TranscriptHistory(directory: directory)
        let result = try await store.append("  \n ")

        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}

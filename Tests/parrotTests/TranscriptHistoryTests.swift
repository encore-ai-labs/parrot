import XCTest

@testable import parrot

final class TranscriptHistoryTests: XCTestCase {
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

        ## 20:38:27

        first transcript

        ## 20:38:32

        second transcript

        """)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(fileAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
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

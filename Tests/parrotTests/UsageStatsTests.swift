import Foundation
import XCTest

@testable import parrot

final class UsageStatsTests: XCTestCase {
    func testSummarizesWordsTimingAndStreaksLocally() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try date(2024, 9, 4, 12, calendar: calendar)
        let url = URL(fileURLWithPath: "/tmp/history.md")
        let records = [
            TranscriptRecord(
                id: "a", recordedAt: try date(2024, 9, 4, 10, calendar: calendar),
                text: "hello brave world", fileURL: url,
                audioDuration: 3, processingDuration: 0.3
            ),
            TranscriptRecord(
                id: "b", recordedAt: try date(2024, 9, 3, 10, calendar: calendar),
                text: "two words", fileURL: url,
                audioDuration: 2, processingDuration: 0.2
            ),
            TranscriptRecord(
                id: "c", recordedAt: try date(2024, 9, 1, 10, calendar: calendar),
                text: "older note", fileURL: url,
                audioDuration: nil, processingDuration: nil
            ),
        ]

        let summary = UsageStats.summarize(
            records, now: now, calendar: calendar, typingWPM: 50
        )
        XCTAssertEqual(summary.dictations, 3)
        XCTAssertEqual(summary.words, 7)
        XCTAssertEqual(summary.activeDays, 3)
        XCTAssertEqual(summary.averageWordsPerDictation, 7.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(summary.currentStreakDays, 2)
        XCTAssertEqual(summary.longestStreakDays, 2)
        XCTAssertEqual(summary.measuredDictations, 2)
        XCTAssertEqual(summary.voiceSeconds, 5, accuracy: 0.0001)
        XCTAssertEqual(summary.processingSeconds, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.averageSpeakingWPM), 60, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.processingRealtimeFactor), 0.1, accuracy: 0.0001)
        XCTAssertEqual(summary.estimatedTypingSeconds, 8.4, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(summary.estimatedTimeSavedSeconds), 0.5, accuracy: 0.0001
        )
    }

    func testPeriodFilteringAndFutureRecords() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try date(2024, 9, 4, 12, calendar: calendar)
        let url = URL(fileURLWithPath: "/tmp/history.md")
        let records = [
            TranscriptRecord(
                id: "today", recordedAt: try date(2024, 9, 4, 8, calendar: calendar),
                text: "today", fileURL: url, audioDuration: nil, processingDuration: nil
            ),
            TranscriptRecord(
                id: "yesterday", recordedAt: try date(2024, 9, 3, 8, calendar: calendar),
                text: "yesterday", fileURL: url, audioDuration: nil, processingDuration: nil
            ),
            TranscriptRecord(
                id: "future", recordedAt: try date(2024, 9, 4, 18, calendar: calendar),
                text: "future", fileURL: url, audioDuration: nil, processingDuration: nil
            ),
        ]

        XCTAssertEqual(
            UsageStats.summarize(records, period: .today, now: now, calendar: calendar).dictations,
            1
        )
    }

    func testStatsCommandParsesAndValidatesOptions() throws {
        let command = try XCTUnwrap(
            try Stats.parseAsRoot(["--period", "week", "--typing-wpm", "55", "--json"])
                as? Stats
        )
        XCTAssertEqual(command.period, .week)
        XCTAssertEqual(command.typingWpm, 55)
        XCTAssertTrue(command.json)
        XCTAssertThrowsError(try Stats.parseAsRoot(["--typing-wpm", "0"]))
        XCTAssertThrowsError(try Stats.parseAsRoot(["--period", "year"]))
    }

    func testUnicodeWordCounting() {
        // Foundation's localized tokenizer treats the hyphenated form and
        // Chinese phrase as multiple lexical words rather than whitespace blobs.
        XCTAssertEqual(UsageStats.wordCount("Café déjà-vu — 你好世界"), 6)
        XCTAssertEqual(UsageStats.wordCount(""), 0)
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour
        )))
    }
}

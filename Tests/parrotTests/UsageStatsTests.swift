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
                audioDuration: 3, processingDuration: 0.3, enhancementDuration: 0.1,
                modelID: "whisper-base.en", mode: .dictation
            ),
            TranscriptRecord(
                id: "b", recordedAt: try date(2024, 9, 3, 10, calendar: calendar),
                text: "two words", fileURL: url,
                audioDuration: 2, processingDuration: 0.2,
                modelID: "whisper-base.en", mode: .notes
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
        XCTAssertEqual(summary.enhancementAttempts, 1)
        XCTAssertEqual(summary.enhancementSeconds, 0.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.averageEnhancementSeconds), 0.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.averageSpeakingWPM), 60, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(summary.processingRealtimeFactor), 0.1, accuracy: 0.0001)
        XCTAssertEqual(summary.estimatedTypingSeconds, 8.4, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(summary.estimatedTimeSavedSeconds), 0.5, accuracy: 0.0001
        )
        XCTAssertEqual(summary.models.count, 1)
        let model = try XCTUnwrap(summary.models.first)
        XCTAssertEqual(model.modelID, "whisper-base.en")
        XCTAssertEqual(model.dictations, 2)
        XCTAssertEqual(model.measuredDictations, 2)
        XCTAssertEqual(model.voiceSeconds, 5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(model.processingRealtimeFactor), 0.08, accuracy: 0.0001)
        XCTAssertEqual(
            summary.modes,
            [
                ModeUsageSummary(mode: .dictation, dictations: 1),
                ModeUsageSummary(mode: .notes, dictations: 1),
            ]
        )
    }

    func testModelStatsAreStableAndOnlyCompareFullyTimedDictations() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let url = URL(fileURLWithPath: "/tmp/history.md")
        let records = [
            TranscriptRecord(
                id: "fast-1", recordedAt: now.addingTimeInterval(-3), text: "one",
                fileURL: url, audioDuration: 10, processingDuration: 1,
                enhancementDuration: 0.25,
                modelID: "model-fast", mode: .notes
            ),
            TranscriptRecord(
                id: "fast-2", recordedAt: now.addingTimeInterval(-2), text: "two",
                fileURL: url, audioDuration: 5, processingDuration: nil,
                modelID: "model-fast", mode: .notes
            ),
            TranscriptRecord(
                id: "slow", recordedAt: now.addingTimeInterval(-1), text: "three",
                fileURL: url, audioDuration: 10, processingDuration: 5,
                modelID: "model-slow", mode: .dictation
            ),
        ]

        let summary = UsageStats.summarize(records, now: now)
        XCTAssertEqual(summary.models.map(\.modelID), ["model-fast", "model-slow"])
        XCTAssertEqual(summary.models[0].dictations, 2)
        XCTAssertEqual(summary.models[0].measuredDictations, 1)
        XCTAssertEqual(
            try XCTUnwrap(summary.models[0].processingRealtimeFactor), 0.075, accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(summary.models[1].processingRealtimeFactor), 0.5, accuracy: 0.0001
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

    func testModelAndModeStatsCostAcrossFiveThousandDictations() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let url = URL(fileURLWithPath: "/tmp/history.md")
        let models = [
            "whisper-base.en",
            "whisper-small.en",
            "parakeet-tdt-ctc-110m.en",
            "parakeet-unified.en",
        ]
        let records = (0..<5_000).map { index in
            TranscriptRecord(
                id: "entry-\(index)",
                recordedAt: now.addingTimeInterval(-TimeInterval(index)),
                text: "private note number \(index)",
                fileURL: url,
                audioDuration: 4,
                processingDuration: Double(index % 10) / 10,
                modelID: models[index % models.count],
                mode: index.isMultiple(of: 3) ? .notes : .dictation
            )
        }
        var summary: UsageSummary?

        measure {
            summary = UsageStats.summarize(records, now: now)
        }
        XCTAssertEqual(summary?.dictations, 5_000)
        XCTAssertEqual(summary?.models.count, 4)
        XCTAssertEqual(summary?.modes.count, 2)
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

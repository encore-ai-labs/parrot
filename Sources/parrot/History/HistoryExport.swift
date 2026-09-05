import Foundation

enum HistoryExportFormat: String, CaseIterable {
    case markdown
    case jsonl
}

struct HistoryExportRange: Equatable {
    let start: Date?
    let endExclusive: Date?

    init(since: String?, until: String?, calendar: Calendar = .current) throws {
        start = try since.map { try Self.startOfDay($0, option: "--since", calendar: calendar) }
        if let until {
            let finalDay = try Self.startOfDay(until, option: "--until", calendar: calendar)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: finalDay) else {
                throw HistoryExportError.invalidDate(until, option: "--until")
            }
            endExclusive = nextDay
        } else {
            endExclusive = nil
        }

        if let start, let endExclusive, start >= endExclusive {
            throw HistoryExportError.reversedRange
        }
    }

    init(period: StatsPeriod, now: Date = Date(), calendar: Calendar = .current) {
        switch period {
        case .all:
            start = nil
            endExclusive = nil
        case .today:
            let day = calendar.startOfDay(for: now)
            start = day
            endExclusive = calendar.date(byAdding: .day, value: 1, to: day)
        case .week:
            let interval = calendar.dateInterval(of: .weekOfYear, for: now)
            start = interval?.start
            endExclusive = interval?.end
        case .month:
            let interval = calendar.dateInterval(of: .month, for: now)
            start = interval?.start
            endExclusive = interval?.end
        }
    }

    func contains(_ date: Date) -> Bool {
        if let start, date < start { return false }
        if let endExclusive, date >= endExclusive { return false }
        return true
    }

    private static func startOfDay(
        _ raw: String,
        option: String,
        calendar: Calendar
    ) throws -> Date {
        let pieces = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              pieces[0].count == 4,
              pieces[1].count == 2,
              pieces[2].count == 2,
              let year = Int(pieces[0]),
              let month = Int(pieces[1]),
              let day = Int(pieces[2]),
              let date = calendar.date(from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day
              ))
        else {
            throw HistoryExportError.invalidDate(raw, option: option)
        }

        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else {
            throw HistoryExportError.invalidDate(raw, option: option)
        }
        return calendar.startOfDay(for: date)
    }
}

enum HistoryExporter {
    static let maximumQueryLength = 512

    static func select(
        _ records: [TranscriptRecord],
        range: HistoryExportRange,
        query rawQuery: String?
    ) throws -> [TranscriptRecord] {
        let query = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let query {
            guard !query.isEmpty else { throw HistoryExportError.emptyQuery }
            guard query.count <= maximumQueryLength else {
                throw HistoryExportError.queryTooLong(maximumQueryLength)
            }
        }
        let words = query.map(Self.fold)?.split(whereSeparator: \Character.isWhitespace)
            .map(String.init) ?? []

        return records.filter { record in
            guard range.contains(record.recordedAt) else { return false }
            guard !words.isEmpty else { return true }
            let searchable = Self.fold(
                record.text + (record.originalText.map { " \($0)" } ?? "")
            )
            return words.allSatisfy(searchable.contains)
        }
        .sorted {
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
            return $0.id < $1.id
        }
    }

    static func render(
        _ records: [TranscriptRecord],
        format: HistoryExportFormat,
        original: Bool,
        calendar: Calendar = .current
    ) throws -> Data {
        switch format {
        case .markdown:
            return Data(markdown(records, original: original, calendar: calendar).utf8)
        case .jsonl:
            return try jsonLines(records, original: original, calendar: calendar)
        }
    }

    private static func markdown(
        _ records: [TranscriptRecord],
        original: Bool,
        calendar: Calendar
    ) -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.dateFormat = "HH:mm:ss"

        var output = "# Parrot history export\n\n"
        output += "- Entries: \(records.count)\n"
        output += "- Text: \(original ? "original recognition when available" : "delivered")\n"

        var activeDay: String?
        for record in records {
            let day = dayFormatter.string(from: record.recordedAt)
            if day != activeDay {
                output += "\n## \(day)\n"
                activeDay = day
            }
            output += "\n### \(timeFormatter.string(from: record.recordedAt))\n"
            output += "<!-- parrot-entry: \(record.id) -->\n\n"
            output += selectedText(record, original: original)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            output += "\n"
        }
        return output
    }

    private static func jsonLines(
        _ records: [TranscriptRecord],
        original: Bool,
        calendar: Calendar
    ) throws -> Data {
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestamp.timeZone = calendar.timeZone
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var data = Data()
        for record in records {
            let hasOriginal = record.originalText != nil
            let row = JSONRow(
                schemaVersion: 1,
                id: record.id,
                recordedAt: timestamp.string(from: record.recordedAt),
                text: selectedText(record, original: original),
                textSource: original && hasOriginal ? "original" : "delivered",
                deliveredText: original && hasOriginal ? record.text : nil,
                originalText: original ? nil : record.originalText,
                audioSeconds: finiteNonnegative(record.audioDuration),
                processingSeconds: finiteNonnegative(record.processingDuration),
                realtimeFactor: realtimeFactor(record),
                language: record.language
            )
            data.append(try encoder.encode(row))
            data.append(0x0A)
        }
        return data
    }

    private static func selectedText(_ record: TranscriptRecord, original: Bool) -> String {
        original ? (record.originalText ?? record.text) : record.text
    }

    private static func finiteNonnegative(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func realtimeFactor(_ record: TranscriptRecord) -> Double? {
        guard let audio = finiteNonnegative(record.audioDuration), audio > 0,
              let processing = finiteNonnegative(record.processingDuration)
        else { return nil }
        return processing / audio
    }

    private static func fold(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .split(whereSeparator: \Character.isWhitespace)
        .joined(separator: " ")
    }

    private struct JSONRow: Encodable {
        let schemaVersion: Int
        let id: String
        let recordedAt: String
        let text: String
        let textSource: String
        let deliveredText: String?
        let originalText: String?
        let audioSeconds: TimeInterval?
        let processingSeconds: TimeInterval?
        let realtimeFactor: Double?
        let language: String?
    }
}

enum HistoryExportError: LocalizedError, Equatable {
    case invalidDate(String, option: String)
    case reversedRange
    case emptyQuery
    case queryTooLong(Int)

    var errorDescription: String? {
        switch self {
        case .invalidDate(let value, let option):
            return "\(option) must be a real date in YYYY-MM-DD form; got '\(value)'"
        case .reversedRange:
            return "--since must be on or before --until"
        case .emptyQuery:
            return "--query must contain one or more search words"
        case .queryTooLong(let maximum):
            return "--query supports at most \(maximum) characters"
        }
    }
}

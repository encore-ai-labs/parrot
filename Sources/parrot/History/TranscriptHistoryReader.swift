import Foundation

struct TranscriptRecord: Equatable {
    let id: String
    let recordedAt: Date
    let text: String
    let originalText: String?
    let fileURL: URL
    let audioDuration: TimeInterval?
    let processingDuration: TimeInterval?
    let enhancementDuration: TimeInterval?
    let language: String?
    let modelID: String?
    let mode: DictationMode?

    init(
        id: String,
        recordedAt: Date,
        text: String,
        originalText: String? = nil,
        fileURL: URL,
        audioDuration: TimeInterval? = nil,
        processingDuration: TimeInterval? = nil,
        enhancementDuration: TimeInterval? = nil,
        language: String? = nil,
        modelID: String? = nil,
        mode: DictationMode? = nil
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.text = text
        self.originalText = originalText
        self.fileURL = fileURL
        self.audioDuration = audioDuration
        self.processingDuration = processingDuration
        self.enhancementDuration = enhancementDuration
        self.language = language
        self.modelID = modelID
        self.mode = mode
    }
}

/// Read/search access over Parrot's user-owned Markdown history.
struct TranscriptHistoryReader {
    private let directory: URL
    private let calendar: Calendar

    init(
        directory: URL = TranscriptHistory.defaultDirectory,
        calendar: Calendar = .current
    ) {
        self.directory = directory
        self.calendar = calendar
    }

    func all() throws -> [TranscriptRecord] {
        try records(startingAt: nil, endingBefore: nil)
    }

    /// Reads only daily files that can overlap the requested interval. This
    /// keeps short-range exports fast even when history spans years.
    func records(startingAt start: Date?, endingBefore end: Date?) throws -> [TranscriptRecord] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try HistoryFileLock.withLock(directory: directory, mode: .shared) {
            try allUnlocked(startingAt: start, endingBefore: end)
        }
    }

    private func allUnlocked(startingAt start: Date?, endingBefore end: Date?) throws
        -> [TranscriptRecord]
    {
        let fileManager = FileManager.default
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            guard url.pathExtension == "md",
                  url.deletingPathExtension().lastPathComponent.range(
                    of: #"^\d{4}-\d{2}-\d{2}$"#,
                    options: .regularExpression
                  ) != nil,
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  )
            else { return false }
            guard values.isRegularFile == true && values.isSymbolicLink != true,
                  let day = dailyFileDate(url),
                  let followingDay = calendar.date(byAdding: .day, value: 1, to: day)
            else { return false }
            if let start, followingDay <= start { return false }
            if let end, day >= end { return false }
            return true
        }

        var records: [TranscriptRecord] = []
        for url in urls {
            let markdown = try String(contentsOf: url, encoding: .utf8)
            records.append(contentsOf: parse(markdown, fileURL: url))
        }
        return records.filter { record in
            if let start, record.recordedAt < start { return false }
            if let end, record.recordedAt >= end { return false }
            return true
        }
        .sorted {
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt > $1.recordedAt }
            return $0.id > $1.id
        }
    }

    func recent(limit: Int) throws -> [TranscriptRecord] {
        Array(try all().prefix(max(0, limit)))
    }

    func search(_ rawQuery: String, limit: Int) throws -> [TranscriptRecord] {
        let query = Self.fold(rawQuery)
        let words = query.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }

        let matches = try all().compactMap { record -> (TranscriptRecord, Bool)? in
            let folded = Self.fold(
                record.text + (record.originalText.map { " \($0)" } ?? "")
            )
            guard words.allSatisfy({ folded.contains($0) }) else { return nil }
            return (record, folded.contains(query))
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 && !$1.1 }
            return $0.0.recordedAt > $1.0.recordedAt
        }
        return Array(matches.prefix(max(0, limit)).map(\.0))
    }

    func resolve(_ rawID: String?) throws -> TranscriptRecord? {
        let records = try all()
        guard let rawID, rawID.lowercased() != "latest" else { return records.first }
        if let exact = records.first(where: { $0.id == rawID }) { return exact }

        let partial = records.filter {
            $0.id.hasPrefix(rawID) || $0.id.hasSuffix(rawID)
        }
        return partial.count == 1 ? partial[0] : nil
    }

    private func parse(_ markdown: String, fileURL: URL) -> [TranscriptRecord] {
        let markerPattern = #"(?m)^<!-- parrot-entry: ([A-Za-z0-9_-]+) -->\r?\n(?:<!-- parrot-metrics: ([^>\r\n]+) -->\r?\n)?## ([0-2]\d:[0-5]\d:[0-5]\d)\s*$"#
        guard let markerRegex = try? NSRegularExpression(pattern: markerPattern) else { return [] }

        let source = markdown as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let markers = markerRegex.matches(in: markdown, range: fullRange)
        guard !markers.isEmpty else {
            return parseLegacy(markdown, fileURL: fileURL)
        }

        var records: [TranscriptRecord] = []
        let legacyLength = markers[0].range.location
        if legacyLength > 0 {
            let legacy = source.substring(with: NSRange(location: 0, length: legacyLength))
            records.append(contentsOf: parseLegacy(legacy, fileURL: fileURL))
        }

        for (index, marker) in markers.enumerated() {
            let contentStart = NSMaxRange(marker.range)
            let contentEnd = index + 1 < markers.count
                ? markers[index + 1].range.location
                : source.length
            let rawContent = source.substring(with: NSRange(
                location: contentStart,
                length: max(0, contentEnd - contentStart)
            ))
            let content = OriginalTranscriptMetadata.extract(from: rawContent)
            guard !content.text.isEmpty else { continue }

            let id = source.substring(with: marker.range(at: 1))
            let time = source.substring(with: marker.range(at: 3))
            let metrics = metricValues(from: marker, group: 2, source: source)
            guard let date = recordedDate(fileURL: fileURL, time: time) else { continue }
            records.append(TranscriptRecord(
                id: id,
                recordedAt: date,
                text: content.text,
                originalText: content.originalText,
                fileURL: fileURL,
                audioDuration: duration(from: metrics["audio-ms"]),
                processingDuration: duration(from: metrics["processing-ms"]),
                enhancementDuration: duration(from: metrics["enhancement-ms"]),
                language: metrics["language"].flatMap(RecognitionLanguage.canonicalize),
                modelID: HistoryMetricValue.identifier(metrics["model"]),
                mode: metrics["mode"].flatMap(DictationMode.parse)
            ))
        }
        return records
    }

    /// Compatibility parser for history written before stable entry markers.
    private func parseLegacy(_ markdown: String, fileURL: URL) -> [TranscriptRecord] {
        let headingPattern = #"(?m)^## ([0-2]\d:[0-5]\d:[0-5]\d)\s*$"#
        guard let headingRegex = try? NSRegularExpression(pattern: headingPattern) else { return [] }

        let source = markdown as NSString
        let headings = headingRegex.matches(
            in: markdown,
            range: NSRange(location: 0, length: source.length)
        )
        var occurrences: [String: Int] = [:]
        return headings.enumerated().compactMap { index, heading in
            let contentStart = NSMaxRange(heading.range)
            let contentEnd = index + 1 < headings.count
                ? headings[index + 1].range.location
                : source.length
            let text = source.substring(with: NSRange(
                location: contentStart,
                length: max(0, contentEnd - contentStart)
            ))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            let time = source.substring(with: heading.range(at: 1))
            guard let date = recordedDate(fileURL: fileURL, time: time) else { return nil }
            let base = legacyID(fileURL: fileURL, time: time)
            occurrences[base, default: 0] += 1
            let occurrence = occurrences[base] ?? 1
            let id = occurrence == 1 ? base : "\(base)-\(occurrence)"
            return TranscriptRecord(
                id: id,
                recordedAt: date,
                text: text,
                fileURL: fileURL,
                audioDuration: nil,
                processingDuration: nil
            )
        }
    }

    private func metricValues(
        from match: NSTextCheckingResult,
        group: Int,
        source: NSString
    ) -> [String: String] {
        let range = match.range(at: group)
        guard range.location != NSNotFound else { return [:] }
        var values: [String: String] = [:]
        for field in source.substring(with: range).split(whereSeparator: \Character.isWhitespace) {
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { values[pair[0]] = pair[1] }
        }
        return values
    }

    private func duration(from rawMilliseconds: String?) -> TimeInterval? {
        guard let rawMilliseconds, let milliseconds = Int(rawMilliseconds) else { return nil }
        return TimeInterval(milliseconds) / 1_000
    }

    private func recordedDate(fileURL: URL, time: String) -> Date? {
        guard let day = dailyFileDate(fileURL) else { return nil }
        let timeParts = time.split(separator: ":").compactMap { Int($0) }
        guard timeParts.count == 3 else { return nil }
        let dateParts = calendar.dateComponents([.year, .month, .day], from: day)
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: dateParts.year,
            month: dateParts.month,
            day: dateParts.day,
            hour: timeParts[0],
            minute: timeParts[1],
            second: timeParts[2]
        ))
    }

    private func dailyFileDate(_ fileURL: URL) -> Date? {
        let name = fileURL.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: parts[0],
                month: parts[1],
                day: parts[2]
              ))
        else { return nil }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == parts[0], resolved.month == parts[1], resolved.day == parts[2]
        else { return nil }
        return calendar.startOfDay(for: date)
    }

    private func legacyID(fileURL: URL, time: String) -> String {
        fileURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: "")
            + "-"
            + time.replacingOccurrences(of: ":", with: "")
    }

    private static func fold(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .split(whereSeparator: \Character.isWhitespace)
        .joined(separator: " ")
    }
}

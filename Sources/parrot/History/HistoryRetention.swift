import Foundation

struct HistoryRetentionPolicy: Equatable {
    static let validDays = 1...3_650
    static let secondsPerDay: TimeInterval = 86_400

    let days: Int

    init(days: Int) throws {
        guard Self.validDays.contains(days) else {
            throw HistoryRetentionError.invalidDays(days)
        }
        self.days = days
    }

    func cutoff(at now: Date) -> Date {
        now.addingTimeInterval(-TimeInterval(days) * Self.secondsPerDay)
    }
}

enum HistoryRetentionError: LocalizedError {
    case invalidDays(Int)

    var errorDescription: String? {
        switch self {
        case .invalidDays(let days):
            return "history retention must be between "
                + "\(HistoryRetentionPolicy.validDays.lowerBound) and "
                + "\(HistoryRetentionPolicy.validDays.upperBound) days, not \(days)"
        }
    }
}

struct HistoryPrunePlan {
    enum Action {
        case delete(url: URL, entries: Int, bytes: Int)
        case rewrite(url: URL, contents: String, entries: Int, bytes: Int)

        var url: URL {
            switch self {
            case .delete(let url, _, _), .rewrite(let url, _, _, _):
                return url
            }
        }

        var entries: Int {
            switch self {
            case .delete(_, let entries, _), .rewrite(_, _, let entries, _):
                return entries
            }
        }

        var bytes: Int {
            switch self {
            case .delete(_, _, let bytes), .rewrite(_, _, _, let bytes):
                return bytes
            }
        }
    }

    let cutoff: Date
    let actions: [Action]

    var entriesRemoved: Int { actions.reduce(0) { $0 + $1.entries } }
    var bytesRemoved: Int { actions.reduce(0) { $0 + $1.bytes } }
    var filesAffected: Int { actions.count }
    var filesDeleted: Int {
        actions.reduce(0) { count, action in
            if case .delete = action { return count + 1 }
            return count
        }
    }
    var filesRewritten: Int { filesAffected - filesDeleted }
}

/// Plans and applies retention only to Parrot's exact `YYYY-MM-DD.md` files.
/// Hidden files, symlinks, journals, and arbitrary Markdown are never targets.
struct HistoryRetentionPruner {
    private let directory: URL
    private let calendar: Calendar
    private let fileManager: FileManager
    private let entryDateFormatter: DateFormatter

    init(
        directory: URL = TranscriptHistory.defaultDirectory,
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.calendar = calendar
        self.fileManager = fileManager
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.isLenient = false
        self.entryDateFormatter = formatter
    }

    func preview(policy: HistoryRetentionPolicy, at now: Date = Date()) throws -> HistoryPrunePlan {
        try HistoryFileLock.withLock(directory: directory, mode: .shared) {
            try buildPlan(policy: policy, at: now)
        }
    }

    /// Rebuilds the plan while holding the exclusive lock, eliminating the
    /// preview/apply race with a daemon append.
    func prune(policy: HistoryRetentionPolicy, at now: Date = Date()) throws -> HistoryPrunePlan {
        try HistoryFileLock.withLock(directory: directory, mode: .exclusive) {
            let plan = try buildPlan(policy: policy, at: now)
            try apply(plan)
            return plan
        }
    }

    private func buildPlan(
        policy: HistoryRetentionPolicy,
        at now: Date
    ) throws -> HistoryPrunePlan {
        guard fileManager.fileExists(atPath: directory.path) else {
            return HistoryPrunePlan(cutoff: policy.cutoff(at: now), actions: [])
        }

        let cutoff = policy.cutoff(at: now)
        let cutoffDay = calendar.startOfDay(for: cutoff)
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var actions: [HistoryPrunePlan.Action] = []
        for url in urls {
            guard let fileDay = historyDay(for: url) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            guard fileDay <= cutoffDay else { continue }

            let original = try String(contentsOf: url, encoding: .utf8)
            // A date-shaped filename alone is not enough authority to delete
            // user data. Require Parrot's generated daily-file header too.
            guard Self.hasGeneratedHeader(original, for: url) else { continue }
            if fileDay < cutoffDay {
                actions.append(.delete(
                    url: url,
                    entries: estimatedEntryCount(in: original),
                    bytes: original.utf8.count
                ))
                continue
            }
            if let action = actionForBoundaryFile(
                original,
                url: url,
                cutoff: cutoff
            ) {
                actions.append(action)
            }
        }
        return HistoryPrunePlan(cutoff: cutoff, actions: actions)
    }

    private func apply(_ plan: HistoryPrunePlan) throws {
        for action in plan.actions {
            switch action {
            case .delete(let url, _, _):
                try fileManager.removeItem(at: url)
            case .rewrite(let url, let contents, _, _):
                try Data(contents.utf8).write(to: url, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
            }
        }
    }

    private func actionForBoundaryFile(
        _ original: String,
        url: URL,
        cutoff: Date
    ) -> HistoryPrunePlan.Action? {
        let source = original as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let markers = Self.entryMarkerRegex.matches(in: original, range: fullRange)
        // Legacy entries have no unambiguous raw boundaries. Preserve them on
        // the cutoff day; complete older daily files remain safely removable.
        guard !markers.isEmpty else { return nil }

        let prefix = source.substring(to: markers[0].range.location)
        var output = prefix
        var removedEntries = 0
        for (index, marker) in markers.enumerated() {
            let start = marker.range.location
            let end = index + 1 < markers.count
                ? markers[index + 1].range.location
                : source.length
            let block = source.substring(with: NSRange(location: start, length: end - start))
            let id = source.substring(with: marker.range(at: 1))
            if let recordedAt = entryDate(from: id), recordedAt < cutoff {
                removedEntries += 1
            } else {
                output += block
            }
        }
        guard removedEntries > 0 else { return nil }

        if Self.containsOnlyGeneratedHeader(prefix, for: url),
           Self.entryMarkerRegex.firstMatch(
               in: output,
               range: NSRange(location: 0, length: (output as NSString).length)
           ) == nil {
            return .delete(
                url: url,
                entries: removedEntries,
                bytes: original.utf8.count
            )
        }
        return .rewrite(
            url: url,
            contents: output,
            entries: removedEntries,
            bytes: max(0, original.utf8.count - output.utf8.count)
        )
    }

    private func historyDay(for url: URL) -> Date? {
        guard url.pathExtension.lowercased() == "md" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else { return nil }
        let verified = calendar.dateComponents([.year, .month, .day], from: date)
        guard verified.year == year, verified.month == month, verified.day == day else {
            return nil
        }
        return date
    }

    private func entryDate(from id: String) -> Date? {
        guard let date = entryDateFormatter.date(from: id),
              entryDateFormatter.string(from: date) == id
        else { return nil }
        return date
    }

    private func estimatedEntryCount(in markdown: String) -> Int {
        let range = NSRange(location: 0, length: (markdown as NSString).length)
        let markers = Self.entryMarkerRegex.matches(in: markdown, range: range)
        if markers.isEmpty {
            return Self.legacyHeadingRegex.numberOfMatches(in: markdown, range: range)
        }
        let prefix = (markdown as NSString).substring(to: markers[0].range.location)
        let prefixRange = NSRange(location: 0, length: (prefix as NSString).length)
        return markers.count
            + Self.legacyHeadingRegex.numberOfMatches(in: prefix, range: prefixRange)
    }

    private static func containsOnlyGeneratedHeader(_ prefix: String, for url: URL) -> Bool {
        guard hasGeneratedHeader(prefix, for: url) else { return false }
        let lines = prefix.split(
            omittingEmptySubsequences: false,
            whereSeparator: \Character.isNewline
        )
        return lines.dropFirst().allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private static func hasGeneratedHeader(_ markdown: String, for url: URL) -> Bool {
        let dateName = url.deletingPathExtension().lastPathComponent
        let expected = "# Parrot transcripts — \(dateName)"
        let lines = markdown.split(
            omittingEmptySubsequences: false,
            whereSeparator: \Character.isNewline
        )
        return lines.first.map(String.init) == expected
    }

    private static let entryMarkerRegex = try! NSRegularExpression(
        pattern: #"(?m)^<!-- parrot-entry: ([A-Za-z0-9_-]+) -->\r?\n"#
    )
    private static let legacyHeadingRegex = try! NSRegularExpression(
        pattern: #"(?m)^## [0-2]\d:[0-5]\d:[0-5]\d\s*$"#
    )
}

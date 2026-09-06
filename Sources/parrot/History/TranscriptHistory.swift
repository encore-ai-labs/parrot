import Foundation

struct TranscriptHistoryWrite: Equatable, Sendable {
    let id: String
    let fileURL: URL
}

enum HistoryMetricValue {
    static func identifier(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= 128,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122, 45, 46, 95:
                      return true
                  default:
                      return false
                  }
              })
        else { return nil }
        return value
    }
}

/// Versioned, Markdown-hidden storage for the recognizer's original text.
/// Base64 prevents dictated `-->` or newlines from escaping the comment.
enum OriginalTranscriptMetadata {
    private static let prefix = "<!-- parrot-original-v1: "
    private static let suffix = " -->"

    static func line(originalText: String?, finalText: String) -> String? {
        guard let originalText else { return nil }
        let original = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, original != finalText else { return nil }
        return prefix + Data(original.utf8).base64EncodedString() + suffix
    }

    static func extract(from content: String) -> (text: String, originalText: String?) {
        let trimmed = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
        guard trimmed.hasPrefix(prefix),
              let lineEnd = trimmed.firstIndex(of: "\n")
        else { return (trimmed, nil) }

        let line = String(trimmed[..<lineEnd])
        let text = String(trimmed[trimmed.index(after: lineEnd)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasSuffix(suffix) else { return (text, nil) }
        let payloadStart = line.index(line.startIndex, offsetBy: prefix.count)
        let payloadEnd = line.index(line.endIndex, offsetBy: -suffix.count)
        let payload = String(line[payloadStart..<payloadEnd])
        guard let data = Data(base64Encoded: payload),
              let original = String(data: data, encoding: .utf8),
              !original.isEmpty
        else { return (text, nil) }
        return (text, original)
    }
}

/// Appends successful dictations to owner-readable daily Markdown files.
actor TranscriptHistory {
    enum HistoryError: LocalizedError {
        case unsafeDailyFile(URL)

        var errorDescription: String? {
            switch self {
            case .unsafeDailyFile(let url):
                return "history daily file must be a regular, non-symlink file: \(url.path)"
            }
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/parrot/transcripts", isDirectory: true)
    }

    private let directory: URL
    private let calendar: Calendar
    private let retentionDays: Int?
    private var lastRetentionCheck: Date?
    private var lastEntryIDBase: String?
    private var entryIDOccurrence = 0

    init(
        directory: URL = TranscriptHistory.defaultDirectory,
        calendar: Calendar = .current,
        retentionDays: Int? = nil
    ) {
        self.directory = directory
        self.calendar = calendar
        self.retentionDays = retentionDays
    }

    nonisolated static func fileURL(
        for date: Date = Date(),
        directory: URL = TranscriptHistory.defaultDirectory,
        calendar: Calendar = .current
    ) -> URL {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let name = String(
            format: "%04d-%02d-%02d.md",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
        return directory.appendingPathComponent(name)
    }

    /// Returns nil for an empty transcript; otherwise returns the file written.
    @discardableResult
    func append(
        _ transcript: String,
        at date: Date = Date(),
        audioDuration: TimeInterval? = nil,
        processingDuration: TimeInterval? = nil,
        enhancementDuration: TimeInterval? = nil,
        language: String? = nil,
        modelID: String? = nil,
        mode: DictationMode? = nil,
        originalText: String? = nil
    ) throws -> URL? {
        try appendEntry(
            transcript,
            at: date,
            audioDuration: audioDuration,
            processingDuration: processingDuration,
            enhancementDuration: enhancementDuration,
            language: language,
            modelID: modelID,
            mode: mode,
            originalText: originalText
        )?.fileURL
    }

    /// Append and expose the stable entry ID used to pair optional retained
    /// audio without putting private filesystem paths into Markdown.
    func appendEntry(
        _ transcript: String,
        at date: Date = Date(),
        audioDuration: TimeInterval? = nil,
        processingDuration: TimeInterval? = nil,
        enhancementDuration: TimeInterval? = nil,
        language: String? = nil,
        modelID: String? = nil,
        mode: DictationMode? = nil,
        originalText: String? = nil
    ) throws -> TranscriptHistoryWrite? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Also tighten an existing directory that may have been created with a
        // permissive umask. Dictations can contain passwords or private notes.
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let url = Self.fileURL(for: date, directory: directory, calendar: calendar)
        let id = nextEntryID(date)
        try HistoryFileLock.withLock(
            directory: directory,
            mode: .exclusive,
            createDirectory: true
        ) {
            let time = timestamp(date)
            // The HTML comment is invisible in rendered Markdown and gives history
            // commands an unambiguous boundary even when a dictated note contains
            // a heading that happens to look like a timestamp.
            var metricFields: [String] = []
            if let audioDuration, let processingDuration {
                let audioMilliseconds = max(0, Int((audioDuration * 1_000).rounded()))
                let processingMilliseconds = max(0, Int((processingDuration * 1_000).rounded()))
                metricFields.append("audio-ms=\(audioMilliseconds)")
                metricFields.append("processing-ms=\(processingMilliseconds)")
            }
            if let enhancementDuration, enhancementDuration.isFinite {
                let enhancementMilliseconds = max(
                    0,
                    Int((enhancementDuration * 1_000).rounded())
                )
                metricFields.append("enhancement-ms=\(enhancementMilliseconds)")
            }
            if let language = language.flatMap(RecognitionLanguage.canonicalize),
               language != RecognitionLanguage.automatic {
                metricFields.append("language=\(language)")
            }
            if let modelID = HistoryMetricValue.identifier(modelID) {
                metricFields.append("model=\(modelID)")
            }
            if let mode {
                metricFields.append("mode=\(mode.rawValue)")
            }
            let metrics = metricFields.isEmpty
                ? ""
                : "<!-- parrot-metrics: \(metricFields.joined(separator: " ")) -->\n"
            let original = OriginalTranscriptMetadata.line(
                originalText: originalText,
                finalText: text
            ).map { "\($0)\n" } ?? ""
            let entry = "\n<!-- parrot-entry: \(id) -->\n\(metrics)## \(time)\n\n\(original)\(text)\n"

            if !fileManager.fileExists(atPath: url.path) {
                let dateName = url.deletingPathExtension().lastPathComponent
                let header = "# Parrot transcripts — \(dateName)\n" + entry
                guard fileManager.createFile(
                    atPath: url.path,
                    contents: Data(header.utf8),
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            } else {
                let values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw HistoryError.unsafeDailyFile(url)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(entry.utf8))
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        return TranscriptHistoryWrite(id: id, fileURL: url)
    }

    /// Applies the saved rolling retention at most hourly. The caller can run
    /// this after delivery so cleanup never extends transcription latency.
    func pruneExpiredIfDue(
        at now: Date = Date(),
        force: Bool = false
    ) throws -> HistoryPrunePlan? {
        guard let retentionDays else { return nil }
        if !force, let lastRetentionCheck,
           now.timeIntervalSince(lastRetentionCheck) < 3_600 {
            return nil
        }
        self.lastRetentionCheck = now
        let policy = try HistoryRetentionPolicy(days: retentionDays)
        return try HistoryRetentionPruner(
            directory: directory,
            calendar: calendar
        ).prune(policy: policy, at: now)
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func nextEntryID(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let base = formatter.string(from: date)
        if base == lastEntryIDBase {
            entryIDOccurrence += 1
            return "\(base)-\(entryIDOccurrence)"
        }
        lastEntryIDBase = base
        entryIDOccurrence = 1
        return base
    }
}

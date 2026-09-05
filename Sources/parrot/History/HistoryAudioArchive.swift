import Darwin
import Foundation

struct ArchivedRecording: Equatable, Sendable {
    let id: String
    let recordedAt: Date
    let url: URL
    let bytes: Int64
}

struct HistoryAudioPruneResult: Equatable, Sendable {
    let recordingsRemoved: Int
    let bytesRemoved: Int64
}

/// Private, opt-in audio history paired with the IDs already embedded in the
/// Markdown transcript log. The daemon archives by hard-linking its staged
/// crash-recovery WAV, adding no second audio encode or file copy to delivery.
struct HistoryAudioArchive: Sendable {
    enum ArchiveError: LocalizedError {
        case unsafeDirectory(URL)
        case unsafeRecording(URL)
        case invalidEntryID(String)
        case recordingAlreadyExists(String)
        case recordingTooLarge
        case hardLinkFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .unsafeDirectory(let url):
                return "audio history must be a regular directory, not a symlink: \(url.path)"
            case .unsafeRecording(let url):
                return "audio history requires a regular, non-symlink WAV: \(url.path)"
            case .invalidEntryID(let id):
                return "invalid transcript history ID: \(id)"
            case .recordingAlreadyExists(let id):
                return "audio history already contains recording \(id)"
            case .recordingTooLarge:
                return "the recording is too large to retain safely"
            case .hardLinkFailed(let code):
                return "couldn't archive the recording: \(String(cString: strerror(code)))"
            }
        }
    }

    static var defaultDirectory: URL {
        TranscriptHistory.defaultDirectory.appendingPathComponent("audio", isDirectory: true)
    }

    let directory: URL
    private let historyDirectory: URL
    private let calendar: Calendar

    init(
        directory: URL = HistoryAudioArchive.defaultDirectory,
        historyDirectory: URL = TranscriptHistory.defaultDirectory,
        calendar: Calendar = .current
    ) {
        self.directory = directory
        self.historyDirectory = historyDirectory
        self.calendar = calendar
    }

    /// Link the already-synchronized recovery WAV into history. Both default
    /// locations share ~/.local/share/parrot, so this is constant-time and
    /// does not duplicate audio bytes. A failure never blocks text delivery.
    func archive(sourceWAV: URL, entryID: String) throws -> URL {
        guard Self.isValidEntryID(entryID) else {
            throw ArchiveError.invalidEntryID(entryID)
        }
        return try HistoryFileLock.withLock(
            directory: historyDirectory,
            mode: .exclusive,
            createDirectory: true
        ) {
            let sourceValues = try sourceWAV.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
                throw ArchiveError.unsafeRecording(sourceWAV)
            }
            guard (sourceValues.fileSize ?? 0) <= 256 * 1_024 * 1_024 else {
                throw ArchiveError.recordingTooLarge
            }
            try prepareDirectory()
            let destination = url(for: entryID)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw ArchiveError.recordingAlreadyExists(entryID)
            }
            guard Darwin.link(sourceWAV.path, destination.path) == 0 else {
                throw ArchiveError.hardLinkFailed(errno)
            }
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.path
                )
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            return destination
        }
    }

    func recordings() throws -> [ArchivedRecording] {
        try HistoryFileLock.withLock(directory: historyDirectory, mode: .shared) {
            try recordingsUnlocked()
        }
    }

    func resolve(_ rawID: String?) throws -> ArchivedRecording? {
        Self.resolve(rawID, in: try recordings())
    }

    @discardableResult
    func delete(_ rawID: String) throws -> ArchivedRecording? {
        try HistoryFileLock.withLock(directory: historyDirectory, mode: .exclusive) {
            guard let recording = Self.resolve(rawID, in: try recordingsUnlocked()) else {
                return nil
            }
            try FileManager.default.removeItem(at: recording.url)
            return recording
        }
    }

    private static func resolve(
        _ rawID: String?,
        in recordings: [ArchivedRecording]
    ) -> ArchivedRecording? {
        guard let rawID, rawID.lowercased() != "latest" else {
            return recordings.first
        }
        if let exact = recordings.first(where: { $0.id == rawID }) { return exact }
        let partial = recordings.filter {
            $0.id.hasPrefix(rawID) || $0.id.hasSuffix(rawID)
        }
        return partial.count == 1 ? partial[0] : nil
    }

    /// Remove recordings outside the audio window or whose transcript entry
    /// no longer exists. Only Parrot-shaped regular WAV files are eligible;
    /// symlinks and unrelated files are always preserved.
    func prune(
        retentionDays: Int,
        validTranscriptIDs: Set<String>,
        at now: Date = Date()
    ) throws -> HistoryAudioPruneResult {
        let policy = try HistoryRetentionPolicy(days: retentionDays)
        return try HistoryFileLock.withLock(directory: historyDirectory, mode: .exclusive) {
            let candidates = try recordingsUnlocked().filter {
                $0.recordedAt < policy.cutoff(at: now)
                    || !validTranscriptIDs.contains($0.id)
            }
            for recording in candidates {
                try FileManager.default.removeItem(at: recording.url)
            }
            return HistoryAudioPruneResult(
                recordingsRemoved: candidates.count,
                bytesRemoved: candidates.reduce(0) { $0 + $1.bytes }
            )
        }
    }

    /// Remove audio whose Markdown record was deleted, regardless of whether
    /// automatic audio retention is currently enabled.
    func pruneOrphans(
        validTranscriptIDs: Set<String>
    ) throws -> HistoryAudioPruneResult {
        try HistoryFileLock.withLock(directory: historyDirectory, mode: .exclusive) {
            let candidates = try recordingsUnlocked().filter {
                !validTranscriptIDs.contains($0.id)
            }
            for recording in candidates {
                try FileManager.default.removeItem(at: recording.url)
            }
            return HistoryAudioPruneResult(
                recordingsRemoved: candidates.count,
                bytesRemoved: candidates.reduce(0) { $0 + $1.bytes }
            )
        }
    }

    func clear() throws -> HistoryAudioPruneResult {
        try HistoryFileLock.withLock(directory: historyDirectory, mode: .exclusive) {
            let candidates = try recordingsUnlocked()
            for recording in candidates {
                try FileManager.default.removeItem(at: recording.url)
            }
            return HistoryAudioPruneResult(
                recordingsRemoved: candidates.count,
                bytesRemoved: candidates.reduce(0) { $0 + $1.bytes }
            )
        }
    }

    private func recordingsUnlocked() throws -> [ArchivedRecording] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        try validateDirectory()
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ],
            options: [.skipsHiddenFiles]
        )
        return try urls.compactMap { url in
            guard url.pathExtension.lowercased() == "wav" else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            guard Self.isValidEntryID(id), let recordedAt = date(from: id) else { return nil }
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return ArchivedRecording(
                id: id,
                recordedAt: recordedAt,
                url: url,
                bytes: Int64(values.fileSize ?? 0)
            )
        }
        .sorted {
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt > $1.recordedAt }
            return $0.id > $1.id
        }
    }

    private func prepareDirectory() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            try validateDirectory()
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func validateDirectory() throws {
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ArchiveError.unsafeDirectory(directory)
        }
    }

    private func url(for entryID: String) -> URL {
        directory.appendingPathComponent(entryID).appendingPathExtension("wav")
    }

    private func date(from entryID: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.isLenient = false
        return formatter.date(from: String(entryID.prefix(19)))
    }

    private static func isValidEntryID(_ id: String) -> Bool {
        id.range(
            of: #"^\d{8}-\d{6}-\d{3}(?:-\d+)?$"#,
            options: .regularExpression
        ) != nil
    }
}

/// Keeps potentially large directory scans off the dictation path and limits
/// them to startup plus at most once per hour in a long-running daemon.
actor HistoryAudioMaintenance {
    private let archive: HistoryAudioArchive
    private let retentionDays: Int
    private var lastCheck: Date?

    init(archive: HistoryAudioArchive, retentionDays: Int) {
        self.archive = archive
        self.retentionDays = retentionDays
    }

    func pruneIfDue(
        validTranscriptIDs: Set<String>,
        at now: Date = Date(),
        force: Bool = false
    ) throws -> HistoryAudioPruneResult? {
        if !force, let lastCheck, now.timeIntervalSince(lastCheck) < 3_600 {
            return nil
        }
        lastCheck = now
        return try archive.prune(
            retentionDays: retentionDays,
            validTranscriptIDs: validTranscriptIDs,
            at: now
        )
    }
}

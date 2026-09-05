import Foundation

/// Appends successful dictations to owner-readable daily Markdown files.
actor TranscriptHistory {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/parrot/transcripts", isDirectory: true)
    }

    private let directory: URL
    private let calendar: Calendar

    init(directory: URL = TranscriptHistory.defaultDirectory, calendar: Calendar = .current) {
        self.directory = directory
        self.calendar = calendar
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
    func append(_ transcript: String, at date: Date = Date()) throws -> URL? {
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
        let time = timestamp(date)
        let entry = "\n## \(time)\n\n\(text)\n"

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
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(entry.utf8))
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return url
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

import Darwin
import Foundation

/// Appends finished dictations directly to a user-selected Markdown journal.
/// The destination is intentionally separate from Parrot's searchable history:
/// journal mode is an output choice, while history remains the private recovery log.
final class MarkdownJournal: @unchecked Sendable {
    enum JournalError: LocalizedError {
        case emptyPath
        case notMarkdown(URL)
        case destinationIsDirectory(URL)
        case systemCall(String, URL, Int32)

        var errorDescription: String? {
            switch self {
            case .emptyPath:
                return "journal path cannot be empty"
            case .notMarkdown(let url):
                return "journal must use a .md or .markdown extension: \(url.path)"
            case .destinationIsDirectory(let url):
                return "journal destination is a directory: \(url.path)"
            case .systemCall(let operation, let url, let code):
                let detail = String(cString: strerror(code))
                return "couldn't \(operation) journal at \(url.path): \(detail)"
            }
        }
    }

    let url: URL

    private let fileManager: FileManager
    private let formatter: DateFormatter
    private let lock = NSLock()

    init(
        url: URL,
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) {
        self.url = url
        self.fileManager = fileManager
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        self.formatter = formatter
    }

    static func resolveURL(
        _ rawPath: String,
        currentDirectory: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
    ) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JournalError.emptyPath }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expanded)
        let url = ((expanded as NSString).isAbsolutePath
            ? candidate
            : currentDirectory.appendingPathComponent(expanded))
            .standardizedFileURL
        guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            throw JournalError.notMarkdown(url)
        }
        return url
    }

    /// Validate and create the destination before model warmup so a bad path
    /// fails at launch rather than after the user has finished speaking.
    func prepare() throws {
        lock.lock()
        defer { lock.unlock() }
        try prepareDirectory()
        try withLockedFile { descriptor, isEmpty in
            guard isEmpty else { return }
            try write(Data("# Parrot journal\n".utf8), to: descriptor)
            try sync(descriptor)
        }
    }

    @discardableResult
    func append(_ transcript: String, at date: Date = Date()) throws -> URL? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }
        try prepareDirectory()
        let entry = "\n## \(timestamp(date))\n\n\(text)\n"
        try withLockedFile { descriptor, isEmpty in
            if isEmpty {
                try write(Data("# Parrot journal\n".utf8), to: descriptor)
            }
            try write(Data(entry.utf8), to: descriptor)
            try sync(descriptor)
        }
        return url
    }

    private func prepareDirectory() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw JournalError.destinationIsDirectory(url)
        }

        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private func withLockedFile(
        _ body: (_ descriptor: Int32, _ isEmpty: Bool) throws -> Void
    ) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw JournalError.systemCall("open", url, errno)
        }
        defer { Darwin.close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw JournalError.systemCall("lock", url, errno)
        }
        defer { flock(descriptor, LOCK_UN) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw JournalError.systemCall("inspect", url, errno)
        }
        try body(descriptor, metadata.st_size == 0)
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var remaining = buffer.count
            var cursor = buffer.baseAddress!
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw JournalError.systemCall("write", url, errno)
                }
                remaining -= written
                cursor = cursor.advanced(by: written)
            }
        }
    }

    private func sync(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 else {
            throw JournalError.systemCall("sync", url, errno)
        }
    }

    private func timestamp(_ date: Date) -> String {
        return formatter.string(from: date)
    }
}

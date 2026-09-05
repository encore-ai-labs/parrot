import Darwin
import Foundation

/// Cross-process coordination for the Markdown history directory.
///
/// The daemon appends while short-lived `parrot history` commands may read or
/// prune. A directory lock prevents partial reads and, more importantly,
/// prevents a cleanup rewrite from racing a newly appended transcript.
enum HistoryFileLock {
    enum Mode {
        case shared
        case exclusive
    }

    enum LockError: LocalizedError {
        case destinationIsNotDirectory(URL)
        case systemCall(String, URL, Int32)

        var errorDescription: String? {
            switch self {
            case .destinationIsNotDirectory(let url):
                return "history destination is not a directory: \(url.path)"
            case .systemCall(let operation, let url, let code):
                return "couldn't \(operation) history lock at \(url.path): "
                    + String(cString: strerror(code))
            }
        }
    }

    static func withLock<T>(
        directory: URL,
        mode: Mode,
        createDirectory: Bool = false,
        _ body: () throws -> T
    ) throws -> T {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw LockError.destinationIsNotDirectory(directory)
            }
        } else if createDirectory {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } else {
            return try body()
        }

        let lockURL = directory.appendingPathComponent(".history.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw LockError.systemCall("open", lockURL, errno)
        }
        defer { Darwin.close(descriptor) }

        _ = fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR))
        let operation = mode == .shared ? LOCK_SH : LOCK_EX
        guard flock(descriptor, operation) == 0 else {
            throw LockError.systemCall("acquire", lockURL, errno)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

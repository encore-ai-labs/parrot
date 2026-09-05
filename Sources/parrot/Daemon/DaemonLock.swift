import Darwin
import Foundation

/// An advisory process lock held for the complete daemon lifetime. This
/// prevents a foreground invocation and a LaunchAgent from both recording,
/// transcribing, and reacting to the same global hotkey.
final class DaemonLock {
    enum LockError: LocalizedError {
        case cannotOpen(URL, Int32)
        case alreadyRunning(pid: Int32?)
        case cannotWrite(URL, Int32)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let url, let code):
                return "couldn't open daemon lock at \(url.path): \(Self.message(code))"
            case .alreadyRunning(let pid):
                if let pid { return "Parrot is already running (pid \(pid))" }
                return "Parrot is already running"
            case .cannotWrite(let url, let code):
                return "couldn't write daemon lock at \(url.path): \(Self.message(code))"
            }
        }

        private static func message(_ code: Int32) -> String {
            String(cString: strerror(code))
        }
    }

    static var defaultURL: URL {
        Config.directory.appendingPathComponent("daemon.lock")
    }

    let url: URL
    private var descriptor: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    static func acquire(
        at url: URL = defaultURL,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws -> DaemonLock {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let descriptor = open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LockError.cannotOpen(url, errno) }
        _ = fchmod(descriptor, S_IRUSR | S_IWUSR)

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let owner = readPID(from: descriptor)
            close(descriptor)
            throw LockError.alreadyRunning(pid: owner)
        }

        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) >= 0 else {
            let code = errno
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw LockError.cannotWrite(url, code)
        }
        let bytes = Array("\(pid)\n".utf8)
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress!, buffer.count)
        }
        guard written == bytes.count else {
            let code = errno
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw LockError.cannotWrite(url, code)
        }

        return DaemonLock(url: url, descriptor: descriptor)
    }

    /// Returns the PID written by the process that currently holds the lock.
    /// A stale lock file is deliberately reported as idle: ownership comes
    /// from `flock`, not from trusting an old PID on disk.
    static func ownerPID(at url: URL = defaultURL) -> Int32? {
        let descriptor = open(url.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return nil
        }
        guard errno == EWOULDBLOCK else { return nil }
        return readPID(from: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }

    private static func readPID(from descriptor: Int32) -> Int32? {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress!, bytes.count)
        }
        guard count > 0 else { return nil }
        let value = String(decoding: buffer.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(value), pid > 1 else { return nil }
        return pid
    }
}

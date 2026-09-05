import Darwin
import Foundation

/// Hands a finished transcript to an explicitly configured local workflow.
///
/// The transcript is provided only on standard input. It is never interpolated
/// into the shell command, argv, or the environment, so dictated shell syntax
/// remains inert data. The child gets a separate process group so a timeout can
/// terminate pipelines and subprocesses rather than abandoning them.
struct LocalCommandDelivery: Sendable {
    enum DeliveryError: LocalizedError, Equatable {
        case emptyCommand
        case commandTooLong
        case invalidCommand
        case systemCall(String, Int32)
        case launch(Int32)
        case failed(Int32, String)
        case timedOut(TimeInterval, String)

        var errorDescription: String? {
            switch self {
            case .emptyCommand:
                return "local delivery command cannot be empty"
            case .commandTooLong:
                return "local delivery command cannot exceed 16 KiB"
            case .invalidCommand:
                return "local delivery command cannot contain a null byte"
            case .systemCall(let operation, let code):
                return "couldn't \(operation): \(Self.message(for: code))"
            case .launch(let code):
                return "couldn't start local delivery command: \(Self.message(for: code))"
            case .failed(let status, let diagnostic):
                return "local delivery command exited with status \(status)\(Self.suffix(diagnostic))"
            case .timedOut(let timeout, let diagnostic):
                return "local delivery command exceeded \(Self.duration(timeout))\(Self.suffix(diagnostic))"
            }
        }

        private static func message(for code: Int32) -> String {
            guard let message = strerror(code) else { return "error \(code)" }
            return String(cString: message)
        }

        private static func duration(_ seconds: TimeInterval) -> String {
            if seconds.rounded() == seconds { return "\(Int(seconds))s" }
            return String(format: "%.2fs", seconds)
        }

        private static func suffix(_ diagnostic: String) -> String {
            diagnostic.isEmpty ? "" : ": \(diagnostic)"
        }
    }

    static let defaultTimeout: TimeInterval = 10
    static let maximumCommandBytes = 16 * 1_024
    static let maximumDiagnosticBytes = 4 * 1_024

    let command: String
    let timeout: TimeInterval

    init(command: String, timeout: TimeInterval = Self.defaultTimeout) throws {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DeliveryError.emptyCommand }
        guard trimmed.utf8.count <= Self.maximumCommandBytes else {
            throw DeliveryError.commandTooLong
        }
        guard !trimmed.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw DeliveryError.invalidCommand
        }
        precondition(timeout > 0)
        self.command = trimmed
        self.timeout = timeout
    }

    /// Runs synchronously on the caller's worker task. Model inference has
    /// already completed, so this adds no recognition latency or model memory.
    func deliver(_ transcript: String) throws {
        let inputDescriptor = try makeUnlinkedInputFile()
        defer { close(inputDescriptor) }
        try write(Data(transcript.utf8), to: inputDescriptor)
        guard lseek(inputDescriptor, 0, SEEK_SET) == 0 else {
            throw DeliveryError.systemCall("rewind command input", errno)
        }

        var diagnosticDescriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&diagnosticDescriptors) == 0 else {
            throw DeliveryError.systemCall("create command diagnostics pipe", errno)
        }
        let diagnosticRead = diagnosticDescriptors[0]
        let diagnosticWrite = diagnosticDescriptors[1]
        defer { close(diagnosticRead) }
        let diagnosticFlags = fcntl(diagnosticRead, F_GETFL)
        guard diagnosticFlags >= 0,
              fcntl(diagnosticRead, F_SETFL, diagnosticFlags | O_NONBLOCK) == 0 else {
            let code = errno
            close(diagnosticWrite)
            throw DeliveryError.systemCall("configure command diagnostics pipe", code)
        }

        let diagnostics = BoundedDiagnosticReader(
            descriptor: diagnosticRead,
            maximumBytes: Self.maximumDiagnosticBytes
        )

        let nullOutput = open("/dev/null", O_WRONLY)
        guard nullOutput >= 0 else {
            close(diagnosticWrite)
            throw DeliveryError.systemCall("open /dev/null", errno)
        }
        defer { close(nullOutput) }

        var actions: posix_spawn_file_actions_t?
        let actionsStatus = posix_spawn_file_actions_init(&actions)
        guard actionsStatus == 0 else {
            close(diagnosticWrite)
            throw DeliveryError.systemCall("initialize command file actions", actionsStatus)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var actionStatuses = [
            posix_spawn_file_actions_adddup2(&actions, inputDescriptor, STDIN_FILENO),
            posix_spawn_file_actions_adddup2(&actions, nullOutput, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, diagnosticWrite, STDERR_FILENO),
        ]
        // A caller may launch Parrot with a standard descriptor already
        // closed. In that case one of these resources can itself be fd 0–2;
        // the dup actions above replace it, so closing it would close the new
        // standard stream too. Only extra descriptors need explicit closure.
        for descriptor in [diagnosticRead, inputDescriptor, nullOutput, diagnosticWrite]
            where descriptor > STDERR_FILENO {
            actionStatuses.append(posix_spawn_file_actions_addclose(&actions, descriptor))
        }
        if let failure = actionStatuses.first(where: { $0 != 0 }) {
            close(diagnosticWrite)
            throw DeliveryError.systemCall("configure command file actions", failure)
        }

        var attributes: posix_spawnattr_t?
        let attributesStatus = posix_spawnattr_init(&attributes)
        guard attributesStatus == 0 else {
            close(diagnosticWrite)
            throw DeliveryError.systemCall("initialize command spawn attributes", attributesStatus)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let groupStatus = posix_spawnattr_setpgroup(&attributes, 0)
        let flagsStatus = posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP)
        )
        if let failure = [groupStatus, flagsStatus].first(where: { $0 != 0 }) {
            close(diagnosticWrite)
            throw DeliveryError.systemCall("configure command process group", failure)
        }

        let shell = "/bin/zsh"
        let arguments = [shell, "-lc", command]
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let spawnStatus = withMutableCStringArray(arguments) { argv in
            withMutableCStringArray(environment) { envp in
                posix_spawn(&pid, shell, &actions, &attributes, argv, envp)
            }
        }
        close(diagnosticWrite)
        guard spawnStatus == 0 else {
            throw DeliveryError.launch(spawnStatus)
        }

        let outcome = wait(for: pid, timeout: timeout, diagnostics: diagnostics)
        diagnostics.drain()
        let diagnostic = diagnostics.text

        switch outcome {
        case .finished(let status):
            guard status == 0 else { throw DeliveryError.failed(status, diagnostic) }
        case .timedOut:
            throw DeliveryError.timedOut(timeout, diagnostic)
        case .waitFailed(let code):
            throw DeliveryError.systemCall("wait for local delivery command", code)
        }
    }

    private enum ProcessOutcome {
        case finished(Int32)
        case timedOut
        case waitFailed(Int32)
    }

    private func wait(
        for pid: pid_t,
        timeout: TimeInterval,
        diagnostics: BoundedDiagnosticReader
    ) -> ProcessOutcome {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var waitStatus: Int32 = 0

        while true {
            diagnostics.drain()
            let result = waitpid(pid, &waitStatus, WNOHANG)
            if result == pid {
                terminateRemainingProcessGroup(pid)
                diagnostics.drain()
                return .finished(exitStatus(from: waitStatus))
            }
            if result == -1, errno != EINTR { return .waitFailed(errno) }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            usleep(10_000)
        }

        // The spawn attribute makes pid the process-group id. Signal the group
        // so pipelines cannot outlive a timed-out delivery shell.
        _ = kill(-pid, SIGTERM)
        let graceDeadline = ProcessInfo.processInfo.systemUptime + 0.25
        var reaped = false
        while ProcessInfo.processInfo.systemUptime < graceDeadline {
            diagnostics.drain()
            if !reaped {
                let result = waitpid(pid, &waitStatus, WNOHANG)
                if result == pid { reaped = true }
                if result == -1, errno != EINTR { return .waitFailed(errno) }
            }
            usleep(10_000)
        }
        // Send this even if the shell has already exited: a child may have
        // ignored SIGTERM while remaining in the command's process group.
        _ = kill(-pid, SIGKILL)
        if !reaped {
            while waitpid(pid, &waitStatus, 0) == -1 {
                if errno == EINTR { continue }
                return .waitFailed(errno)
            }
        }
        return .timedOut
    }

    private func terminateRemainingProcessGroup(_ pid: pid_t) {
        guard kill(-pid, 0) == 0 else { return }
        _ = kill(-pid, SIGTERM)
        usleep(50_000)
        if kill(-pid, 0) == 0 {
            _ = kill(-pid, SIGKILL)
            usleep(10_000)
        }
    }

    private func exitStatus(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        if signal == 0 { return (waitStatus >> 8) & 0xff }
        return 128 + signal
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard var cursor = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw DeliveryError.systemCall("write private command input", errno)
                }
                remaining -= written
                cursor = cursor.advanced(by: written)
            }
        }
    }

    private func makeUnlinkedInputFile() throws -> Int32 {
        let directory = FileManager.default.temporaryDirectory.path
        let path = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("parrot-command-input.XXXXXX").path
        var template = Array(path.utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress!)
        }
        guard descriptor >= 0 else {
            throw DeliveryError.systemCall("create private command input", errno)
        }
        let unlinkStatus = template.withUnsafeBufferPointer { buffer in
            unlink(buffer.baseAddress!)
        }
        guard unlinkStatus == 0 else {
            let code = errno
            close(descriptor)
            throw DeliveryError.systemCall("unlink private command input", code)
        }
        return descriptor
    }

    private func withMutableCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}

private final class BoundedDiagnosticReader: @unchecked Sendable {
    private let descriptor: Int32
    private let maximumBytes: Int
    private var bytes: [UInt8] = []

    init(descriptor: Int32, maximumBytes: Int) {
        self.descriptor = descriptor
        self.maximumBytes = maximumBytes
    }

    var text: String {
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func drain() {
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(descriptor, storage.baseAddress, storage.count)
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            guard count > 0 else { return }
            if bytes.count < maximumBytes {
                let kept = min(count, maximumBytes - bytes.count)
                bytes.append(contentsOf: buffer.prefix(kept))
            }
        }
    }
}

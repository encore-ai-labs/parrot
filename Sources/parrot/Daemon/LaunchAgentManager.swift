import Darwin
import Foundation

struct LaunchAgentStatus: Equatable {
    let installed: Bool
    let loaded: Bool
    let state: String?
    let pid: Int32?
    let lastExitCode: Int32?

    var running: Bool { state == "running" && pid != nil }
}

struct LaunchctlResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

final class LaunchAgentManager {
    static let maximumLogBytes: off_t = 5 * 1_024 * 1_024

    enum ManagerError: LocalizedError {
        case binaryMissing
        case notInstalled(URL)
        case launchctl(String, Int32, String)

        var errorDescription: String? {
            switch self {
            case .binaryMissing:
                return "couldn't locate the parrot binary; install it to /usr/local/bin/parrot first"
            case .notInstalled(let url):
                return "launch-at-login is not installed (missing \(url.path))"
            case .launchctl(let action, let status, let message):
                let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "launchctl \(action) failed with exit code \(status)"
                    : "launchctl \(action) failed: \(detail)"
            }
        }
    }

    static let label = "com.digimata.parrot"

    let homeDirectory: URL
    let userID: uid_t
    private let launchctlRunner: ([String]) -> LaunchctlResult

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: uid_t = getuid(),
        launchctlRunner: (([String]) -> LaunchctlResult)? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.userID = userID
        self.launchctlRunner = launchctlRunner ?? Self.runLaunchctl
    }

    var plistURL: URL {
        homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist")
    }

    var logDirectory: URL {
        homeDirectory.appendingPathComponent("Library/Logs/Parrot", isDirectory: true)
    }

    var stdoutLogURL: URL { logDirectory.appendingPathComponent("daemon.out.log") }
    var stderrLogURL: URL { logDirectory.appendingPathComponent("daemon.err.log") }
    var domainTarget: String { "gui/\(userID)" }
    var serviceTarget: String { "\(domainTarget)/\(Self.label)" }

    func install(binaryPath: String? = nil) throws {
        let binary = try binaryPath ?? resolveBinaryPath()
        try preparePrivateLogs()

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList(binaryPath: binary),
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: plistURL.path
        )

        if status().loaded {
            let result = launchctlRunner(["bootout", serviceTarget])
            if result.status != 0 { throw launchctlError("bootout", result) }
        }
        let result = launchctlRunner(["bootstrap", domainTarget, plistURL.path])
        guard result.status == 0 else { throw launchctlError("bootstrap", result) }
    }

    func uninstall() throws -> Bool {
        let current = status()
        guard current.installed || current.loaded else { return false }
        if current.loaded {
            let result = launchctlRunner(["bootout", serviceTarget])
            guard result.status == 0 else { throw launchctlError("bootout", result) }
        }
        if current.installed {
            try FileManager.default.removeItem(at: plistURL)
        }
        return true
    }

    func start() throws {
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            throw ManagerError.notInstalled(plistURL)
        }
        let current = status()
        let result = current.loaded
            ? launchctlRunner(["kickstart", "-k", serviceTarget])
            : launchctlRunner(["bootstrap", domainTarget, plistURL.path])
        guard result.status == 0 else {
            throw launchctlError(current.loaded ? "kickstart" : "bootstrap", result)
        }
    }

    func stop() throws -> Bool {
        guard status().loaded else { return false }
        let result = launchctlRunner(["bootout", serviceTarget])
        guard result.status == 0 else { throw launchctlError("bootout", result) }
        return true
    }

    func restart() throws {
        try start()
    }

    func status() -> LaunchAgentStatus {
        let installed = FileManager.default.fileExists(atPath: plistURL.path)
        let result = launchctlRunner(["print", serviceTarget])
        guard result.status == 0 else {
            return LaunchAgentStatus(
                installed: installed, loaded: false, state: nil, pid: nil, lastExitCode: nil
            )
        }
        return Self.parseStatus(result.stdout, installed: installed)
    }

    func logTail(lineCount: Int) -> [(URL, String)] {
        [stdoutLogURL, stderrLogURL].compactMap { url in
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  !contents.isEmpty
            else { return nil }
            let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            return (url, lines.suffix(lineCount).joined(separator: "\n"))
        }
    }

    func propertyList(binaryPath: String) -> [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [binaryPath, "run", "--skip-doctor"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ThrottleInterval": 30,
            "ProcessType": "Interactive",
            "StandardOutPath": stdoutLogURL.path,
            "StandardErrorPath": stderrLogURL.path,
            "EnvironmentVariables": ["PARROT_LAUNCH_AGENT": "1"],
        ]
    }

    static func parseStatus(_ output: String, installed: Bool) -> LaunchAgentStatus {
        var state: String?
        var pid: Int32?
        var lastExitCode: Int32?

        for rawLine in output.split(separator: "\n") {
            let parts = rawLine.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "state": state = parts[1]
            case "pid": pid = Int32(parts[1])
            case "last exit code": lastExitCode = Int32(parts[1])
            default: break
            }
        }
        return LaunchAgentStatus(
            installed: installed,
            loaded: true,
            state: state,
            pid: pid,
            lastExitCode: lastExitCode
        )
    }

    /// launchd opens these descriptors before starting Parrot. Truncating the
    /// inherited descriptors keeps operational logs bounded without a shell
    /// wrapper, and only runs for the LaunchAgent environment we generate.
    static func trimInheritedLogsIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard environment["PARROT_LAUNCH_AGENT"] == "1" else { return }
        for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_size > maximumLogBytes
            else { continue }
            guard ftruncate(descriptor, 0) == 0 else { continue }
            _ = lseek(descriptor, 0, SEEK_SET)
        }
    }

    private func preparePrivateLogs() throws {
        try FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: logDirectory.path
        )
        for url in [stdoutLogURL, stderrLogURL] {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        }
    }

    private func resolveBinaryPath() throws -> String {
        let installed = "/usr/local/bin/parrot"
        if FileManager.default.isExecutableFile(atPath: installed) { return installed }
        let argv0 = CommandLine.arguments.first ?? "parrot"
        if argv0.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: argv0) {
            FileHandle.standardError.write(Data(
                "note: /usr/local/bin/parrot not found; using \(argv0)\n".utf8
            ))
            return argv0
        }
        throw ManagerError.binaryMissing
    }

    private func launchctlError(_ action: String, _ result: LaunchctlResult) -> ManagerError {
        .launchctl(action, result.status, result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    private static func runLaunchctl(_ arguments: [String]) -> LaunchctlResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        do {
            try task.run()
        } catch {
            return LaunchctlResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        task.waitUntilExit()
        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        return LaunchctlResult(status: task.terminationStatus, stdout: output, stderr: error)
    }
}

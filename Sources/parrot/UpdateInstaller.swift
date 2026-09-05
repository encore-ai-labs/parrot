import ArgumentParser
import Darwin
import Foundation

enum UpdateInstaller {
    enum InstallerError: LocalizedError {
        case commandFailed(String, Int32)
        case commandCouldNotStart(String, String)
        case commandWaitFailed(String, String)
        case installedBinaryMissing

        var errorDescription: String? {
            switch self {
            case .commandFailed(let command, let status):
                return "\(command) exited with status \(status)"
            case .commandCouldNotStart(let command, let reason):
                return "couldn't start \(command): \(reason)"
            case .commandWaitFailed(let command, let reason):
                return "couldn't wait for \(command): \(reason)"
            case .installedBinaryMissing:
                return "the updated binary was not found at /usr/local/bin/parrot"
            }
        }
    }

    static let installedBinaryURL = URL(fileURLWithPath: "/usr/local/bin/parrot")

    /// Release builds fetch the installer from their own immutable tag. A
    /// nonce also bypasses intermediary caches for development builds and
    /// older GitHub/CDN responses.
    static func installerURL(
        appVersion: String = AppVersion.current,
        cacheToken: String = UUID().uuidString
    ) -> URL {
        let revision = appVersion == "development" ? "master" : "v\(appVersion)"
        var components = URLComponents()
        components.scheme = "https"
        components.host = "raw.githubusercontent.com"
        components.path = "/encore-ai-labs/parrot/\(revision)/scripts/install.sh"
        components.queryItems = [URLQueryItem(name: "parrot-cache", value: cacheToken)]
        return components.url!
    }

    /// Fetch the installer as a file rather than piping remote code directly
    /// into a shell. The installer verifies the release archive's published
    /// SHA-256 checksum before replacing the binary.
    static func installLatest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("install.sh")
        let sourceURL = installerURL()
        try run(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: [
                "-fsSL",
                "-H", "Cache-Control: no-cache",
                sourceURL.absoluteString,
                "-o", script.path,
            ],
            label: "downloading the updater"
        )
        try run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [script.path],
            label: "installing the update",
            environment: ["PARROT_UPDATE_MODE": "1"]
        )
    }

    /// Start the newly installed daemon with the same options. It waits for
    /// this process to exit before touching permissions, the microphone, or
    /// the hotkey, avoiding two live Parrot instances.
    static func relaunchCurrentDaemonAfterExit() throws {
        guard FileManager.default.isExecutableFile(atPath: installedBinaryURL.path) else {
            throw InstallerError.installedBinaryMissing
        }
        let task = Process()
        task.executableURL = installedBinaryURL
        task.arguments = restartArguments(
            currentArguments: CommandLine.arguments,
            waitingFor: ProcessInfo.processInfo.processIdentifier
        )
        try task.run()
    }

    static func restartArguments(currentArguments: [String], waitingFor pid: Int32) -> [String] {
        var arguments = Array(currentArguments.dropFirst())
        arguments.append(contentsOf: ["--wait-for-pid", String(pid)])
        return arguments
    }

    /// Run synchronously while inheriting the caller's process group and file
    /// descriptors. Foundation.Process can put a packaged CLI's child outside
    /// the terminal's foreground process group on macOS; sudo then cannot read
    /// /dev/tty and reports an Input/output error.
    @discardableResult
    static func run(
        executable: URL,
        arguments: [String],
        label: String,
        environment: [String: String] = [:]
    ) throws -> Int32 {
        let executablePath = executable.path
        let argv = [executablePath] + arguments
        let mergedEnvironment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, new in new }
        )
        let env = mergedEnvironment.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let spawnStatus = withMutableCStringArray(argv) { argvPointer in
            withMutableCStringArray(env) { environmentPointer in
                posix_spawn(
                    &pid,
                    executablePath,
                    nil,
                    nil,
                    argvPointer,
                    environmentPointer
                )
            }
        }
        guard spawnStatus == 0 else {
            throw InstallerError.commandCouldNotStart(label, errorMessage(spawnStatus))
        }

        var waitStatus: Int32 = 0
        while waitpid(pid, &waitStatus, 0) == -1 {
            if errno == EINTR { continue }
            throw InstallerError.commandWaitFailed(label, errorMessage(errno))
        }

        let status = exitStatus(from: waitStatus)
        guard status == 0 else {
            throw InstallerError.commandFailed(label, status)
        }
        return status
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { string in
            string.withCString { strdup($0) }
        }
        pointers.append(nil)
        defer {
            for pointer in pointers {
                free(pointer)
            }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private static func exitStatus(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        if signal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + signal
    }

    private static func errorMessage(_ code: Int32) -> String {
        guard let message = strerror(code) else { return "error \(code)" }
        return String(cString: message)
    }
}

struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download and install the latest stable Parrot release."
    )

    func run() throws {
        try UpdateInstaller.installLatest()
        print("✓ update complete — the next `parrot` launch will use the new version")
    }
}

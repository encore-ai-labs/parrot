import ArgumentParser
import Foundation

enum UpdateInstaller {
    enum InstallerError: LocalizedError {
        case commandFailed(String, Int32)
        case installedBinaryMissing

        var errorDescription: String? {
            switch self {
            case .commandFailed(let command, let status):
                return "\(command) exited with status \(status)"
            case .installedBinaryMissing:
                return "the updated binary was not found at /usr/local/bin/parrot"
            }
        }
    }

    private static let installerURL = URL(
        string: "https://raw.githubusercontent.com/encore-ai-labs/parrot/master/scripts/install.sh"
    )!
    static let installedBinaryURL = URL(fileURLWithPath: "/usr/local/bin/parrot")

    /// Fetch the installer as a file rather than piping remote code directly
    /// into a shell. The installer verifies the release archive's published
    /// SHA-256 checksum before replacing the binary.
    static func installLatest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = directory.appendingPathComponent("install.sh")
        try run(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: ["-fsSL", installerURL.absoluteString, "-o", script.path],
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

    private static func run(
        executable: URL,
        arguments: [String],
        label: String,
        environment: [String: String] = [:]
    ) throws {
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        if !environment.isEmpty {
            task.environment = ProcessInfo.processInfo.environment.merging(
                environment,
                uniquingKeysWith: { _, new in new }
            )
        }
        // Process does not reliably preserve an interactive terminal when
        // Parrot is itself a packaged CLI. Forward all three streams
        // explicitly so sudo can display and read its password prompt.
        task.standardInput = FileHandle.standardInput
        task.standardOutput = FileHandle.standardOutput
        task.standardError = FileHandle.standardError
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw InstallerError.commandFailed(label, task.terminationStatus)
        }
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

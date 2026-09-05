import ArgumentParser
import Darwin
import Foundation

/// Backwards-compatible install surface. The `parrot daemon` command exposes
/// the rest of the lifecycle without asking users to memorize launchctl.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
    )

    @Flag(name: .long, help: "Register parrot to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall: Bool = false

    func run() throws {
        if launchAtLogin == uninstall {
            throw ValidationError("specify exactly one of --launch-at-login or --uninstall")
        }

        let manager = LaunchAgentManager()
        if uninstall {
            if try manager.uninstall() {
                print("✓ launch-at-login removed")
                print("  logs preserved at \(manager.logDirectory.path)")
            } else {
                print("nothing to remove (no agent at \(manager.plistURL.path))")
            }
        } else {
            try manager.install()
            print("✓ launch-at-login installed and started")
            print("  plist: \(manager.plistURL.path)")
            print("  logs:  \(manager.logDirectory.path)")
        }
    }
}

struct Daemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Manage the background launch-at-login daemon.",
        subcommands: [Status.self, Start.self, Stop.self, Restart.self, Logs.self]
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show daemon status.")

        func run() {
            let manager = LaunchAgentManager()
            let status = manager.status()
            let presentation = DaemonStatusPresentation.resolve(
                launchAgent: status,
                runtimePID: DaemonLock.ownerPID()
            )
            print("installed: \(status.installed ? "yes" : "no")")
            print("loaded:    \(status.loaded ? "yes" : "no")")
            print("state:     \(presentation.state)")
            if let pid = presentation.pid { print("pid:       \(pid)") }
            if let lifecycle = presentation.lifecycle {
                print("lifecycle: \(lifecycle)")
            }
            if let code = status.lastExitCode { print("last exit: \(code)") }
            print("logs:      \(manager.logDirectory.path)")
        }
    }

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start the installed daemon.")

        func run() throws {
            try LaunchAgentManager().start()
            print("✓ daemon started")
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the daemon.")

        func run() throws {
            var stopped = try LaunchAgentManager().stop()
            if let pid = DaemonLock.ownerPID() {
                guard kill(pid, SIGTERM) == 0 || errno == ESRCH else {
                    throw ValidationError(
                        "couldn't stop running Parrot pid \(pid): \(String(cString: strerror(errno)))"
                    )
                }
                for _ in 0..<60 where DaemonLock.ownerPID() != nil {
                    usleep(50_000)
                }
                guard DaemonLock.ownerPID() == nil else {
                    throw ValidationError("Parrot pid \(pid) did not stop within 3 seconds")
                }
                stopped = true
            }
            if stopped {
                print("✓ daemon stopped")
            } else {
                print("daemon is already stopped")
            }
        }
    }

    struct Restart: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Restart the installed daemon.")

        func run() throws {
            try LaunchAgentManager().restart()
            print("✓ daemon restarted")
        }
    }

    struct Logs: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show recent private daemon logs.")

        @Option(name: .shortAndLong, help: "Number of lines from each log (1...1000).")
        var lines: Int = 80

        func validate() throws {
            guard (1...1000).contains(lines) else {
                throw ValidationError("--lines must be between 1 and 1000")
            }
        }

        func run() {
            let manager = LaunchAgentManager()
            let logs = manager.logTail(lineCount: lines)
            guard !logs.isEmpty else {
                print("no daemon logs yet")
                print("expected in \(manager.logDirectory.path)")
                return
            }
            for (index, log) in logs.enumerated() {
                if index > 0 { print() }
                print("==> \(log.0.path) <==")
                print(log.1)
            }
        }
    }
}

struct DaemonStatusPresentation: Equatable {
    let state: String
    let pid: Int32?
    let lifecycle: String?

    static func resolve(
        launchAgent: LaunchAgentStatus,
        runtimePID: Int32?
    ) -> Self {
        if let runtimePID {
            return Self(
                state: "running",
                pid: runtimePID,
                lifecycle: launchAgent.pid == runtimePID
                    ? "launchd"
                    : "foreground/update restart"
            )
        }
        return Self(
            state: launchAgent.state ?? "stopped",
            pid: launchAgent.pid,
            lifecycle: launchAgent.pid == nil ? nil : "launchd"
        )
    }
}

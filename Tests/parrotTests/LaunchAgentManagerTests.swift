import Foundation
import XCTest

@testable import parrot

final class LaunchAgentManagerTests: XCTestCase {
    func testDaemonCommandsAndLogBoundsParse() throws {
        XCTAssertTrue(try Daemon.parseAsRoot(["status"]) is Daemon.Status)
        XCTAssertTrue(try Daemon.parseAsRoot(["start"]) is Daemon.Start)
        XCTAssertTrue(try Daemon.parseAsRoot(["stop"]) is Daemon.Stop)
        XCTAssertTrue(try Daemon.parseAsRoot(["restart"]) is Daemon.Restart)
        let logs = try XCTUnwrap(try Daemon.parseAsRoot(["logs", "--lines", "25"]) as? Daemon.Logs)
        XCTAssertEqual(logs.lines, 25)
        XCTAssertThrowsError(try Daemon.parseAsRoot(["logs", "--lines", "0"]))
        XCTAssertThrowsError(try Daemon.parseAsRoot(["logs", "--lines", "1001"]))
    }

    func testInstallWritesPrivateAgentAndBootstrapsIt() throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        var calls: [[String]] = []
        let manager = LaunchAgentManager(homeDirectory: home, userID: 501) { arguments in
            calls.append(arguments)
            if arguments.first == "print" {
                return LaunchctlResult(status: 113, stdout: "", stderr: "not found")
            }
            return LaunchctlResult(status: 0, stdout: "", stderr: "")
        }

        try manager.install(binaryPath: "/usr/local/bin/parrot")

        let data = try Data(contentsOf: manager.plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            ["/usr/local/bin/parrot", "run", "--skip-doctor"]
        )
        XCTAssertEqual(plist["StandardOutPath"] as? String, manager.stdoutLogURL.path)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, manager.stderrLogURL.path)
        XCTAssertEqual(plist["ThrottleInterval"] as? Int, 30)
        XCTAssertEqual(permissions(at: manager.plistURL), 0o600)
        XCTAssertEqual(permissions(at: manager.logDirectory), 0o700)
        XCTAssertEqual(permissions(at: manager.stdoutLogURL), 0o600)
        XCTAssertEqual(permissions(at: manager.stderrLogURL), 0o600)
        XCTAssertEqual(calls.last, ["bootstrap", "gui/501", manager.plistURL.path])
    }

    func testStatusParsesLaunchctlFields() {
        let output = """
        gui/501/com.digimata.parrot = {
            state = running
            pid = 4200
            last exit code = 78
        }
        """
        XCTAssertEqual(
            LaunchAgentManager.parseStatus(output, installed: true),
            LaunchAgentStatus(
                installed: true,
                loaded: true,
                state: "running",
                pid: 4200,
                lastExitCode: 78
            )
        )
    }

    func testRuntimeLockIsAuthoritativeForForegroundAndLaunchdPresentation() {
        let waitingAgent = LaunchAgentStatus(
            installed: true,
            loaded: true,
            state: "waiting",
            pid: nil,
            lastExitCode: 1
        )
        XCTAssertEqual(
            DaemonStatusPresentation.resolve(launchAgent: waitingAgent, runtimePID: 42),
            DaemonStatusPresentation(
                state: "running",
                pid: 42,
                lifecycle: "foreground/update restart"
            )
        )

        let runningAgent = LaunchAgentStatus(
            installed: true,
            loaded: true,
            state: "running",
            pid: 84,
            lastExitCode: nil
        )
        XCTAssertEqual(
            DaemonStatusPresentation.resolve(launchAgent: runningAgent, runtimePID: 84),
            DaemonStatusPresentation(state: "running", pid: 84, lifecycle: "launchd")
        )
    }

    func testStartBootstrapsUnloadedAgentAndKickstartsLoadedAgent() throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let managerForPath = LaunchAgentManager(homeDirectory: home, userID: 502) { _ in
            LaunchctlResult(status: 1, stdout: "", stderr: "")
        }
        try FileManager.default.createDirectory(
            at: managerForPath.plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: managerForPath.plistURL.path, contents: Data()
        ))

        var unloadedCalls: [[String]] = []
        let unloaded = LaunchAgentManager(homeDirectory: home, userID: 502) { arguments in
            unloadedCalls.append(arguments)
            return LaunchctlResult(
                status: arguments.first == "print" ? 1 : 0, stdout: "", stderr: ""
            )
        }
        try unloaded.start()
        XCTAssertEqual(
            unloadedCalls.last,
            ["bootstrap", "gui/502", unloaded.plistURL.path]
        )

        var loadedCalls: [[String]] = []
        let loaded = LaunchAgentManager(homeDirectory: home, userID: 502) { arguments in
            loadedCalls.append(arguments)
            let output = arguments.first == "print" ? "state = running\npid = 5\n" : ""
            return LaunchctlResult(status: 0, stdout: output, stderr: "")
        }
        try loaded.start()
        XCTAssertEqual(loadedCalls.last, ["kickstart", "-k", loaded.serviceTarget])
    }

    func testLogTailReturnsOnlyRequestedLines() throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = LaunchAgentManager(homeDirectory: home) { _ in
            LaunchctlResult(status: 1, stdout: "", stderr: "")
        }
        try FileManager.default.createDirectory(
            at: manager.logDirectory, withIntermediateDirectories: true
        )
        try Data("one\ntwo\nthree".utf8).write(to: manager.stderrLogURL)

        let logs = manager.logTail(lineCount: 2)
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.0, manager.stderrLogURL)
        XCTAssertEqual(logs.first?.1, "two\nthree")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-agent-tests-\(UUID().uuidString)")
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }
}

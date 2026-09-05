import Darwin
import Foundation
import XCTest

@testable import parrot

final class LocalCommandDeliveryTests: XCTestCase {
    func testRejectsUnsafeOrUnusableCommandSettings() throws {
        XCTAssertThrowsError(try LocalCommandDelivery(command: "  \n "))
        XCTAssertThrowsError(try LocalCommandDelivery(command: "ok\0bad"))
        XCTAssertThrowsError(try LocalCommandDelivery(
            command: String(repeating: "x", count: LocalCommandDelivery.maximumCommandBytes + 1)
        ))

        let delivery = try LocalCommandDelivery(command: "  /usr/bin/true  \n")
        XCTAssertEqual(delivery.command, "/usr/bin/true")
    }

    func testDeliversExactUTF8TranscriptOnStandardInput() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("delivered.txt")
        let transcript = "# Café notes\n\n- $(touch should-not-run)\n- `echo inert` 🦜"
        let delivery = try LocalCommandDelivery(
            command: "/bin/cat > \(shellQuote(output.path))"
        )

        try delivery.deliver(transcript)

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), transcript)
    }

    func testLargeTranscriptCannotDeadlockCommandInput() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("large.txt")
        let transcript = String(repeating: "local note line\n", count: 100_000)
        let delivery = try LocalCommandDelivery(
            command: "/bin/cat > \(shellQuote(output.path))",
            timeout: 2
        )

        try delivery.deliver(transcript)

        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue,
            transcript.utf8.count
        )
    }

    func testReportsExitStatusAndTrimmedStandardError() throws {
        let delivery = try LocalCommandDelivery(
            command: "/bin/echo 'destination refused note' >&2; exit 23"
        )

        XCTAssertThrowsError(try delivery.deliver("private transcript")) { error in
            XCTAssertEqual(
                error as? LocalCommandDelivery.DeliveryError,
                .failed(23, "destination refused note")
            )
        }
    }

    func testTypicalSuccessfulDeliveryPerformance() throws {
        let delivery = try LocalCommandDelivery(command: ":")
        let transcript = "## Project update\n\n- Local models stay fast.\n- Notes stay private."

        measure {
            try! delivery.deliver(transcript)
        }
    }

    func testCapsCapturedDiagnosticsWhileDrainingAllOutput() throws {
        let delivery = try LocalCommandDelivery(
            command: "i=0; while (( i < 6000 )); do printf x >&2; (( i++ )); done; exit 4",
            timeout: 2
        )

        XCTAssertThrowsError(try delivery.deliver("note")) { error in
            guard case .failed(4, let diagnostic) = error as? LocalCommandDelivery.DeliveryError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(diagnostic.utf8.count, LocalCommandDelivery.maximumDiagnosticBytes)
        }
    }

    func testTimeoutTerminatesTheWholeCommandProcessGroup() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pidFile = root.appendingPathComponent("child.pid")
        let delivery = try LocalCommandDelivery(
            command: "/bin/sleep 5 & child=$!; /bin/echo $child > \(shellQuote(pidFile.path)); wait",
            timeout: 0.10
        )
        let started = ProcessInfo.processInfo.systemUptime

        XCTAssertThrowsError(try delivery.deliver("note")) { error in
            guard case .timedOut(let timeout, _) = error as? LocalCommandDelivery.DeliveryError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(timeout, 0.10)
        }

        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
        let childPID = try XCTUnwrap(
            Int32(try String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines))
        )
        XCTAssertEqual(kill(childPID, 0), -1, "timed-out child process was left running")
        XCTAssertEqual(errno, ESRCH)
    }

    func testSuccessfulShellCannotStrandBackgroundChildren() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pidFile = root.appendingPathComponent("background.pid")
        let delivery = try LocalCommandDelivery(
            command: "/bin/sleep 5 & child=$!; /bin/echo $child > \(shellQuote(pidFile.path)); disown",
            timeout: 1
        )

        try delivery.deliver("note")

        let childPID = try XCTUnwrap(
            Int32(try String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines))
        )
        XCTAssertEqual(kill(childPID, 0), -1, "background child process was left running")
        XCTAssertEqual(errno, ESRCH)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-command-tests-\(UUID().uuidString)")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

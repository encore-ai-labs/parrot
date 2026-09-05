import Foundation
import XCTest

@testable import parrot

final class DaemonLockTests: XCTestCase {
    func testExclusiveLockReportsOwnerAndCanBeReacquiredAfterRelease() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/daemon.lock")

        let first = try DaemonLock.acquire(at: url, pid: 1234)
        XCTAssertEqual(try String(contentsOf: url), "1234\n")
        XCTAssertEqual(permissions(at: url), 0o600)
        XCTAssertEqual(permissions(at: url.deletingLastPathComponent()), 0o700)

        XCTAssertThrowsError(try DaemonLock.acquire(at: url, pid: 5678)) { error in
            guard case DaemonLock.LockError.alreadyRunning(let pid) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(pid, 1234)
        }

        first.release()
        let second = try DaemonLock.acquire(at: url, pid: 5678)
        XCTAssertEqual(try String(contentsOf: url), "5678\n")
        second.release()
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-lock-tests-\(UUID().uuidString)")
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }
}

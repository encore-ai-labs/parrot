import Foundation
import XCTest

@testable import parrot

final class MarkdownJournalTests: XCTestCase {
    func testResolvesRelativeTildeAndMarkdownPaths() throws {
        let current = URL(fileURLWithPath: "/tmp/parrot-journal-cwd", isDirectory: true)

        XCTAssertEqual(
            try MarkdownJournal.resolveURL("notes/inbox.md", currentDirectory: current).path,
            "/tmp/parrot-journal-cwd/notes/inbox.md"
        )
        XCTAssertEqual(
            try MarkdownJournal.resolveURL("/tmp/absolute.markdown", currentDirectory: current).path,
            "/tmp/absolute.markdown"
        )
        XCTAssertTrue(try MarkdownJournal.resolveURL("~/notes.md").path.hasSuffix("/notes.md"))
        XCTAssertThrowsError(try MarkdownJournal.resolveURL("   ", currentDirectory: current))
        XCTAssertThrowsError(try MarkdownJournal.resolveURL("notes.txt", currentDirectory: current))
    }

    func testPrepareAndAppendCreatePrivateStructuredJournal() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let url = root.appendingPathComponent("nested/inbox.md")
        let journal = MarkdownJournal(url: url, calendar: calendar)

        try journal.prepare()
        XCTAssertEqual(try String(contentsOf: url), "# Parrot journal\n")
        XCTAssertEqual(permissions(at: url), 0o600)
        XCTAssertEqual(permissions(at: root), 0o700)
        XCTAssertEqual(permissions(at: url.deletingLastPathComponent()), 0o700)

        let first = Date(timeIntervalSince1970: 1_725_475_849)
        XCTAssertEqual(try journal.append("  # Project\n\n- first task  ", at: first), url)
        XCTAssertNil(try journal.append(" \n ", at: first))
        XCTAssertEqual(try journal.append("Second thought", at: first.addingTimeInterval(1)), url)

        XCTAssertEqual(try String(contentsOf: url), """
        # Parrot journal

        ## 2024-09-04 18:50:49 GMT

        # Project

        - first task

        ## 2024-09-04 18:50:50 GMT

        Second thought

        """)
    }

    func testExistingJournalPermissionsAndContentsArePreserved() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("shared.md")
        try Data("existing\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)

        let journal = MarkdownJournal(url: url)
        try journal.prepare()
        try journal.append("new note")

        XCTAssertTrue(try String(contentsOf: url).hasPrefix("existing\n\n## "))
        XCTAssertTrue(try String(contentsOf: url).hasSuffix("\n\nnew note\n"))
        XCTAssertEqual(permissions(at: url), 0o640)
    }

    func testDirectoryDestinationFailsBeforeRecording() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("folder.md", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        XCTAssertThrowsError(try MarkdownJournal(url: url).prepare()) { error in
            XCTAssertTrue(error.localizedDescription.contains("is a directory"))
        }
    }

    func testConcurrentAppendsRemainWholeAndComplete() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("concurrent.md")
        let journal = MarkdownJournal(url: url)
        let failures = ErrorCollector()

        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do {
                try journal.append("entry-\(index)")
            } catch {
                failures.append(error)
            }
        }

        XCTAssertTrue(failures.values.isEmpty)
        let contents = try String(contentsOf: url)
        XCTAssertEqual(contents.components(separatedBy: "\n## ").count - 1, 40)
        for index in 0..<40 {
            XCTAssertEqual(
                contents.components(separatedBy: "\nentry-\(index)\n").count - 1,
                1
            )
        }
    }

    func testRunJournalAndPasteOptionsAreMutuallyExclusive() throws {
        let journal = try XCTUnwrap(
            try Run.parseAsRoot(["--journal", "/tmp/inbox.md"]) as? Run
        )
        XCTAssertEqual(journal.journal, "/tmp/inbox.md")

        let paste = try XCTUnwrap(try Run.parseAsRoot(["--paste"]) as? Run)
        XCTAssertTrue(paste.paste)
        XCTAssertThrowsError(try Run.parseAsRoot([
            "--journal", "/tmp/inbox.md", "--paste",
        ]))
        XCTAssertThrowsError(try Run.parseAsRoot(["--journal", "/tmp/inbox.txt"]))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-journal-tests-\(UUID().uuidString)")
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }
}

private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []

    var values: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ error: Error) {
        lock.lock()
        storage.append(error)
        lock.unlock()
    }
}

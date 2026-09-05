import Foundation
import XCTest

@testable import parrot

final class HistoryAudioArchiveTests: XCTestCase {
    func testArchivesByHardLinkWithPrivatePermissionsAndSurvivesRecoveryCleanup() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("history", isDirectory: true)
        let recovery = LastRecordingRecovery(
            directory: root.appendingPathComponent("recovery", isDirectory: true)
        )
        try recovery.stage(
            samples: [Float](repeating: 0.1, count: 16_000 * 60),
            sampleRate: 16_000
        )
        let archive = HistoryAudioArchive(
            directory: history.appendingPathComponent("audio", isDirectory: true),
            historyDirectory: history,
            calendar: utcCalendar()
        )

        let started = Date()
        let url = try archive.archive(
            sourceWAV: recovery.fileURL,
            entryID: "20240905-120000-123"
        )

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        XCTAssertEqual(permissions(at: url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(permissions(at: url), 0o600)
        XCTAssertEqual(fileNumber(at: recovery.fileURL), fileNumber(at: url))
        XCTAssertEqual(try archive.resolve("latest")?.id, "20240905-120000-123")
        try recovery.markDelivered()
        XCTAssertFalse(recovery.hasPendingFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testHardLinkArchivingCostStaysBelowDeliveryBudget() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("history", isDirectory: true)
        let recovery = LastRecordingRecovery(
            directory: root.appendingPathComponent("recovery", isDirectory: true)
        )
        try recovery.stage(
            samples: [Float](repeating: 0.1, count: 16_000 * 60),
            sampleRate: 16_000
        )
        let archive = HistoryAudioArchive(
            directory: history.appendingPathComponent("audio", isDirectory: true),
            historyDirectory: history,
            calendar: utcCalendar()
        )
        var nextSuffix = 2

        measure {
            for _ in 0..<100 {
                let id = "20240905-120000-123-\(nextSuffix)"
                nextSuffix += 1
                let url = try! archive.archive(sourceWAV: recovery.fileURL, entryID: id)
                try! FileManager.default.removeItem(at: url)
            }
        }
    }

    func testRejectsUnsafeIdentifiersSourcesAndArchiveDirectories() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = root.appendingPathComponent("history", isDirectory: true)
        let source = root.appendingPathComponent("source.wav")
        try WAVWriter.write(samples: [0.1], sampleRate: 16_000, to: source.path)
        let archive = HistoryAudioArchive(
            directory: history.appendingPathComponent("audio", isDirectory: true),
            historyDirectory: history,
            calendar: utcCalendar()
        )
        XCTAssertThrowsError(try archive.archive(sourceWAV: source, entryID: "../../escape"))

        let oversized = root.appendingPathComponent("oversized.wav")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
        let oversizedHandle = try FileHandle(forWritingTo: oversized)
        try oversizedHandle.truncate(atOffset: UInt64(256 * 1_024 * 1_024 + 1))
        try oversizedHandle.close()
        XCTAssertThrowsError(try archive.archive(
            sourceWAV: oversized,
            entryID: "20240905-115959-999"
        ))

        let sourceLink = root.appendingPathComponent("source-link.wav")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)
        XCTAssertThrowsError(try archive.archive(
            sourceWAV: sourceLink,
            entryID: "20240905-120000-123"
        ))

        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: history.appendingPathComponent("audio"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try archive.archive(
            sourceWAV: source,
            entryID: "20240905-120000-123"
        ))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testRetentionRemovesExpiredAndOrphanedAudioOnly() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = root.appendingPathComponent("history", isDirectory: true)
        let directory = history.appendingPathComponent("audio", isDirectory: true)
        let source = root.appendingPathComponent("source.wav")
        try WAVWriter.write(samples: [0.1, 0.2], sampleRate: 16_000, to: source.path)
        let archive = HistoryAudioArchive(
            directory: directory,
            historyDirectory: history,
            calendar: utcCalendar()
        )
        let old = "20240901-120000-000"
        let orphan = "20240905-110000-000"
        let keep = "20240905-120000-000"
        for id in [old, orphan, keep] {
            _ = try archive.archive(sourceWAV: source, entryID: id)
        }
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data("mine".utf8).write(to: unrelated)
        let symlink = directory.appendingPathComponent("20240902-120000-000.wav")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unrelated)

        let result = try archive.prune(
            retentionDays: 2,
            validTranscriptIDs: [old, keep],
            at: try date(year: 2024, month: 9, day: 5, hour: 13)
        )

        XCTAssertEqual(result.recordingsRemoved, 2)
        XCTAssertEqual(try archive.recordings().map(\.id), [keep])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
    }

    func testMaintenanceIsHourlyAndClearKeepsTranscriptFiles() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = root.appendingPathComponent("history", isDirectory: true)
        let directory = history.appendingPathComponent("audio", isDirectory: true)
        let source = root.appendingPathComponent("source.wav")
        try WAVWriter.write(samples: [0.1], sampleRate: 16_000, to: source.path)
        let archive = HistoryAudioArchive(
            directory: directory,
            historyDirectory: history,
            calendar: utcCalendar()
        )
        _ = try archive.archive(sourceWAV: source, entryID: "20240905-120000-000")
        let note = history.appendingPathComponent("2024-09-05.md")
        try Data("# keep transcript".utf8).write(to: note)
        let maintenance = HistoryAudioMaintenance(archive: archive, retentionDays: 7)
        let now = try date(year: 2024, month: 9, day: 5, hour: 13)

        let first = try await maintenance.pruneIfDue(
            validTranscriptIDs: ["20240905-120000-000"],
            at: now,
            force: true
        )
        let throttled = try await maintenance.pruneIfDue(
            validTranscriptIDs: ["20240905-120000-000"],
            at: now.addingTimeInterval(3_599)
        )
        let due = try await maintenance.pruneIfDue(
            validTranscriptIDs: ["20240905-120000-000"],
            at: now.addingTimeInterval(3_600)
        )
        XCTAssertNotNil(first)
        XCTAssertNil(throttled)
        XCTAssertNotNil(due)

        let cleared = try archive.clear()
        XCTAssertEqual(cleared.recordingsRemoved, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
    }

    func testDeleteRemovesOneRecordingAndKeepsTranscriptFile() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = root.appendingPathComponent("history", isDirectory: true)
        let source = root.appendingPathComponent("source.wav")
        try WAVWriter.write(samples: [0.1], sampleRate: 16_000, to: source.path)
        let archive = HistoryAudioArchive(
            directory: history.appendingPathComponent("audio", isDirectory: true),
            historyDirectory: history,
            calendar: utcCalendar()
        )
        _ = try archive.archive(sourceWAV: source, entryID: "20240905-120000-000")
        _ = try archive.archive(sourceWAV: source, entryID: "20240905-120001-000")
        let note = history.appendingPathComponent("2024-09-05.md")
        try Data("# keep transcript".utf8).write(to: note)

        let deleted = try archive.delete("120000-000")

        XCTAssertEqual(deleted?.id, "20240905-120000-000")
        XCTAssertEqual(try archive.recordings().map(\.id), ["20240905-120001-000"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
        XCTAssertNil(try archive.delete("missing"))
    }

    func testHistoryAudioCommandsAndReprocessArgumentsParse() throws {
        XCTAssertTrue(try History.parseAsRoot(["audio"]) is History.Audio.List)
        XCTAssertTrue(try History.parseAsRoot(["audio", "path"]) is History.Audio.Path)
        XCTAssertTrue(try History.parseAsRoot([
            "audio", "play", "latest",
        ]) is History.Audio.Play)
        let parsed = try XCTUnwrap(try History.parseAsRoot([
            "audio", "reprocess", "20240905", "--model", "whisper-small.en",
            "--language", "en", "--notes", "--cleanup", "--lowercase",
            "--auto-paragraphs", "--no-vocabulary", "--no-fillers", "--no-snippets",
        ]) as? History.Audio.Reprocess)
        XCTAssertEqual(parsed.id, "20240905")
        XCTAssertEqual(
            parsed.transcriptionArguments(for: URL(fileURLWithPath: "/tmp/input.wav")),
            [
                "/tmp/input.wav", "--stdout", "--format", "text",
                "--model", "whisper-small.en", "--language", "en", "--notes", "--cleanup",
                "--lowercase", "--auto-paragraphs", "--no-vocabulary", "--no-fillers",
                "--no-snippets",
            ]
        )
        XCTAssertThrowsError(try History.parseAsRoot([
            "audio", "reprocess", "latest", "--notes", "--dictation",
        ]))
        XCTAssertThrowsError(try History.parseAsRoot([
            "audio", "reprocess", "latest", "--cleanup", "--no-cleanup",
        ]))
        XCTAssertThrowsError(try History.parseAsRoot([
            "audio", "reprocess", "latest", "--lowercase", "--no-lowercase",
        ]))
        XCTAssertThrowsError(try History.parseAsRoot([
            "audio", "reprocess", "latest", "--auto-paragraphs", "--no-auto-paragraphs",
        ]))
        XCTAssertTrue(try History.parseAsRoot([
            "audio", "clear",
        ]) is History.Audio.Clear)
        XCTAssertTrue(try History.parseAsRoot([
            "audio", "delete", "latest", "--confirm",
        ]) is History.Audio.Delete)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-audio-history-tests-\(UUID().uuidString)")
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(year: Int, month: Int, day: Int, hour: Int) throws -> Date {
        try XCTUnwrap(utcCalendar().date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        )))
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }

    private func fileNumber(at url: URL) -> UInt64 {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.systemFileNumber] as! NSNumber).uint64Value
    }
}

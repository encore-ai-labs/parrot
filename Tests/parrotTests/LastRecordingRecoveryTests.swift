import Foundation
import XCTest

@testable import parrot

final class LastRecordingRecoveryTests: XCTestCase {
    func testStagesPrivateWAVAndRestoresIt() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples: [Float] = [-1, -0.25, 0, 0.25, 1]
        let store = LastRecordingRecovery(directory: directory)

        try store.stage(samples: samples, sampleRate: 16_000)

        XCTAssertTrue(store.hasRecording)
        XCTAssertTrue(store.hasPendingFile)
        XCTAssertEqual(permissions(directory), 0o700)
        XCTAssertEqual(permissions(store.fileURL), 0o600)

        let restored = LastRecordingRecovery(directory: directory)
        XCTAssertTrue(try restored.restorePending())
        let audio = try XCTUnwrap(restored.samples())
        XCTAssertEqual(audio.sampleRate, 16_000)
        XCTAssertEqual(audio.samples.count, samples.count)
        for (actual, expected) in zip(audio.samples, samples) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
    }

    func testSuccessfulDeliveryDeletesDiskButKeepsFastRetryInMemory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LastRecordingRecovery(directory: directory)
        try store.stage(samples: [0.1, 0.2], sampleRate: 16_000)

        try store.markDelivered()

        XCTAssertFalse(store.hasPendingFile)
        XCTAssertEqual(store.samples()?.samples.count, 2)
        XCTAssertFalse(try LastRecordingRecovery(directory: directory).restorePending())
    }

    func testNewCaptureAtomicallyReplacesPriorSlot() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LastRecordingRecovery(directory: directory)
        try store.stage(samples: [0.1, 0.2, 0.3], sampleRate: 16_000)
        try store.stage(samples: [-0.5], sampleRate: 8_000)

        let restored = LastRecordingRecovery(directory: directory)
        XCTAssertTrue(try restored.restorePending())
        XCTAssertEqual(restored.samples()?.sampleRate, 8_000)
        XCTAssertEqual(
            try XCTUnwrap(restored.samples()).samples.first ?? 0,
            -0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            (try FileManager.default.contentsOfDirectory(atPath: directory.path)).sorted(),
            ["last-recording.wav"]
        )
    }

    func testForgetRemovesMemoryAndDisk() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LastRecordingRecovery(directory: directory)
        try store.stage(samples: [0.1], sampleRate: 16_000)

        try store.forget()

        XCTAssertFalse(store.hasRecording)
        XCTAssertFalse(store.hasPendingFile)
    }

    func testRejectsDamagedRecoveryFileWithoutLoadingSamples() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LastRecordingRecovery(directory: directory)
        try Data("not a wav".utf8).write(to: store.fileURL)

        XCTAssertThrowsError(try store.restorePending())
        XCTAssertFalse(store.hasRecording)
        XCTAssertTrue(store.hasPendingFile)
    }

    func testStartupPrunesOnlyInterruptedRecoveryWrites() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent(".last-recording-abandoned.tmp")
        let unrelated = directory.appendingPathComponent("keep-me.txt")
        try Data().write(to: stale)
        try Data().write(to: unrelated)

        let store = LastRecordingRecovery(directory: directory)
        XCTAssertFalse(try store.restorePending())

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testOneMinuteSafetyCopyStaysOffTheCriticalPathBudget() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LastRecordingRecovery(directory: directory)
        let samples = [Float](repeating: 0.1, count: 16_000 * 60)
        let started = Date()

        try store.stage(samples: samples, sampleRate: 16_000)

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        let size = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.size]
            as? NSNumber
        XCTAssertEqual(size?.intValue, 44 + samples.count * 2)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-recovery-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func permissions(_ url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }
}

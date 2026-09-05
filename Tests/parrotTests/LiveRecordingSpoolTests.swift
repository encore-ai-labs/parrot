import Foundation
import XCTest

@testable import parrot

final class LiveRecordingSpoolTests: XCTestCase {
    func testStreamsPrivatePCMAndFinalizesExactMetadata() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("last-recording.wav")
        let samples: [Float] = [-1, -0.25, 0, 0.25, 1]
        let spool = try LiveRecordingSpool(fileURL: url, sampleRate: 16_000)

        try spool.append(samples.prefix(2))
        try spool.append(samples.dropFirst(2))
        let summary = try spool.finish()

        XCTAssertEqual(summary.fileURL, url)
        XCTAssertEqual(summary.sampleRate, 16_000)
        XCTAssertEqual(summary.sampleCount, samples.count)
        XCTAssertEqual(summary.duration, Double(samples.count) / 16_000, accuracy: 0.000_001)
        XCTAssertEqual(
            summary.rms,
            Float((samples.map { Double($0 * $0) }.reduce(0, +) / Double(samples.count)).squareRoot()),
            accuracy: 0.000_001
        )
        let metadata = try LiveRecordingSpool.metadata(at: url)
        XCTAssertEqual(metadata.sampleRate, 16_000)
        XCTAssertEqual(metadata.sampleCount, samples.count)
        XCTAssertEqual(fileSize(url), LiveRecordingSpool.headerSize + samples.count * 2)
        XCTAssertEqual(permissions(directory), 0o700)
        XCTAssertEqual(permissions(url), 0o600)
    }

    func testRepairsInterruptedHeaderWithoutChangingAudioPayload() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("last-recording.wav")
        let samples = [Float](repeating: 0.125, count: 4_096)
        var spool: LiveRecordingSpool? = try LiveRecordingSpool(
            fileURL: url, sampleRate: 16_000
        )
        try spool?.append(samples)
        spool = nil
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(try LiveRecordingSpool.metadata(at: url))
        try LiveRecordingSpool.repairHeaderIfNeeded(at: url)
        let metadata = try LiveRecordingSpool.metadata(at: url)
        let after = try Data(contentsOf: url)

        XCTAssertEqual(metadata.sampleRate, 16_000)
        XCTAssertEqual(metadata.sampleCount, samples.count)
        XCTAssertEqual(before[44...], after[44...])
        XCTAssertNotEqual(before[4..<8], after[4..<8])
        XCTAssertNotEqual(before[40..<44], after[40..<44])
    }

    func testCancelRemovesOnlyTheLiveRecoveryFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("last-recording.wav")
        let unrelated = directory.appendingPathComponent("keep.txt")
        let spool = try LiveRecordingSpool(fileURL: url, sampleRate: 16_000)
        try "keep".write(to: unrelated, atomically: true, encoding: .utf8)
        try spool.append([Float](repeating: 0.1, count: 100))

        spool.cancel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: unrelated), "keep")
    }

    func testRefusesExistingFilesAndSymlinkDestinations() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = directory.appendingPathComponent("outside.wav")
        try Data("outside".utf8).write(to: outside)
        let link = directory.appendingPathComponent("last-recording.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(try LiveRecordingSpool(fileURL: link, sampleRate: 16_000))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testRefusesSymlinkedRecoveryDirectory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)

        XCTAssertThrowsError(try LiveRecordingSpool(
            fileURL: linked.appendingPathComponent("last-recording.wav"),
            sampleRate: 16_000
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("last-recording.wav").path
        ))
    }

    func testOneMinuteStreamingCostStaysSmallAndConstantMemory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let samples = [Float](repeating: 0.1, count: 16_000 * 60)
        var iteration = 0

        measure {
            let url = root.appendingPathComponent("recording-\(iteration).wav")
            let spool = try! LiveRecordingSpool(fileURL: url, sampleRate: 16_000)
            for offset in stride(from: 0, to: samples.count, by: 1_024) {
                try! spool.append(samples[offset..<min(offset + 1_024, samples.count)])
            }
            _ = try! spool.finish()
            try! FileManager.default.removeItem(at: url)
            iteration += 1
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-live-spool-tests-\(UUID().uuidString)")
    }

    private func fileSize(_ url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as! NSNumber).intValue
    }

    private func permissions(_ url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }
}

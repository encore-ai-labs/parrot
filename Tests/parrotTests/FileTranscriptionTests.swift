import ArgumentParser
import Foundation
import XCTest

@testable import parrot

final class FileTranscriptionTests: XCTestCase {
    func testAsyncFileWorkDoesNotMoveDaemonOffMainThread() {
        XCTAssertFalse(Parrot.self is AsyncParsableCommand.Type)
        XCTAssertFalse(Run.self is AsyncParsableCommand.Type)
        XCTAssertFalse(Transcribe.self is AsyncParsableCommand.Type)
    }

    func testCommandParsesBatchAndOutputOptions() throws {
        let command = try XCTUnwrap(
            try Transcribe.parseAsRoot([
                "/tmp/one.m4a", "/tmp/two.mp4",
                "--model", "whisper-small.en",
                "--notes", "--lowercase", "--no-vocabulary", "--no-snippets",
                "--format", "json", "--output-directory", "/tmp/transcripts",
                "--no-timestamps", "--force",
            ]) as? Transcribe
        )
        XCTAssertEqual(command.files, ["/tmp/one.m4a", "/tmp/two.mp4"])
        XCTAssertEqual(command.model, "whisper-small.en")
        XCTAssertTrue(command.notes)
        XCTAssertTrue(command.lowercase)
        XCTAssertTrue(command.noVocabulary)
        XCTAssertTrue(command.noSnippets)
        XCTAssertEqual(command.format, .json)
        XCTAssertEqual(command.outputDirectory, "/tmp/transcripts")
        XCTAssertFalse(command.timestamps)
        XCTAssertTrue(command.force)
    }

    func testCommandRejectsAmbiguousOutputAndModeOptions() {
        XCTAssertThrowsError(
            try Transcribe.parseAsRoot(["one.wav", "--notes", "--dictation"])
        )
        XCTAssertThrowsError(
            try Transcribe.parseAsRoot(["one.wav", "--lowercase", "--no-lowercase"])
        )
        XCTAssertThrowsError(
            try Transcribe.parseAsRoot([
                "one.wav", "--stdout", "--output", "one.md",
            ])
        )
        XCTAssertThrowsError(
            try Transcribe.parseAsRoot([
                "one.wav", "two.wav", "--output", "both.md",
            ])
        )
        XCTAssertThrowsError(
            try Transcribe.parseAsRoot(["one.wav", "two.wav", "--stdout"])
        )
    }

    func testPlanUsesAdjacentOutputsAndNeverOverwritesByDefault() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("voice memo.m4a")
        try Data("audio".utf8).write(to: input)

        let jobs = try FileTranscriptionPlan.makeJobs(
            filePaths: [input.path],
            format: .markdown,
            outputPath: nil,
            outputDirectoryPath: nil,
            standardOutput: false,
            force: false
        )
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].input, input)
        XCTAssertEqual(
            jobs[0].destination,
            directory.appendingPathComponent("voice memo.md")
        )

        try Data("existing".utf8).write(to: try XCTUnwrap(jobs[0].destination))
        XCTAssertThrowsError(
            try FileTranscriptionPlan.makeJobs(
                filePaths: [input.path],
                format: .markdown,
                outputPath: nil,
                outputDirectoryPath: nil,
                standardOutput: false,
                force: false
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("pass --force"))
        }
    }

    func testPlanRejectsDuplicateBatchOutputsAndInputReplacement() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstDirectory = directory.appendingPathComponent("first")
        let secondDirectory = directory.appendingPathComponent("second")
        let outputDirectory = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let first = firstDirectory.appendingPathComponent("memo.wav")
        let second = secondDirectory.appendingPathComponent("memo.m4a")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)

        XCTAssertThrowsError(
            try FileTranscriptionPlan.makeJobs(
                filePaths: [first.path, second.path],
                format: .json,
                outputPath: nil,
                outputDirectoryPath: outputDirectory.path,
                standardOutput: false,
                force: true
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("same output"))
        }

        let markdownInput = directory.appendingPathComponent("source.md")
        try Data("source".utf8).write(to: markdownInput)
        XCTAssertThrowsError(
            try FileTranscriptionPlan.makeJobs(
                filePaths: [markdownInput.path],
                format: .markdown,
                outputPath: nil,
                outputDirectoryPath: nil,
                standardOutput: false,
                force: true
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("refusing to replace"))
        }
    }

    func testWriterIsPrivateCollisionSafeAndAtomicallyReplaceable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("private/transcripts", isDirectory: true)
        let output = nested.appendingPathComponent("memo.md")

        try SafeTranscriptWriter.write(Data("first".utf8), to: output, force: false)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "first")
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: nested.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let parentAttributes = try FileManager.default.attributesOfItem(
            atPath: nested.deletingLastPathComponent().path
        )
        XCTAssertEqual((parentAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        XCTAssertThrowsError(
            try SafeTranscriptWriter.write(Data("second".utf8), to: output, force: false)
        )
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "first")

        try SafeTranscriptWriter.write(Data("second".utf8), to: output, force: true)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "second")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: nested.path)
            .filter { $0.hasPrefix(".parrot-transcript.") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testMarkdownAndJSONReportsPreserveTranscriptAndTimestamps() throws {
        let report = sampleReport()
        let markdown = try FileTranscriptRenderer.render(report, format: .markdown)
        XCTAssertTrue(markdown.contains("# memo.m4a"))
        XCTAssertTrue(markdown.contains("- Source: `memo.m4a`"))
        XCTAssertFalse(markdown.contains("/private/tmp"))
        XCTAssertTrue(markdown.contains("## Transcript\n\n# Project notes"))
        XCTAssertTrue(markdown.contains("**[00:01.250–00:03.500]** first segment"))
        XCTAssertTrue(markdown.contains("12.0× realtime"))

        let json = try FileTranscriptRenderer.render(report, format: .json)
        let decoded = try JSONDecoder().decode(FileTranscriptReport.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.segments[0].startSeconds, 1.25)

        XCTAssertEqual(
            try FileTranscriptRenderer.render(report, format: .text),
            "# Project notes\n\n- ship it\n"
        )
    }

    func testProcessingMatchesLiveNoteLowercaseAndSnippetOrder() throws {
        var library = SnippetLibrary()
        try library.set(trigger: "signature", content: "Regards,\nParth")
        let output = TranscriptProcessing.process(
            "Heading two Plan. New task Ship it. Insert snippet signature.",
            mode: .notes,
            lowercase: true,
            snippets: SnippetExpander(entries: library.entries)
        )
        XCTAssertTrue(output.contains("## plan"))
        XCTAssertTrue(output.contains("- [ ] ship it"))
        XCTAssertTrue(output.contains("Regards,\nParth"))
    }

    func testTimestampFormattingHandlesMinuteAndHourBoundaries() {
        XCTAssertEqual(FileTranscriptRenderer.timestamp(0), "00:00.000")
        XCTAssertEqual(FileTranscriptRenderer.timestamp(59.9996), "01:00.000")
        XCTAssertEqual(FileTranscriptRenderer.timestamp(3_661.125), "01:01:01.125")
        XCTAssertEqual(FileTranscriptRenderer.timestamp(-5), "00:00.000")
    }

    private func sampleReport() -> FileTranscriptReport {
        FileTranscriptReport(
            source: "/private/tmp/memo.m4a",
            sourceName: "memo.m4a",
            model: "whisper-base.en",
            mode: "notes",
            language: "en",
            transcribedAt: "2026-09-05T10:00:00.000Z",
            audioSeconds: 6,
            processingSeconds: 0.5,
            realTimeFactor: 1 / 12,
            text: "# Project notes\n\n- ship it",
            segments: [
                TimedTranscriptSegment(
                    startSeconds: 1.25,
                    endSeconds: 3.5,
                    text: "first segment"
                ),
            ]
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-file-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

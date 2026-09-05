import XCTest

@testable import parrot

final class ModelBenchmarkTests: XCTestCase {
    func testMedianForOddAndEvenSamples() {
        XCTAssertEqual(BenchmarkMath.median([3, 1, 2]), 2)
        XCTAssertEqual(BenchmarkMath.median([4, 1, 3, 2]), 2.5)
        XCTAssertEqual(BenchmarkMath.median([]), 0)
    }

    func testWordErrorRateIgnoresCasePunctuationAndDiacritics() {
        XCTAssertEqual(
            BenchmarkMath.wordErrorRate(
                reference: "Café, PARROT! Don't stop.",
                hypothesis: "cafe parrot dont stop"
            ),
            0
        )
    }

    func testWordErrorRateCountsWordEdits() {
        XCTAssertEqual(
            BenchmarkMath.wordErrorRate(
                reference: "the quick brown fox",
                hypothesis: "the slow brown"
            ),
            0.5
        )
        XCTAssertEqual(BenchmarkMath.wordErrorRate(reference: "", hypothesis: "extra"), 1)
    }

    func testBenchmarkCommandParsesInputs() throws {
        let command = try XCTUnwrap(
            try ModelBenchmark.parseAsRoot([
                "whisper-base.en", "--audio", "/tmp/sample.wav",
                "--language", "en",
                "--reference", "hello world", "--runs", "5", "--notes",
                "--spoken-mode-trigger", "--auto-paragraphs", "--no-snippets", "--json",
            ]) as? ModelBenchmark
        )
        XCTAssertEqual(command.id, "whisper-base.en")
        XCTAssertEqual(command.audio, "/tmp/sample.wav")
        XCTAssertEqual(command.language, "en")
        XCTAssertEqual(command.reference, "hello world")
        XCTAssertEqual(command.runs, 5)
        XCTAssertTrue(command.notes)
        XCTAssertTrue(command.spokenModeTrigger)
        XCTAssertTrue(command.automaticParagraphs)
        XCTAssertTrue(command.noSnippets)
        XCTAssertTrue(command.json)
    }

    func testBenchmarkRejectsInvalidRunCountAndTwoReferences() throws {
        XCTAssertThrowsError(
            try ModelBenchmark.parseAsRoot([
                "whisper-base.en", "--audio", "/tmp/sample.wav", "--runs", "0",
            ])
        )
        XCTAssertThrowsError(
            try ModelBenchmark.parseAsRoot([
                "whisper-base.en", "--audio", "/tmp/sample.wav",
                "--reference", "hello", "--reference-file", "/tmp/reference.txt",
            ])
        )
        XCTAssertThrowsError(
            try ModelBenchmark.parseAsRoot([
                "whisper-base.en", "--audio", "/tmp/sample.wav",
                "--auto-paragraphs", "--no-auto-paragraphs",
            ])
        )
    }
}

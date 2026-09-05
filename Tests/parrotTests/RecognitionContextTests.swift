import XCTest

@testable import parrot

final class RecognitionContextTests: XCTestCase {
    func testSourceParsingCanonicalizesAliases() {
        XCTAssertEqual(RecognitionContextSource.parse("off"), .off)
        XCTAssertEqual(RecognitionContextSource.parse(" NONE "), .off)
        XCTAssertEqual(RecognitionContextSource.parse("selection"), .selectedText)
        XCTAssertEqual(RecognitionContextSource.parse("selected-text"), .selectedText)
        XCTAssertEqual(RecognitionContextSource.parse("pasteboard"), .clipboard)
        XCTAssertEqual(RecognitionContextSource.parse("both"), .both)
        XCTAssertNil(RecognitionContextSource.parse("screen"))
    }

    func testOffNeverUsesProvidedText() {
        XCTAssertNil(RecognitionContextBuilder.prepare(
            selectedText: "private selection",
            clipboardText: "private clipboard",
            source: .off
        ))
    }

    func testEachSourceIsStrictlyIsolated() {
        XCTAssertEqual(RecognitionContextBuilder.prepare(
            selectedText: " selected\n words ",
            clipboardText: "clipboard words",
            source: .selectedText
        ), "selected words")
        XCTAssertEqual(RecognitionContextBuilder.prepare(
            selectedText: "selected words",
            clipboardText: " clipboard\twords ",
            source: .clipboard
        ), "clipboard words")
    }

    func testBothPutsSelectionLastAndStaysWithinTotalBound() throws {
        let result = try XCTUnwrap(RecognitionContextBuilder.prepare(
            selectedText: String(repeating: "s", count: 4_000),
            clipboardText: String(repeating: "c", count: 4_000),
            source: .both
        ))

        XCTAssertLessThanOrEqual(result.count, RecognitionContextBuilder.maximumCharacters)
        XCTAssertTrue(result.hasPrefix("ccc"))
        XCTAssertTrue(result.hasSuffix("sss"))
        XCTAssertTrue(result.contains(". "))
    }

    func testSingleSourceKeepsMostRecentBoundedSuffix() throws {
        let selected = "old" + String(repeating: "x", count: 3_000) + "latest"
        let result = try XCTUnwrap(RecognitionContextBuilder.prepare(
            selectedText: selected,
            clipboardText: nil,
            source: .selectedText
        ))

        XCTAssertEqual(result.count, RecognitionContextBuilder.maximumCharacters)
        XCTAssertFalse(result.hasPrefix("old"))
        XCTAssertTrue(result.hasSuffix("latest"))
    }

    func testWhitespaceAndControlCharactersAreNormalized() {
        XCTAssertEqual(RecognitionContextBuilder.prepare(
            selectedText: "one\n\ttwo\u{0000}three",
            clipboardText: nil,
            source: .selectedText
        ), "one two three")
    }

    @MainActor
    func testOffDoesNotCreateACaptureTask() {
        XCTAssertNil(RecognitionContextCapture.start(source: .off))
    }

    func testPromptMergeReservesBoundedSuffixForContext() {
        let persistent = Array(0..<100)
        let context = Array(1_000..<1_100)
        let merged = WhisperKitTranscriber.mergingPromptTokens(
            persistent: persistent,
            context: context
        )

        XCTAssertEqual(merged.count, 96)
        XCTAssertEqual(Array(merged.prefix(64)), Array(persistent.prefix(64)))
        XCTAssertEqual(Array(merged.suffix(32)), Array(context.suffix(32)))
    }

    func testPromptMergeKeepsPersonalizationWorkConstantForShortContext() {
        let merged = WhisperKitTranscriber.mergingPromptTokens(
            persistent: Array(0..<96),
            context: [100, 101]
        )

        XCTAssertEqual(merged.count, 66)
        XCTAssertEqual(Array(merged.prefix(64)), Array(0..<64))
        XCTAssertEqual(Array(merged.suffix(2)), [100, 101])
    }

    func testBoundedPreparationCost() {
        let value = String(repeating: "context value\n", count: 2_000)
        measure {
            for _ in 0..<100 {
                _ = RecognitionContextBuilder.prepare(
                    selectedText: value,
                    clipboardText: value,
                    source: .both
                )
            }
        }
    }
}

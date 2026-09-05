import XCTest

@testable import parrot

final class SpokenEditProcessorTests: XCTestCase {
    func testScratchThatReplacesTheCurrentUnpunctuatedPhrase() {
        XCTAssertEqual(
            SpokenEditProcessor.apply("Buy regular milk scratch that Buy oat milk."),
            "Buy oat milk."
        )
    }

    func testScratchThatKeepsEarlierClausesAndSentences() {
        XCTAssertEqual(
            SpokenEditProcessor.apply(
                "Call Sam after lunch, then send the draft scratch that then send the final."
            ),
            "Call Sam after lunch, then send the final."
        )
        XCTAssertEqual(
            SpokenEditProcessor.apply(
                "Keep this sentence. The deadline is Monday scratch that The deadline is Tuesday."
            ),
            "Keep this sentence. The deadline is Tuesday."
        )
    }

    func testScratchThatRemovesAPhraseWhisperAlreadyPunctuated() {
        XCTAssertEqual(
            SpokenEditProcessor.apply(
                "Keep this sentence. The deadline is Monday. Scratch that. The deadline is Tuesday."
            ),
            "Keep this sentence. The deadline is Tuesday."
        )
        XCTAssertEqual(
            SpokenEditProcessor.apply("Use the red version, never mind, Use the blue version."),
            "Use the blue version."
        )
    }

    func testScratchThatPreservesMarkdownLinePrefix() {
        XCTAssertEqual(
            SpokenEditProcessor.apply("- Buy regular milk scratch that Buy oat milk"),
            "- Buy oat milk"
        )
        XCTAssertEqual(
            SpokenEditProcessor.apply("- [ ] Send draft. Delete that. Send final"),
            "- [ ] Send final"
        )
        XCTAssertEqual(
            SpokenEditProcessor.apply("## Old title scratch that New title"),
            "## New title"
        )
    }

    func testDeleteLastWordHandlesUnicodeAndPunctuation() {
        XCTAssertEqual(
            SpokenEditProcessor.apply(
                "Project codename Sparrow delete last word Parrot."
            ),
            "Project codename Parrot."
        )
        XCTAssertEqual(
            SpokenEditProcessor.apply("Order café, delete previous word tea."),
            "Order tea."
        )
        XCTAssertEqual(
            SpokenEditProcessor.apply("Use version 2.5 delete last word 3.0"),
            "Use version 3.0"
        )
    }

    func testDeleteLastSentenceKeepsEarlierText() {
        XCTAssertEqual(
            SpokenEditProcessor.apply(
                "Keep this. Remove this sentence delete last sentence Add this."
            ),
            "Keep this. Add this."
        )
        XCTAssertEqual(
            SpokenEditProcessor.apply(
                "Keep this. Remove this sentence. Delete previous sentence. Add this."
            ),
            "Keep this. Add this."
        )
    }

    func testUndoRestoresTheMostRecentDeletionAndDropsCorrectionText() {
        XCTAssertEqual(
            SpokenEditProcessor.apply(
                "Wrong phrase scratch that Correct phrase undo that Final words."
            ),
            "Wrong phrase Final words."
        )
        XCTAssertEqual(
            SpokenEditProcessor.apply("Nothing to restore undo that Keep this."),
            "Nothing to restore Keep this."
        )
        XCTAssertEqual(
            SpokenEditProcessor.apply(
                "One. Two scratch that Three scratch that Four "
                    + "undo that undo that Five."
            ),
            "One. Two Five."
        )
    }

    func testLiteralPrefixKeepsEveryEditingCommand() {
        XCTAssertEqual(
            SpokenEditProcessor.apply(
                "Keep literal scratch that, literal delete last word, "
                    + "literal delete last sentence, and literal undo that."
            ),
            "Keep scratch that, delete last word, delete last sentence, and undo that."
        )
    }

    func testCommandsDoNotMatchInsideWordsOrTreatActuallyAsSemanticEdit() {
        let text = "The scratch thatcher never minded this. I actually prefer the original."
        XCTAssertEqual(SpokenEditProcessor.apply(text), text)
    }

    func testDecimalPunctuationDoesNotCreateAFalseClauseBoundary() {
        XCTAssertEqual(
            SpokenEditProcessor.apply(
                "Set threshold to 2.5 units scratch that Set threshold to 3.0 units."
            ),
            "Set threshold to 3.0 units."
        )
    }

    func testNotePipelineEditsAfterMarkdownFormattingButBeforeSnippets() {
        let snippets = SnippetExpander(entries: [
            SnippetEntry(trigger: "template", content: "Keep scratch that exactly"),
        ])
        XCTAssertEqual(
            TranscriptProcessing.process(
                "Bullet point Buy milk scratch that Buy oat milk. "
                    + "Next bullet insert snippet template.",
                mode: .notes,
                lowercase: false,
                snippets: snippets
            ),
            "- Buy oat milk.\n- Keep scratch that exactly"
        )
    }

    func testPlainDictationNeverRunsSpokenEdits() {
        XCTAssertEqual(
            TranscriptProcessing.process(
                "Keep this scratch that Keep both.",
                mode: .dictation,
                lowercase: false,
                snippets: SnippetExpander(entries: [])
            ),
            "Keep this scratch that Keep both."
        )
    }

    func testEditingCostStaysBoundedForLongNotes() {
        let paragraph = "Keep this sentence. Remove this phrase scratch that Replace it. "
        let input = String(repeating: paragraph, count: 100)
        var output = ""
        measure {
            for _ in 0..<10 {
                output = SpokenEditProcessor.apply(input)
            }
        }
        XCTAssertFalse(output.contains("Remove this phrase"))
    }
}

import XCTest

@testable import parrot

final class SpokenModeTriggerTests: XCTestCase {
    private let snippets = SnippetExpander(entries: [])

    func testLeadingNoteModeSelectsNotesAndRemovesTheTrigger() {
        XCTAssertEqual(
            SpokenModeTrigger.resolve(
                "Note mode, bullet point Ship the release.",
                fallbackMode: .dictation
            ),
            .init(
                text: "bullet point Ship the release.",
                mode: .notes,
                wasTriggered: true
            )
        )
        XCTAssertEqual(
            SpokenModeTrigger.resolve("notes mode:Plan", fallbackMode: .dictation),
            .init(text: "Plan", mode: .notes, wasTriggered: true)
        )
    }

    func testLeadingDictationModeSelectsPlainDictation() {
        XCTAssertEqual(
            SpokenModeTrigger.resolve(
                "Dictation mode. Bullet point stays spoken.",
                fallbackMode: .notes
            ),
            .init(
                text: "Bullet point stays spoken.",
                mode: .dictation,
                wasTriggered: true
            )
        )
    }

    func testLiteralPrefixEscapesEitherModeCommand() {
        XCTAssertEqual(
            SpokenModeTrigger.resolve(
                "literal note mode is useful.",
                fallbackMode: .dictation
            ),
            .init(
                text: "note mode is useful.",
                mode: .dictation,
                wasTriggered: false
            )
        )
        XCTAssertEqual(
            SpokenModeTrigger.resolve(
                "Literal dictation mode is useful.",
                fallbackMode: .notes
            ),
            .init(
                text: "dictation mode is useful.",
                mode: .notes,
                wasTriggered: false
            )
        )
    }

    func testNonLeadingAndEmbeddedPhrasesRemainByteStable() {
        for text in [
            "Explain note mode",
            "This note models the plan.",
            "Notebook mode is unrelated.",
            "The current dictation mode",
        ] {
            XCTAssertEqual(
                SpokenModeTrigger.resolve(text, fallbackMode: .dictation),
                .init(text: text, mode: .dictation, wasTriggered: false)
            )
        }
    }

    func testACommandOnlyCaptureSelectsModeAndProducesNoText() {
        XCTAssertEqual(
            SpokenModeTrigger.resolve("  NOTES MODE!  ", fallbackMode: .dictation),
            .init(text: "", mode: .notes, wasTriggered: true)
        )
    }

    func testLivePipelineAppliesTheSelectedModeForOneCapture() {
        XCTAssertEqual(
            TranscriptProcessing.processWithSpokenModeTrigger(
                "Note mode bullet point Ship it. New task Tell the team.",
                fallbackMode: .dictation,
                lowercase: false,
                snippets: snippets
            ),
            .init(
                text: "- Ship it.\n- [ ] Tell the team.",
                mode: .notes,
                usedSpokenModeTrigger: true
            )
        )
        XCTAssertEqual(
            TranscriptProcessing.processWithSpokenModeTrigger(
                "Dictation mode bullet point Ship it.",
                fallbackMode: .notes,
                lowercase: false,
                snippets: snippets
            ),
            .init(
                text: "bullet point Ship it.",
                mode: .dictation,
                usedSpokenModeTrigger: true
            )
        )
    }

    func testAutomaticParagraphsUseTheOriginalTimedTranscript() {
        let raw = "Note mode First thought. Second thought."
        let segments = [
            TimedTranscriptSegment(
                startSeconds: 0,
                endSeconds: 1,
                text: "Note mode First thought."
            ),
            TimedTranscriptSegment(
                startSeconds: 2.5,
                endSeconds: 3.2,
                text: "Second thought."
            ),
        ]
        XCTAssertEqual(
            TranscriptProcessing.processWithSpokenModeTrigger(
                raw,
                fallbackMode: .dictation,
                lowercase: false,
                automaticParagraphs: true,
                segments: segments,
                snippets: snippets
            ).text,
            "First thought.\n\nSecond thought."
        )
    }

    func testStoredMediaPipelineDoesNotInterpretModeTriggers() {
        XCTAssertEqual(
            TranscriptProcessing.process(
                "Note mode bullet point keep every word.",
                mode: .dictation,
                lowercase: false,
                snippets: snippets
            ),
            "Note mode bullet point keep every word."
        )
    }

    func testNoTriggerPathStaysCheapForLongNotes() {
        let input = String(repeating: "Ordinary dictated sentence. ", count: 300)
        var output = ""
        measure {
            for _ in 0..<100 {
                output = SpokenModeTrigger.resolve(input, fallbackMode: .dictation).text
            }
        }
        XCTAssertEqual(output, input)
    }
}

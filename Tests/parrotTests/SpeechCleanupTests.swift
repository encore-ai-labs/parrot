import XCTest

@testable import parrot

final class SpeechCleanupTests: XCTestCase {
    func testRemovesOnlyUnambiguousStandaloneHesitations() {
        XCTAssertEqual(
            SpeechCleanup.clean("Um, I think we should, uh, ship this. Erm. Yes."),
            "I think we should, ship this. Yes."
        )
        XCTAssertEqual(SpeechCleanup.clean("uh umm uhhh uhm erm"), "")
        XCTAssertEqual(
            SpeechCleanup.clean("UM and UML use example.com/um, uh-huh, um_based, and um-driven logic."),
            "UM and UML use example.com/um, uh-huh, um_based, and um-driven logic."
        )
    }

    func testCollapsesCommaSeparatedFalseStarts() {
        XCTAssertEqual(
            SpeechCleanup.clean(
                "I wanted to, I wanted to check the launch plan and, and confirm Friday."
            ),
            "I wanted to check the launch plan and confirm Friday."
        )
        XCTAssertEqual(
            SpeechCleanup.clean("We need to, we need to, we need to finish screenshots."),
            "We need to finish screenshots."
        )
    }

    func testCollapsesConservativeFunctionWordAndPrefixStutters() {
        XCTAssertEqual(
            SpeechCleanup.clean("I I think we we should w- write the the note."),
            "I think we should write the note."
        )
    }

    func testPreservesPotentiallyMeaningfulLanguage() {
        let text = "I like like-minded people. Very very good. Very, very good. No, no, no. He had had lunch. The fact that that worked matters. Hmm, okay, right."
        XCTAssertEqual(SpeechCleanup.clean(text), text)
    }

    func testPreservesLineStructureAndUnicode() {
        XCTAssertEqual(
            SpeechCleanup.clean("  ## Café  \n  - Um, résumé review  \n  - naïve approach  "),
            "## Café\n- résumé review\n- naïve approach"
        )
    }

    func testPipelineCleansBeforeFormattingAndSnippetExpansion() throws {
        var snippets = SnippetLibrary()
        try snippets.set(trigger: "raw", content: "Um, keep  double spaces")
        let output = TranscriptProcessing.process(
            "Um, heading two Notes. I wanted to, I wanted to begin. Insert snippet raw.",
            mode: .notes,
            lowercase: false,
            cleanup: true,
            snippets: SnippetExpander(entries: snippets.entries)
        )

        XCTAssertEqual(
            output,
            "## Notes. I wanted to begin. Um, keep  double spaces"
        )
    }

    func testCleanupPerformanceOnLongDraft() {
        let sentence = "Um, I wanted to, I wanted to record the launch note and and send it. "
        let draft = String(repeating: sentence, count: 200)

        measure {
            for _ in 0..<20 {
                _ = SpeechCleanup.clean(draft)
            }
        }
    }

    func testCleanupPerformanceOnTypicalDictation() {
        let draft = "Um, I wanted to, I wanted to capture a quick project note and and share it after I review the screenshots."

        measure {
            for _ in 0..<1_000 {
                _ = SpeechCleanup.clean(draft)
            }
        }
    }
}

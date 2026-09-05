import XCTest

@testable import parrot

final class NoteFormatterTests: XCTestCase {
    func testParagraphsAndLines() {
        XCTAssertEqual(
            NoteFormatter.format(
                "First thought. New paragraph. Second thought new line third thought."
            ),
            "First thought.\n\nSecond thought\nthird thought."
        )
    }

    func testMarkdownListsAndTasks() {
        XCTAssertEqual(
            NoteFormatter.format(
                "Bullet point Buy milk. Next bullet Call Sam. New task Send the notes."
            ),
            "- Buy milk.\n- Call Sam.\n- [ ] Send the notes."
        )
        XCTAssertEqual(
            NoteFormatter.format("Numbered item First. Next numbered item Second."),
            "1. First.\n1. Second."
        )
    }

    func testAcceptsCommonBulletRecognitionVariants() {
        XCTAssertEqual(
            NoteFormatter.format(
                "Bullet points Ship the release. Next bullet point Tell the team."
            ),
            "- Ship the release.\n- Tell the team."
        )
    }

    func testMarkdownHeadings() {
        XCTAssertEqual(
            NoteFormatter.format(
                "Heading one Project Alpha. Heading two Decisions. Bullet point Ship Friday."
            ),
            "# Project Alpha.\n\n## Decisions.\n- Ship Friday."
        )
    }

    func testHeadingNumberHomophonesFromSpeechRecognition() {
        XCTAssertEqual(
            NoteFormatter.format("heading won Overview heading to Details heading tree Appendix"),
            "# Overview\n\n## Details\n\n### Appendix"
        )
    }

    func testSpokenPunctuation() {
        XCTAssertEqual(
            NoteFormatter.format(
                "Hello comma world period New paragraph Is this ready question mark"
            ),
            "Hello, world.\n\nIs this ready?"
        )
        XCTAssertEqual(
            NoteFormatter.format("One colon two semicolon three em dash four exclamation point"),
            "One: two; three— four!"
        )
    }

    func testLiteralPrefixEscapesCommands() {
        XCTAssertEqual(
            NoteFormatter.format(
                "Say literal new paragraph and literal bullet point period"
            ),
            "Say new paragraph and bullet point."
        )
        XCTAssertEqual(
            NoteFormatter.format("Keep literal New Paragraph capitalized"),
            "Keep New Paragraph capitalized"
        )
    }

    func testCommandsDoNotMatchInsideWords() {
        XCTAssertEqual(
            NoteFormatter.format("A periodical headington bullet pointer."),
            "A periodical headington bullet pointer."
        )
    }

    func testNotesFlagIsExplicitAndHasAlias() throws {
        let notes = try XCTUnwrap(try Run.parseAsRoot(["--notes"]) as? Run)
        let alias = try XCTUnwrap(try Run.parseAsRoot(["--note-mode"]) as? Run)
        let dictation = try XCTUnwrap(try Run.parseAsRoot(["--dictation"]) as? Run)

        XCTAssertTrue(notes.noteMode)
        XCTAssertTrue(alias.noteMode)
        XCTAssertTrue(dictation.dictationMode)
        XCTAssertFalse(try XCTUnwrap(try Run.parseAsRoot([]) as? Run).noteMode)
    }

    func testAutomaticParagraphFlagsParseAndConflict() throws {
        let enabled = try XCTUnwrap(
            try Run.parseAsRoot(["--notes", "--auto-paragraphs"]) as? Run
        )
        XCTAssertTrue(enabled.automaticParagraphs)

        let disabled = try XCTUnwrap(
            try Run.parseAsRoot(["--notes", "--no-auto-paragraphs"]) as? Run
        )
        XCTAssertTrue(disabled.noAutomaticParagraphs)
        XCTAssertThrowsError(try Run.parseAsRoot([
            "--auto-paragraphs", "--no-auto-paragraphs",
        ]))
    }

    func testFormatterPerformance() {
        let input = """
        Heading one Weekly review. New paragraph. Bullet point Finished the local history search.
        Next bullet Fixed the update flow. New task Benchmark the next model. New paragraph. Done.
        """
        var output = ""
        measure {
            for _ in 0..<1_000 {
                output = NoteFormatter.format(input)
            }
        }
        XCTAssertTrue(output.contains("# Weekly review"))
    }
}

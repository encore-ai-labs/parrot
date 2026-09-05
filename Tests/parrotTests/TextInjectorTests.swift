import XCTest

@testable import parrot

final class TextInjectorTests: XCTestCase {
    func testAddsOneDeliveryOnlyBoundarySpace() {
        XCTAssertEqual(
            TextInjector.preparedText("First thought.", appendSpace: true),
            "First thought. "
        )
        XCTAssertEqual(
            TextInjector.preparedText("- [ ] Follow up", appendSpace: true),
            "- [ ] Follow up "
        )
    }

    func testDoesNotDoubleExistingWhitespace() {
        for text in ["Already spaced ", "Line break\n", "Tabbed\t"] {
            XCTAssertEqual(TextInjector.preparedText(text, appendSpace: true), text)
        }
    }

    func testExactModeAndEmptyTextRemainByteStable() {
        let text = "Exact\nMarkdown"
        XCTAssertEqual(TextInjector.preparedText(text, appendSpace: false), text)
        XCTAssertEqual(TextInjector.preparedText("", appendSpace: true), "")
    }

    func testRunFlagsParseAndConflict() throws {
        let enabled = try XCTUnwrap(
            try Run.parseAsRoot(["--space-after-paste"]) as? Run
        )
        XCTAssertTrue(enabled.spaceAfterPaste)

        let disabled = try XCTUnwrap(
            try Run.parseAsRoot(["--no-space-after-paste"]) as? Run
        )
        XCTAssertTrue(disabled.noSpaceAfterPaste)

        XCTAssertThrowsError(try Run.parseAsRoot([
            "--space-after-paste", "--no-space-after-paste",
        ]))
    }

    func testBoundaryPreparationCostStaysNegligibleForLongNotes() {
        let input = String(repeating: "A representative dictated sentence. ", count: 250)
            .trimmingCharacters(in: .whitespaces)
        var output = ""
        measure {
            for _ in 0..<1_000 {
                output = TextInjector.preparedText(input, appendSpace: true)
            }
        }
        XCTAssertEqual(output.count, input.count + 1)
    }
}

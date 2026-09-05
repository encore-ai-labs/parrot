import XCTest

@testable import parrot

final class AutomaticParagraphFormatterTests: XCTestCase {
    func testInsertsParagraphOnlyAtDeliberatePause() {
        let text = "First thought continues here. Second thought starts here. Final detail."
        let segments = [
            segment(0, 1.0, "First thought continues here."),
            segment(1.4, 2.2, "Second thought starts here."),
            segment(3.5, 4.0, "Final detail."),
        ]

        XCTAssertEqual(
            AutomaticParagraphFormatter.format(text, segments: segments),
            "First thought continues here. Second thought starts here.\n\nFinal detail."
        )
    }

    func testLeavesTextByteStableWithoutQualifyingPause() {
        let text = "Keep   the model's original spacing."
        let segments = [
            segment(0, 1, "Keep the model's"),
            segment(1.4, 2, "original spacing."),
        ]

        XCTAssertEqual(
            AutomaticParagraphFormatter.format(text, segments: segments),
            text
        )
    }

    func testFallsBackWhenSegmentsDoNotReconstructTranscript() {
        let text = "RustPond ships today."
        let segments = [
            segment(0, 0.5, "rust"),
            segment(2, 2.5, "pond ships today."),
        ]

        XCTAssertEqual(
            AutomaticParagraphFormatter.format(text, segments: segments),
            text
        )
    }

    func testPreservesExplicitLineStructure() {
        let text = "# Plan\n\nKeep the existing structure."
        let segments = [
            segment(0, 0.5, "# Plan"),
            segment(2, 3, "Keep the existing structure."),
        ]

        XCTAssertEqual(
            AutomaticParagraphFormatter.format(text, segments: segments),
            text
        )
    }

    func testSortsSegmentsAndTreatsOverlapsAsNoPause() {
        let text = "One two three."
        let segments = [
            segment(0.8, 1.2, "three."),
            segment(0, 0.6, "One two"),
        ]

        XCTAssertEqual(
            AutomaticParagraphFormatter.format(text, segments: segments),
            text
        )
    }

    func testFormattingCostStaysBoundedForLongNotes() {
        let segments = (0..<200).map { index in
            segment(
                Double(index) * 0.6,
                Double(index) * 0.6 + 0.3,
                "word\(index)"
            )
        }
        let text = segments.map(\.text).joined(separator: " ")
        var output = ""

        measure {
            for _ in 0..<100 {
                output = AutomaticParagraphFormatter.format(text, segments: segments)
            }
        }
        XCTAssertEqual(output, text)
    }

    private func segment(
        _ start: Double,
        _ end: Double,
        _ text: String
    ) -> TimedTranscriptSegment {
        TimedTranscriptSegment(startSeconds: start, endSeconds: end, text: text)
    }
}

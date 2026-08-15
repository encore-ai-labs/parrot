import XCTest

@testable import parrot

/// Regression tests for the transcript sanitizer.
///
/// The first implementation stripped anything between brackets, which quietly
/// destroyed dictated text — "multiply 2 * 3 and then 5 * 6" arrived as
/// "multiply 2 6". Every case in `testKeepsDictatedText` is a real failure that
/// shipped in v0.1.0 through v0.3.0.
final class TranscriptSanitizerTests: XCTestCase {

    // MARK: - The regression that prompted all this

    func testKeepsDictatedText() {
        let unchanged = [
            "multiply 2 * 3 and then 5 * 6",
            "multiply 2 * 3 and then 5 * 6 equals thirty",
            "the value (roughly ten) is fine",
            "use array[0] to index it",
            "call foo(x) then bar(y)",
            "set list[N] to the result",
            "he said (quietly) that it was fine",
            "the formula is a * b * c",
            "5 * 5 is 25",
        ]
        for input in unchanged {
            XCTAssertEqual(
                TranscriptSanitizer.sanitize(input), input,
                "sanitize must not alter dictated text: \(input)"
            )
        }
    }

    // MARK: - What it's actually for

    func testStripsWhisperAnnotations() {
        let cases: [(String, String)] = [
            ("[BLANK_AUDIO]", ""),
            ("[MUSIC]", ""),
            ("[Applause]", ""),
            ("(silence)", ""),
            ("(music playing)", ""),
            ("<|nospeech|>", ""),
            ("<|endoftext|>", ""),
            ("[BLANK_AUDIO] hello there", "hello there"),
            ("hello there [MUSIC]", "hello there"),
            ("hello [BLANK_AUDIO] there", "hello there"),
            ("<|startoftranscript|>hello<|endoftext|>", "hello"),
            ("[SPEAKER_01]", ""),
            ("(background noise)", ""),
            ("(wind blowing)", ""),
            ("*laughs*", ""),
            ("*coughs* excuse me", "excuse me"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(
                TranscriptSanitizer.sanitize(input), expected,
                "input: \(input)"
            )
        }
    }

    /// A lone bracketed span is an annotation by elimination — nobody dictates
    /// a sentence that is only a parenthetical, but silence yields exactly this.
    func testStripsUnknownTagWhenItIsTheWholeTranscript() {
        XCTAssertEqual(TranscriptSanitizer.sanitize("[whirring sound]"), "")
        XCTAssertEqual(TranscriptSanitizer.sanitize("(some odd artifact)"), "")
        // ...but the same text mid-sentence is left alone.
        XCTAssertEqual(
            TranscriptSanitizer.sanitize("the box (some odd artifact) works"),
            "the box (some odd artifact) works"
        )
    }

    // MARK: - Cleanup

    func testTidiesWhitespaceAfterRemoval() {
        XCTAssertEqual(TranscriptSanitizer.sanitize("hello   there"), "hello there")
        XCTAssertEqual(TranscriptSanitizer.sanitize("hello [MUSIC] , there"), "hello, there")
        XCTAssertEqual(TranscriptSanitizer.sanitize("  padded  "), "padded")
        XCTAssertEqual(TranscriptSanitizer.sanitize("hello [MUSIC]."), "hello.")
    }

    func testEmptyAndWhitespaceInput() {
        XCTAssertEqual(TranscriptSanitizer.sanitize(""), "")
        XCTAssertEqual(TranscriptSanitizer.sanitize("   "), "")
        XCTAssertEqual(TranscriptSanitizer.sanitize("\n\t"), "")
    }

    // MARK: - Classification

    func testNonSpeechClassification() {
        for yes in ["silence", "MUSIC", "Blank_Audio", "applause", "background noise",
                    "speaking in Spanish", "sound of a door", "upbeat music", "no speech"] {
            XCTAssertTrue(TranscriptSanitizer.isNonSpeech(yes), "should be non-speech: \(yes)")
        }
        for no in ["roughly ten", "0", "x", "quietly", "see figure 3", "n + 1"] {
            XCTAssertFalse(TranscriptSanitizer.isNonSpeech(no), "should be speech: \(no)")
        }
    }

    /// The classic Whisper silence hallucination has no brackets, so the
    /// sanitizer can't catch it — that's the energy gate's job, not this one.
    func testDocumentsWhatSanitizeCannotCatch() {
        XCTAssertEqual(TranscriptSanitizer.sanitize("Thank you."), "Thank you.")
    }
}

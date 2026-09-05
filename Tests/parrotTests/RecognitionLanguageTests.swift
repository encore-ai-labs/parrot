import XCTest

@testable import parrot

final class RecognitionLanguageTests: XCTestCase {
    func testCanonicalizesCodesNamesRegionsAndAutomaticAliases() {
        XCTAssertEqual(RecognitionLanguage.canonicalize("Spanish"), "es")
        XCTAssertEqual(RecognitionLanguage.canonicalize("PT_br"), "pt")
        XCTAssertEqual(RecognitionLanguage.canonicalize("detect automatically"), "auto")
        XCTAssertEqual(RecognitionLanguage.canonicalize("automatic detection"), "auto")
        XCTAssertEqual(RecognitionLanguage.canonicalize("yue"), "yue")
        XCTAssertNil(RecognitionLanguage.canonicalize("Klingon"))
        XCTAssertNil(RecognitionLanguage.canonicalize("  "))
    }

    func testModelCompatibilityAndAutomaticDecoderChoice() throws {
        let english = try XCTUnwrap(ModelRegistry.find("whisper-base.en"))
        let multilingual = try XCTUnwrap(ModelRegistry.find("whisper-base"))
        let parakeet = try XCTUnwrap(ModelRegistry.find("parakeet-tdt-ctc-110m.en"))

        XCTAssertTrue(RecognitionLanguage.isSupported("auto", by: english))
        XCTAssertTrue(RecognitionLanguage.isSupported("en", by: parakeet))
        XCTAssertFalse(RecognitionLanguage.isSupported("es", by: english))
        XCTAssertFalse(RecognitionLanguage.isSupported("fr", by: parakeet))
        XCTAssertTrue(RecognitionLanguage.isSupported("haw", by: multilingual))
        XCTAssertEqual(
            RecognitionLanguage.decoderLanguage(requested: "auto", model: english),
            "en"
        )
        XCTAssertNil(
            RecognitionLanguage.decoderLanguage(requested: "auto", model: multilingual)
        )
        XCTAssertEqual(
            RecognitionLanguage.decoderLanguage(requested: "Spanish", model: multilingual),
            "es"
        )
    }

    func testMultilingualModelsAreRegisteredWithoutChangingEnglishDefault() {
        XCTAssertEqual(ModelRegistry.recommended()?.id, "whisper-base.en")
        XCTAssertEqual(ModelRegistry.find("whisper-base")?.whisperKitID, "openai_whisper-base")
        XCTAssertEqual(ModelRegistry.find("whisper-small")?.whisperKitID, "openai_whisper-small")
        XCTAssertEqual(ModelRegistry.find("whisper-base")?.languages, ["multi"])
    }

    func testDecoderOptionsDetectOnlyWhenLanguageIsAutomatic() {
        let automatic = WhisperKitTranscriber.decodingOptions(
            promptTerms: [],
            tokenizer: nil,
            language: nil
        )
        XCTAssertNil(automatic.language)
        XCTAssertTrue(automatic.detectLanguage)
        XCTAssertTrue(automatic.usePrefillPrompt)

        let spanish = WhisperKitTranscriber.decodingOptions(
            promptTerms: [],
            tokenizer: nil,
            language: "es"
        )
        XCTAssertEqual(spanish.language, "es")
        XCTAssertFalse(spanish.detectLanguage)
        XCTAssertTrue(spanish.usePrefillPrompt)
    }

    func testEnglishCleanupIsNeverAppliedToAnotherDetectedLanguage() {
        XCTAssertTrue(RecognitionLanguage.supportsEnglishCleanup("en"))
        XCTAssertTrue(RecognitionLanguage.supportsEnglishCleanup("English"))
        XCTAssertFalse(RecognitionLanguage.supportsEnglishCleanup("es"))
        XCTAssertFalse(RecognitionLanguage.supportsEnglishCleanup("auto"))
        XCTAssertFalse(RecognitionLanguage.supportsEnglishCleanup("unknown"))
    }

    func testLanguagesAndRunFlagsParse() throws {
        XCTAssertTrue(try Parrot.parseAsRoot(["languages"]) is Languages)
        let run = try XCTUnwrap(
            try Run.parseAsRoot([
                "--model", "whisper-base", "--language", "Spanish", "--context", "both",
            ]) as? Run
        )
        XCTAssertEqual(run.model, "whisper-base")
        XCTAssertEqual(run.language, "Spanish")
        XCTAssertEqual(run.recognitionContext, "both")
        XCTAssertThrowsError(try Run.parseAsRoot(["--context", "screen"]))
    }
}

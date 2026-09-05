import Foundation

enum TranscriberFactory {
    static func make(
        model: TranscriptionModel,
        language: String = RecognitionLanguage.automatic,
        automaticParagraphs: Bool = false,
        vocabulary: PersonalVocabulary = PersonalVocabulary(),
        additionalPromptTerms: [String] = [],
        notePromptTerms: [String] = []
    ) -> any Transcriber {
        precondition(
            RecognitionLanguage.isSupported(language, by: model),
            "unsupported language \(language) for \(model.id)"
        )
        switch model.engine {
        case .whisperKit:
            return WhisperKitTranscriber(
                model: model,
                language: RecognitionLanguage.decoderLanguage(
                    requested: language,
                    model: model
                ),
                automaticParagraphs: automaticParagraphs,
                vocabulary: vocabulary,
                additionalPromptTerms: additionalPromptTerms,
                notePromptTerms: notePromptTerms
            )
        case .parakeet:
            return ParakeetTranscriber(
                model: model,
                automaticParagraphs: automaticParagraphs,
                vocabulary: vocabulary
            )
        }
    }
}

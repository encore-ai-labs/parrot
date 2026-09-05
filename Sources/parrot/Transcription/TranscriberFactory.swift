import Foundation

enum TranscriberFactory {
    static func make(
        model: TranscriptionModel,
        vocabulary: PersonalVocabulary = PersonalVocabulary(),
        additionalPromptTerms: [String] = [],
        notePromptTerms: [String] = []
    ) -> any Transcriber {
        switch model.engine {
        case .whisperKit:
            return WhisperKitTranscriber(
                model: model,
                vocabulary: vocabulary,
                additionalPromptTerms: additionalPromptTerms,
                notePromptTerms: notePromptTerms
            )
        case .parakeet:
            return ParakeetTranscriber(
                model: model,
                vocabulary: vocabulary
            )
        }
    }
}

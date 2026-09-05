import Foundation

protocol Transcriber: Sendable {
    var modelID: String { get }
    func warmUp() async throws
    func updatePersonalization(_ personalization: TranscriberPersonalization) async
    func transcribe(_ audio: [Float]) async throws -> LiveTranscription
    func transcribe(_ audio: [Float], mode: DictationMode) async throws -> LiveTranscription
    func transcribeFile(at url: URL, mode: DictationMode) async throws -> TimedTranscription
}

/// Immutable, bounded recognition state that can be replaced between
/// captures without reloading the speech model.
struct TranscriberPersonalization: Sendable {
    let revision: UInt64
    let vocabularyReplacer: VocabularyReplacer
    let promptTerms: [String]
}

extension Transcriber {
    func transcribe(_ audio: [Float]) async throws -> LiveTranscription {
        try await transcribe(audio, mode: .dictation)
    }
}

struct LiveTranscription: Equatable, Sendable {
    let text: String
    let language: String
    let segments: [TimedTranscriptSegment]

    init(
        text: String,
        language: String,
        segments: [TimedTranscriptSegment] = []
    ) {
        self.text = text
        self.language = language
        self.segments = segments
    }
}

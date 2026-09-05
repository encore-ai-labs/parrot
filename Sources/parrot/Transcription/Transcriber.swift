import Foundation

protocol Transcriber: Sendable {
    var modelID: String { get }
    func warmUp() async throws
    func transcribe(_ audio: [Float]) async throws -> LiveTranscription
    func transcribe(_ audio: [Float], mode: DictationMode) async throws -> LiveTranscription
    func transcribeFile(at url: URL, mode: DictationMode) async throws -> TimedTranscription
}

extension Transcriber {
    func transcribe(_ audio: [Float]) async throws -> LiveTranscription {
        try await transcribe(audio, mode: .dictation)
    }
}

struct LiveTranscription: Equatable, Sendable {
    let text: String
    let language: String
}

import Foundation

protocol Transcriber: Sendable {
    var modelID: String { get }
    func warmUp() async throws
    func transcribe(_ audio: [Float]) async throws -> String
    func transcribe(_ audio: [Float], mode: DictationMode) async throws -> String
    func transcribeFile(at url: URL, mode: DictationMode) async throws -> TimedTranscription
}

extension Transcriber {
    func transcribe(_ audio: [Float]) async throws -> String {
        try await transcribe(audio, mode: .dictation)
    }
}

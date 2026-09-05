import Foundation
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private let vocabularyReplacer: VocabularyReplacer
    private var pipeline: WhisperKit?
    private var decodingOptions: DecodingOptions?

    init(
        model: TranscriptionModel,
        vocabulary: PersonalVocabulary = PersonalVocabulary(),
        additionalPromptTerms: [String] = []
    ) {
        self.modelID = model.id
        self.model = model
        vocabularyReplacer = VocabularyReplacer(entries: vocabulary.entries)
        promptTerms = additionalPromptTerms + vocabulary.promptTerms
    }

    private let promptTerms: [String]

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
    func warmUp() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        let config = WhisperKitConfig(model: whisperKitID, verbose: false, prewarm: true, load: true)
        let loadedPipeline = try await WhisperKit(config)
        pipeline = loadedPipeline
        decodingOptions = Self.decodingOptions(
            promptTerms: promptTerms,
            tokenizer: loadedPipeline.tokenizer
        )
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let results = try await pipeline.transcribe(
            audioArray: audio,
            decodeOptions: decodingOptions
        )
        let raw = results.map(\.text).joined(separator: " ")
        return vocabularyReplacer.applying(to: TranscriptSanitizer.sanitize(raw))
    }

    /// Prompt prefill improves recognition of names and jargon, but an
    /// unbounded vocabulary would trade away both latency and output context.
    /// Ninety-six tokens is enough for the newest couple dozen short terms and
    /// keeps the fast dictation path effectively constant-sized.
    private static func decodingOptions(
        promptTerms: [String],
        tokenizer: WhisperTokenizer?
    ) -> DecodingOptions? {
        guard !promptTerms.isEmpty, let tokenizer else { return nil }

        let maximumPromptTokens = 96
        var tokens: [Int] = []
        for term in promptTerms {
            let encoded = tokenizer.encode(text: " \(term).")
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            guard !encoded.isEmpty, tokens.count + encoded.count <= maximumPromptTokens else {
                continue
            }
            tokens.append(contentsOf: encoded)
        }
        guard !tokens.isEmpty else { return nil }

        var options = DecodingOptions()
        options.promptTokens = tokens
        options.usePrefillPrompt = true
        return options
    }
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
}

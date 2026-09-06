import Foundation
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private var vocabularyReplacer: VocabularyReplacer
    private let storage: ModelStorage
    private let downloadProgress: ModelDownloadProgress
    /// Nil requests per-recording language detection from a multilingual model.
    private let language: String?
    private let automaticParagraphs: Bool
    private var pipeline: WhisperKit?
    private var decodingOptions: DecodingOptions?
    private var noteDecodingOptions: DecodingOptions?

    init(
        model: TranscriptionModel,
        language: String?,
        automaticParagraphs: Bool,
        vocabulary: PersonalVocabulary = PersonalVocabulary(),
        additionalPromptTerms: [String] = [],
        notePromptTerms: [String] = [],
        storage: ModelStorage = .default,
        downloadProgress: ModelDownloadProgress = ModelDownloadProgress()
    ) {
        self.modelID = model.id
        self.model = model
        self.storage = storage
        self.downloadProgress = downloadProgress
        self.language = language
        self.automaticParagraphs = automaticParagraphs
        vocabularyReplacer = VocabularyReplacer(entries: vocabulary.entries)
        promptTerms = additionalPromptTerms + vocabulary.promptTerms
        self.notePromptTerms = notePromptTerms
    }

    private var promptTerms: [String]
    private let notePromptTerms: [String]
    private var personalizationRevision: UInt64 = 0

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
    func warmUp() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        let resolved: ResolvedModelStorage
        do {
            resolved = try await storage.resolve(
                variant: whisperKitID,
                progressCallback: { [downloadProgress] progress in
                    downloadProgress.update(progress)
                }
            )
        } catch {
            downloadProgress.finish()
            throw error
        }
        downloadProgress.finish()
        let config = WhisperKitConfig(
            model: whisperKitID,
            downloadBase: resolved.downloadBase,
            modelFolder: resolved.modelFolder.path,
            tokenizerFolder: resolved.tokenizerFolder,
            verbose: false,
            prewarm: true,
            load: true
        )
        let loadedPipeline = try await WhisperKit(config)
        pipeline = loadedPipeline
        rebuildDecodingOptions(tokenizer: loadedPipeline.tokenizer)
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    /// Rebuilds only the bounded prompt tokens and deterministic replacer.
    /// The loaded Core ML pipeline stays resident and untouched.
    func updatePersonalization(_ personalization: TranscriberPersonalization) async {
        guard personalization.revision != personalizationRevision else { return }
        personalizationRevision = personalization.revision
        vocabularyReplacer = personalization.vocabularyReplacer
        promptTerms = personalization.promptTerms
        if let tokenizer = pipeline?.tokenizer {
            rebuildDecodingOptions(tokenizer: tokenizer)
        }
    }

    func transcribe(
        _ audio: [Float],
        mode: DictationMode,
        recognitionContext: String?
    ) async throws -> LiveTranscription {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let basePromptTerms = mode == .notes ? notePromptTerms + promptTerms : promptTerms
        let contextualOptions: DecodingOptions?
        if let recognitionContext {
            contextualOptions = Self.decodingOptions(
                promptTerms: basePromptTerms,
                recognitionContext: recognitionContext,
                tokenizer: pipeline.tokenizer,
                language: language
            )
        } else {
            contextualOptions = nil
        }

        let results = try await pipeline.transcribe(
            audioArray: audio,
            decodeOptions: contextualOptions
                ?? (mode == .notes ? noteDecodingOptions : decodingOptions)
        )
        var segments = processedSegments(from: results)
        if automaticParagraphs && mode == .notes {
            segments = AudioPauseDetector.refining(
                segments,
                samples: audio,
                sampleRate: Double(WhisperKit.sampleRate)
            )
        }
        let originalText = sanitizedText(from: results)
        return LiveTranscription(
            text: vocabularyReplacer.applying(to: originalText),
            language: results.first?.language ?? language ?? "unknown",
            segments: segments,
            originalText: originalText
        )
    }

    /// Transcribe an AVFoundation-readable file without loading the whole
    /// recording into memory. Files are staged in bounded chunks and decoded
    /// sequentially through this actor's already-warmed model.
    func transcribeFile(
        at url: URL,
        mode: DictationMode,
        recognitionContext: String?
    ) async throws -> TimedTranscription {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let basePromptTerms = mode == .notes ? notePromptTerms + promptTerms : promptTerms
        let contextualOptions = recognitionContext.map {
            Self.decodingOptions(
                promptTerms: basePromptTerms,
                recognitionContext: $0,
                tokenizer: pipeline.tokenizer,
                language: language
            )
        }

        let results = try await pipeline.transcribe(
            audioPath: url.path,
            audioInputOptions: AudioInputOptions(
                audioLoadingMode: .incremental(
                    chunkDurationSeconds: 120,
                    maxBufferedChunks: 1
                )
            ),
            decodeOptions: contextualOptions
                ?? (mode == .notes ? noteDecodingOptions : decodingOptions)
        )
        var segments = processedSegments(from: results)
        if automaticParagraphs && mode == .notes {
            segments = (try? AudioPauseDetector.refining(segments, audioAt: url)) ?? segments
        }
        let originalText = sanitizedText(from: results)
        return TimedTranscription(
            text: vocabularyReplacer.applying(to: originalText),
            language: results.first?.language ?? "unknown",
            segments: segments,
            originalText: originalText
        )
    }

    private func processedSegments(
        from results: [TranscriptionResult]
    ) -> [TimedTranscriptSegment] {
        return results
            .flatMap(\.segments)
            .sorted {
                if $0.start == $1.start { return $0.end < $1.end }
                return $0.start < $1.start
            }
            .compactMap { segment -> TimedTranscriptSegment? in
                let text = vocabularyReplacer.applying(
                    to: TranscriptSanitizer.sanitize(segment.text)
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TimedTranscriptSegment(
                    startSeconds: max(0, Double(segment.start)),
                    endSeconds: max(Double(segment.start), Double(segment.end)),
                    text: text
                )
            }
    }

    private func sanitizedText(from results: [TranscriptionResult]) -> String {
        let raw = results.map(\.text).joined(separator: " ")
        return TranscriptSanitizer.sanitize(raw)
    }

    private func rebuildDecodingOptions(tokenizer: WhisperTokenizer?) {
        decodingOptions = Self.decodingOptions(
            promptTerms: promptTerms,
            tokenizer: tokenizer,
            language: language
        )
        noteDecodingOptions = notePromptTerms.isEmpty
            ? decodingOptions
            : Self.decodingOptions(
                promptTerms: notePromptTerms + promptTerms,
                tokenizer: tokenizer,
                language: language
            )
    }

    /// Prompt prefill improves recognition of names and jargon, but an
    /// unbounded vocabulary would trade away both latency and output context.
    /// Ninety-six tokens is enough for the newest couple dozen short terms and
    /// keeps the fast dictation path effectively constant-sized.
    static func decodingOptions(
        promptTerms: [String],
        recognitionContext: String? = nil,
        tokenizer: WhisperTokenizer?,
        language: String?
    ) -> DecodingOptions {
        var options = DecodingOptions(
            language: language,
            usePrefillPrompt: true,
            detectLanguage: language == nil
        )
        guard let tokenizer else { return options }

        let maximumPromptTokens = 96
        let maximumContextTokens = 32
        let persistentLimit = recognitionContext == nil
            ? maximumPromptTokens
            : maximumPromptTokens - maximumContextTokens
        var tokens: [Int] = []
        for term in promptTerms {
            let encoded = tokenizer.encode(text: " \(term).")
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            guard !encoded.isEmpty, tokens.count + encoded.count <= persistentLimit else {
                continue
            }
            tokens.append(contentsOf: encoded)
        }
        if let recognitionContext {
            let contextTokens = tokenizer.encode(text: " \(recognitionContext)")
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            tokens = mergingPromptTokens(
                persistent: tokens,
                context: contextTokens,
                maximumPromptTokens: maximumPromptTokens,
                maximumContextTokens: maximumContextTokens
            )
        }
        guard !tokens.isEmpty else { return options }

        options.promptTokens = tokens
        return options
    }

    /// Keep stable personalization first and the most recent task context at
    /// the suffix Whisper attends to most strongly. Exposed for budget tests
    /// without constructing a model tokenizer.
    nonisolated static func mergingPromptTokens(
        persistent: [Int],
        context: [Int],
        maximumPromptTokens: Int = 96,
        maximumContextTokens: Int = 32
    ) -> [Int] {
        let contextSuffix = Array(context.suffix(maximumContextTokens))
        // Keep personalization work constant whenever context is enabled;
        // unused context capacity is intentionally not reassigned.
        let persistentLimit = max(0, maximumPromptTokens - maximumContextTokens)
        return Array(persistent.prefix(persistentLimit)) + contextSuffix
    }
}

struct TimedTranscription: Codable, Equatable, Sendable {
    let originalText: String
    let text: String
    let language: String
    let segments: [TimedTranscriptSegment]

    init(
        text: String,
        language: String,
        segments: [TimedTranscriptSegment],
        originalText: String? = nil
    ) {
        self.originalText = originalText ?? text
        self.text = text
        self.language = language
        self.segments = segments
    }

    private enum CodingKeys: String, CodingKey {
        case text, language, segments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        originalText = text
        language = try container.decode(String.self, forKey: .language)
        segments = try container.decode([TimedTranscriptSegment].self, forKey: .segments)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(language, forKey: .language)
        try container.encode(segments, forKey: .segments)
    }
}

struct TimedTranscriptSegment: Codable, Equatable, Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let text: String
}

enum TranscriberError: LocalizedError {
    case missingEngineID
    case notLoaded
    case invalidAudio
    case unsupportedRealtime

    var errorDescription: String? {
        switch self {
        case .missingEngineID:
            "the selected model does not define an engine identifier"
        case .notLoaded:
            "the transcription model is not loaded"
        case .invalidAudio:
            "the captured audio is invalid"
        case .unsupportedRealtime:
            "the selected model does not support live transcription"
        }
    }
}

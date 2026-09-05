import Foundation
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private let vocabularyReplacer: VocabularyReplacer
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

    private let promptTerms: [String]
    private let notePromptTerms: [String]

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
        decodingOptions = Self.decodingOptions(
            promptTerms: promptTerms,
            tokenizer: loadedPipeline.tokenizer,
            language: language
        )
        noteDecodingOptions = notePromptTerms.isEmpty
            ? decodingOptions
            : Self.decodingOptions(
                promptTerms: notePromptTerms + promptTerms,
                tokenizer: loadedPipeline.tokenizer,
                language: language
            )
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    func transcribe(_ audio: [Float]) async throws -> LiveTranscription {
        try await transcribe(audio, mode: .dictation)
    }

    func transcribe(_ audio: [Float], mode: DictationMode) async throws -> LiveTranscription {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let results = try await pipeline.transcribe(
            audioArray: audio,
            decodeOptions: mode == .notes ? noteDecodingOptions : decodingOptions
        )
        var segments = processedSegments(from: results)
        if automaticParagraphs && mode == .notes {
            segments = AudioPauseDetector.refining(
                segments,
                samples: audio,
                sampleRate: Double(WhisperKit.sampleRate)
            )
        }
        return LiveTranscription(
            text: processedText(from: results),
            language: results.first?.language ?? language ?? "unknown",
            segments: segments
        )
    }

    /// Transcribe an AVFoundation-readable file without loading the whole
    /// recording into memory. Files are staged in bounded chunks and decoded
    /// sequentially through this actor's already-warmed model.
    func transcribeFile(
        at url: URL,
        mode: DictationMode
    ) async throws -> TimedTranscription {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let results = try await pipeline.transcribe(
            audioPath: url.path,
            audioInputOptions: AudioInputOptions(
                audioLoadingMode: .incremental(
                    chunkDurationSeconds: 120,
                    maxBufferedChunks: 1
                )
            ),
            decodeOptions: mode == .notes ? noteDecodingOptions : decodingOptions
        )
        var segments = processedSegments(from: results)
        if automaticParagraphs && mode == .notes {
            segments = (try? AudioPauseDetector.refining(segments, audioAt: url)) ?? segments
        }
        return TimedTranscription(
            text: processedText(from: results),
            language: results.first?.language ?? "unknown",
            segments: segments
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

    private func processedText(from results: [TranscriptionResult]) -> String {
        let raw = results.map(\.text).joined(separator: " ")
        return vocabularyReplacer.applying(to: TranscriptSanitizer.sanitize(raw))
    }

    /// Prompt prefill improves recognition of names and jargon, but an
    /// unbounded vocabulary would trade away both latency and output context.
    /// Ninety-six tokens is enough for the newest couple dozen short terms and
    /// keeps the fast dictation path effectively constant-sized.
    static func decodingOptions(
        promptTerms: [String],
        tokenizer: WhisperTokenizer?,
        language: String?
    ) -> DecodingOptions {
        var options = DecodingOptions(
            language: language,
            usePrefillPrompt: true,
            detectLanguage: language == nil
        )
        guard !promptTerms.isEmpty, let tokenizer else { return options }

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
        guard !tokens.isEmpty else { return options }

        options.promptTokens = tokens
        return options
    }
}

struct TimedTranscription: Codable, Equatable, Sendable {
    let text: String
    let language: String
    let segments: [TimedTranscriptSegment]
}

struct TimedTranscriptSegment: Codable, Equatable, Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let text: String
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
}

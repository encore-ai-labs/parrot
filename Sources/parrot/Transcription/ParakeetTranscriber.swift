import AVFoundation
import FluidAudio
import Foundation
import NaturalLanguage

/// Fast local Parakeet transcription through FluidAudio's Core ML runtimes.
/// Models are downloaded once into Parrot's own managed Application Support
/// directory and every inference call stays on-device.
actor ParakeetTranscriber: Transcriber {
    static let minimumSamples = ASRConstants.minimumRequiredSamples(
        forSampleRate: ASRConstants.sampleRate
    )

    let modelID: String

    enum Variant: Equatable {
        case compact
        case tdtV3
        case unified
        case unifiedStreaming

        init?(modelID: String) {
            switch modelID {
            case "parakeet-tdt-ctc-110m.en": self = .compact
            case "parakeet-tdt-0.6b-v3": self = .tdtV3
            case "parakeet-unified.en": self = .unified
            case "parakeet-unified-streaming.en": self = .unifiedStreaming
            default: return nil
            }
        }

        var folderName: String {
            switch self {
            case .compact: return Repo.parakeetTdtCtc110m.folderName
            case .tdtV3: return Repo.parakeetV3.folderName
            case .unified, .unifiedStreaming: return Repo.parakeetUnified.folderName
            }
        }

        var requiredArtifacts: [String] {
            switch self {
            case .compact:
                return [
                    "Preprocessor.mlmodelc",
                    "Decoder.mlmodelc",
                    "JointDecision.mlmodelc",
                    "parakeet_vocab.json",
                ]
            case .tdtV3:
                return [
                    "Preprocessor.mlmodelc",
                    "Encoder.mlmodelc",
                    "Decoder.mlmodelc",
                    "JointDecisionv3.mlmodelc",
                    "parakeet_vocab.json",
                ]
            case .unified:
                return [
                    "parakeet_unified_encoder_int8.mlmodelc",
                    "parakeet_unified_decoder.mlmodelc",
                    "parakeet_unified_joint_decision_single_step.mlmodelc",
                    "vocab.json",
                ]
            case .unifiedStreaming:
                return [
                    "parakeet_unified_encoder_streaming_70_7_1_int8.mlmodelc",
                    "parakeet_unified_decoder.mlmodelc",
                    "parakeet_unified_joint_decision_single_step.mlmodelc",
                    "vocab.json",
                ]
            }
        }

        var supplementalArtifacts: [(folder: String, artifact: String)] {
            switch self {
            case .compact:
                // FluidAudio currently loads this acoustic CTC head alongside
                // the compact TDT model for its hybrid decoding path.
                return [(Repo.parakeetCtc110m.folderName, "CtcHead.mlmodelc")]
            case .tdtV3, .unified, .unifiedStreaming:
                return []
            }
        }

        /// Large encoder artifacts owned exclusively by one Parrot model ID.
        /// Unified decoder/joint/vocabulary files are shared by batch and live
        /// variants and deliberately remain as a small reusable cache.
        var removableArtifacts: [String] {
            switch self {
            case .compact:
                return requiredArtifacts
            case .tdtV3:
                // FluidAudio also keeps the upstream config and legacy-named
                // vocabulary beside the five files used at runtime.
                return requiredArtifacts + ["config.json", "parakeet_v3_vocab.json"]
            case .unified:
                return ["parakeet_unified_encoder_int8.mlmodelc"]
            case .unifiedStreaming:
                return ["parakeet_unified_encoder_streaming_70_7_1_int8.mlmodelc"]
            }
        }
    }

    private enum Backend {
        case tdt(AsrManager)
        case unified(UnifiedAsrManager)
        case unifiedStreaming(StreamingUnifiedAsrManager)
    }

    private let variant: Variant
    nonisolated let supportsRealtime: Bool
    private let requestedLanguage: String
    private let automaticParagraphs: Bool
    private var vocabularyReplacer: VocabularyReplacer
    private var personalizationRevision: UInt64 = 0
    private let storage: ModelStorage
    private let downloadProgress: ModelDownloadProgress
    private var backend: Backend?

    init(
        model: TranscriptionModel,
        language: String = RecognitionLanguage.automatic,
        automaticParagraphs: Bool,
        vocabulary: PersonalVocabulary = PersonalVocabulary(),
        storage: ModelStorage = .default,
        downloadProgress: ModelDownloadProgress = ModelDownloadProgress()
    ) {
        modelID = model.id
        guard let variant = Variant(modelID: model.id) else {
            preconditionFailure("unknown Parakeet model: \(model.id)")
        }
        self.variant = variant
        supportsRealtime = variant == .unifiedStreaming
        requestedLanguage = RecognitionLanguage.canonicalize(language)
            ?? RecognitionLanguage.automatic
        self.automaticParagraphs = automaticParagraphs
        vocabularyReplacer = VocabularyReplacer(entries: vocabulary.entries)
        self.storage = storage
        self.downloadProgress = downloadProgress
    }

    func warmUp() async throws {
        if backend != nil { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: storage.managedBase,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: storage.managedBase.path
        )

        FileHandle.standardError.write(Data("loading \(modelID)...\n".utf8))
        do {
            let progressHandler: ProgressHandler?
            if Self.isDownloaded(variant: variant, storage: storage) {
                progressHandler = nil
            } else {
                progressHandler = { [downloadProgress] progress in
                    downloadProgress.update(fractionCompleted: progress.fractionCompleted)
                }
            }
            switch variant {
            case .compact:
                let target = storage.managedBase.appendingPathComponent(
                    variant.folderName,
                    isDirectory: true
                )
                let models = try await AsrModels.downloadAndLoad(
                    to: target,
                    version: .tdtCtc110m,
                    progressHandler: progressHandler
                )
                let loaded = AsrManager()
                try await loaded.loadModels(models)
                backend = .tdt(loaded)
            case .tdtV3:
                let target = storage.managedBase.appendingPathComponent(
                    variant.folderName,
                    isDirectory: true
                )
                let models = try await AsrModels.downloadAndLoad(
                    to: target,
                    version: .v3,
                    encoderPrecision: .int8,
                    progressHandler: progressHandler
                )
                // FluidAudio recommends the no-mel boundary path for v3
                // multilingual long-form audio to avoid English-prior drift.
                let loaded = AsrManager(config: ASRConfig(melChunkContext: false))
                try await loaded.loadModels(models)
                backend = .tdt(loaded)
            case .unified:
                let loaded = UnifiedAsrManager(encoderPrecision: .int8)
                try await loaded.loadModels(
                    to: storage.managedBase,
                    progressHandler: progressHandler
                )
                backend = .unified(loaded)
            case .unifiedStreaming:
                let loaded = StreamingUnifiedAsrManager(
                    config: UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 1),
                    encoderPrecision: .int8
                )
                try await loaded.loadModels(
                    to: storage.managedBase,
                    progressHandler: progressHandler
                )
                backend = .unifiedStreaming(loaded)
            }
        } catch {
            downloadProgress.finish()
            throw error
        }
        downloadProgress.finish()
        FileHandle.standardError.write(Data("✓ \(modelID) ready\n".utf8))
    }

    /// Parakeet does not accept prompt hints, but deterministic replacements
    /// can still become active without reloading its Core ML models.
    func updatePersonalization(_ personalization: TranscriberPersonalization) async {
        guard personalization.revision != personalizationRevision else { return }
        personalizationRevision = personalization.revision
        vocabularyReplacer = personalization.vocabularyReplacer
    }

    func transcribe(
        _ audio: [Float],
        mode: DictationMode,
        recognitionContext: String?
    ) async throws -> LiveTranscription {
        _ = recognitionContext // Parakeet has no acoustic prompt API.
        if backend == nil { try await warmUp() }
        guard let backend else { throw TranscriberError.notLoaded }
        let compatibleAudio = Self.paddingShortAudio(audio)
        let sourceDuration = Double(audio.count) / Double(ASRConstants.sampleRate)
        let wantsTimings = automaticParagraphs && mode == .notes
        switch backend {
        case .tdt(let manager):
            var state = TdtDecoderState.make(
                decoderLayers: variant == .compact ? 1 : 2
            )
            let result = try await manager.transcribe(
                compatibleAudio,
                decoderState: &state,
                language: Self.languageHint(requestedLanguage, variant: variant)
            )
            return liveTranscription(
                text: result.text,
                timings: wantsTimings ? result.tokenTimings ?? [] : [],
                sourceDuration: sourceDuration,
                language: Self.outputLanguage(
                    requested: requestedLanguage,
                    variant: variant,
                    transcript: result.text
                )
            )
        case .unified(let manager):
            if wantsTimings {
                // Unified already carries emission frames through decoding, so
                // asking for timings adds only their conversion to seconds.
                let result = try await manager.transcribeWithTimings(compatibleAudio)
                return liveTranscription(
                    text: result.text,
                    timings: result.tokenTimings,
                    sourceDuration: sourceDuration
                )
            }
            let originalText = sanitized(try await manager.transcribe(compatibleAudio))
            return LiveTranscription(
                text: vocabularyReplacer.applying(to: originalText),
                language: "en",
                originalText: originalText
            )
        case .unifiedStreaming(let manager):
            return try await transcribeStreaming(
                audio,
                manager: manager,
                mode: mode,
                sourceDuration: sourceDuration
            )
        }
    }

    func transcribeFile(
        at url: URL,
        mode: DictationMode,
        recognitionContext: String?
    ) async throws -> TimedTranscription {
        _ = recognitionContext // Parakeet has no acoustic prompt API.
        if backend == nil { try await warmUp() }
        guard let backend else { throw TranscriberError.notLoaded }

        let text: String
        let timings: [TokenTiming]
        let loadedDuration = try? await AVURLAsset(url: url).load(.duration).seconds
        let sourceDuration = loadedDuration.flatMap { duration in
            duration.isFinite ? max(0, duration) : nil
        }
        switch backend {
        case .tdt(let manager):
            // The TDT manager streams long files through a disk-backed
            // converter, keeping audio memory bounded independently of length.
            var state = TdtDecoderState.make(
                decoderLayers: variant == .compact ? 1 : 2
            )
            let result: ASRResult
            if let sourceDuration,
               sourceDuration < ASRConstants.minimumAudioDurationSeconds {
                let samples = try AudioConverter().resampleAudioFile(url)
                result = try await manager.transcribe(
                    Self.paddingShortAudio(samples),
                    decoderState: &state,
                    language: Self.languageHint(requestedLanguage, variant: variant)
                )
            } else {
                result = try await manager.transcribe(
                    url,
                    decoderState: &state,
                    language: Self.languageHint(requestedLanguage, variant: variant)
                )
            }
            text = result.text
            timings = result.tokenTimings ?? []
        case .unified(let manager):
            // Unified currently accepts samples, then performs its own bounded
            // overlapping 15-second inference windows.
            let originalSamples = try AudioConverter().resampleAudioFile(url)
            let samples = Self.paddingShortAudio(originalSamples)
            let result = try await manager.transcribeWithTimings(samples)
            text = result.text
            timings = result.tokenTimings
        case .unifiedStreaming(let manager):
            let samples = try AudioConverter().resampleAudioFile(url)
            let result = try await transcribeStreaming(
                samples,
                manager: manager,
                mode: mode,
                sourceDuration: sourceDuration ?? Double(samples.count) / Double(ASRConstants.sampleRate)
            )
            return TimedTranscription(
                text: result.text,
                language: result.language,
                segments: result.segments,
                originalText: result.originalText
            )
        }
        let originalText = sanitized(text)
        return TimedTranscription(
            text: vocabularyReplacer.applying(to: originalText),
            language: Self.outputLanguage(
                requested: requestedLanguage,
                variant: variant,
                transcript: originalText
            ),
            segments: Self.segments(
                from: buildWordTimings(from: timings).map {
                    TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
                },
                vocabularyReplacer: vocabularyReplacer,
                maximumDuration: sourceDuration
            ),
            originalText: originalText
        )
    }

    nonisolated static func paddingShortAudio(_ samples: [Float]) -> [Float] {
        guard samples.count < minimumSamples else { return samples }
        return samples + repeatElement(0, count: minimumSamples - samples.count)
    }

    nonisolated static func languageHint(
        _ requested: String,
        variant: Variant
    ) -> Language? {
        guard variant == .tdtV3, requested != RecognitionLanguage.automatic else {
            return nil
        }
        return Language(rawValue: requested)
    }

    /// FluidAudio's v3 API auto-detects but does not return a language code.
    /// Resolve metadata locally from the final transcript so cleanup and
    /// history never falsely claim English. A pinned language stays exact.
    nonisolated static func outputLanguage(
        requested: String,
        variant: Variant,
        transcript: String
    ) -> String {
        guard variant == .tdtV3 else { return "en" }
        if requested != RecognitionLanguage.automatic { return requested }
        guard let detected = NLLanguageRecognizer.dominantLanguage(for: transcript)?.rawValue,
              RecognitionLanguage.parakeetV3Codes.contains(detected)
        else { return "und" }
        return detected
    }

    nonisolated static func isDownloaded(
        model: TranscriptionModel,
        storage: ModelStorage = .default
    ) -> Bool {
        guard let variant = Variant(modelID: model.id) else { return false }
        return isDownloaded(variant: variant, storage: storage)
    }

    nonisolated static func managedRemovalTargets(
        model: TranscriptionModel,
        storage: ModelStorage
    ) -> [URL] {
        guard let variant = Variant(modelID: model.id) else { return [] }
        let folder = storage.managedBase.appendingPathComponent(
            variant.folderName,
            isDirectory: true
        )
        let primary = variant.removableArtifacts.map { folder.appendingPathComponent($0) }
        let supplemental = variant.supplementalArtifacts.map { item in
            storage.managedBase
                .appendingPathComponent(item.folder, isDirectory: true)
                .appendingPathComponent(item.artifact)
        }
        return primary + supplemental
    }

    private nonisolated static func isDownloaded(
        variant: Variant,
        storage: ModelStorage
    ) -> Bool {
        let directory = storage.managedBase.appendingPathComponent(
            variant.folderName,
            isDirectory: true
        )
        let baseIsComplete = variant.requiredArtifacts.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        return baseIsComplete && variant.supplementalArtifacts.allSatisfy { item in
            let path = storage.managedBase
                .appendingPathComponent(item.folder, isDirectory: true)
                .appendingPathComponent(item.artifact)
                .path
            return FileManager.default.fileExists(atPath: path)
        }
    }

    /// Group word timings into useful sentence/pause-sized timeline rows
    /// instead of emitting one Markdown row per subword token.
    nonisolated static func segments(
        from words: [TimedWord],
        vocabularyReplacer: VocabularyReplacer,
        maximumDuration: TimeInterval? = nil
    ) -> [TimedTranscriptSegment] {
        TimedSegmentBuilder.segments(
            from: words,
            vocabularyReplacer: vocabularyReplacer,
            maximumDuration: maximumDuration
        )
    }

    private func processed(_ raw: String) -> String {
        vocabularyReplacer.applying(to: sanitized(raw))
    }

    private func sanitized(_ raw: String) -> String {
        TranscriptSanitizer.sanitize(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func liveTranscription(
        text: String,
        timings: [TokenTiming],
        sourceDuration: TimeInterval,
        language: String = "en"
    ) -> LiveTranscription {
        let segments = Self.segments(
            from: buildWordTimings(from: timings).map {
                TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
            },
            vocabularyReplacer: vocabularyReplacer,
            maximumDuration: sourceDuration
        )
        let originalText = sanitized(text)
        return LiveTranscription(
            text: vocabularyReplacer.applying(to: originalText),
            language: language,
            segments: segments,
            originalText: originalText
        )
    }

    private func transcribeStreaming(
        _ audio: [Float],
        manager: StreamingUnifiedAsrManager,
        mode: DictationMode,
        sourceDuration: TimeInterval
    ) async throws -> LiveTranscription {
        try await manager.reset()
        await manager.setPartialTranscriptCallback { _ in }
        do {
            if !audio.isEmpty {
                try await manager.appendAudio(Self.audioBuffer(for: audio))
            }
            let text = try await manager.finish()
            let timings = await manager.consumeTokenTimings()
            let result = liveTranscription(
                text: text,
                timings: automaticParagraphs && mode == .notes ? timings : [],
                sourceDuration: sourceDuration
            )
            await manager.setPartialTranscriptCallback { _ in }
            try await manager.reset()
            return result
        } catch {
            await manager.setPartialTranscriptCallback { _ in }
            try? await manager.reset()
            throw error
        }
    }

    nonisolated private static func audioBuffer(for audio: [Float]) throws -> AVAudioPCMBuffer {
        guard audio.count <= Int(UInt32.max),
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(ASRConstants.sampleRate),
                channels: 1,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(audio.count)
              ),
              let channel = buffer.floatChannelData?[0]
        else { throw TranscriberError.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(audio.count)
        audio.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channel.update(from: baseAddress, count: audio.count)
        }
        return buffer
    }
}

extension ParakeetTranscriber: RealtimeTranscriber {
    func beginRealtime(
        partial: @escaping @Sendable (String) -> Void
    ) async throws {
        if backend == nil { try await warmUp() }
        guard case .unifiedStreaming(let manager) = backend else {
            throw TranscriberError.unsupportedRealtime
        }
        let replacer = vocabularyReplacer
        try await manager.reset()
        await manager.setPartialTranscriptCallback { raw in
            let original = TranscriptSanitizer.sanitize(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            partial(replacer.applying(to: original))
        }
    }

    func appendRealtime(_ audio: [Float]) async throws {
        guard case .unifiedStreaming(let manager) = backend else {
            throw TranscriberError.unsupportedRealtime
        }
        guard !audio.isEmpty else { return }
        try await manager.appendAudio(Self.audioBuffer(for: audio))
        try await manager.processBufferedAudio()
    }

    func finishRealtime(
        mode: DictationMode,
        sourceDuration: TimeInterval
    ) async throws -> LiveTranscription {
        guard case .unifiedStreaming(let manager) = backend else {
            throw TranscriberError.unsupportedRealtime
        }
        do {
            let text = try await manager.finish()
            let timings = await manager.consumeTokenTimings()
            let result = liveTranscription(
                text: text,
                timings: automaticParagraphs && mode == .notes ? timings : [],
                sourceDuration: sourceDuration
            )
            await manager.setPartialTranscriptCallback { _ in }
            try await manager.reset()
            return result
        } catch {
            await manager.setPartialTranscriptCallback { _ in }
            try? await manager.reset()
            throw error
        }
    }

    func cancelRealtime() async {
        guard case .unifiedStreaming(let manager) = backend else { return }
        await manager.setPartialTranscriptCallback { _ in }
        try? await manager.reset()
    }
}

struct TimedWord: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

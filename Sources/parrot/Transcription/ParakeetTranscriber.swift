import AVFoundation
import FluidAudio
import Foundation

/// Punctuation-aware English transcription through Parakeet Unified's INT8
/// Core ML encoder. The model is downloaded once into Parrot's own managed
/// Application Support directory and every inference call stays on-device.
actor ParakeetTranscriber: Transcriber {
    static let minimumSamples = ASRConstants.minimumRequiredSamples(
        forSampleRate: ASRConstants.sampleRate
    )

    let modelID: String

    enum Variant {
        case compact
        case unified

        init?(modelID: String) {
            switch modelID {
            case "parakeet-tdt-ctc-110m.en": self = .compact
            case "parakeet-unified.en": self = .unified
            default: return nil
            }
        }

        var folderName: String {
            switch self {
            case .compact: return Repo.parakeetTdtCtc110m.folderName
            case .unified: return Repo.parakeetUnified.folderName
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
            case .unified:
                return [
                    "parakeet_unified_encoder_int8.mlmodelc",
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
            case .unified:
                return []
            }
        }
    }

    private enum Backend {
        case compact(AsrManager)
        case unified(UnifiedAsrManager)
    }

    private let variant: Variant
    private let vocabularyReplacer: VocabularyReplacer
    private let storage: ModelStorage
    private let downloadProgress: ModelDownloadProgress
    private var backend: Backend?

    init(
        model: TranscriptionModel,
        vocabulary: PersonalVocabulary = PersonalVocabulary(),
        storage: ModelStorage = .default,
        downloadProgress: ModelDownloadProgress = ModelDownloadProgress()
    ) {
        modelID = model.id
        guard let variant = Variant(modelID: model.id) else {
            preconditionFailure("unknown Parakeet model: \(model.id)")
        }
        self.variant = variant
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
                backend = .compact(loaded)
            case .unified:
                let loaded = UnifiedAsrManager(encoderPrecision: .int8)
                try await loaded.loadModels(
                    to: storage.managedBase,
                    progressHandler: progressHandler
                )
                backend = .unified(loaded)
            }
        } catch {
            downloadProgress.finish()
            throw error
        }
        downloadProgress.finish()
        FileHandle.standardError.write(Data("✓ \(modelID) ready\n".utf8))
    }

    func transcribe(_ audio: [Float], mode: DictationMode) async throws -> LiveTranscription {
        _ = mode // formatting is deterministic and shared after recognition
        if backend == nil { try await warmUp() }
        guard let backend else { throw TranscriberError.notLoaded }
        let compatibleAudio = Self.paddingShortAudio(audio)
        switch backend {
        case .compact(let manager):
            var state = TdtDecoderState.make(decoderLayers: 1)
            return LiveTranscription(text: processed(try await manager.transcribe(
                compatibleAudio,
                decoderState: &state
            ).text), language: "en")
        case .unified(let manager):
            return LiveTranscription(
                text: processed(try await manager.transcribe(compatibleAudio)),
                language: "en"
            )
        }
    }

    func transcribeFile(at url: URL, mode: DictationMode) async throws -> TimedTranscription {
        _ = mode
        if backend == nil { try await warmUp() }
        guard let backend else { throw TranscriberError.notLoaded }

        let text: String
        let timings: [TokenTiming]
        let loadedDuration = try? await AVURLAsset(url: url).load(.duration).seconds
        let sourceDuration = loadedDuration.flatMap { duration in
            duration.isFinite ? max(0, duration) : nil
        }
        switch backend {
        case .compact(let manager):
            // The compact manager streams long files through a disk-backed
            // converter, keeping audio memory bounded independently of length.
            var state = TdtDecoderState.make(decoderLayers: 1)
            let result: ASRResult
            if let sourceDuration,
               sourceDuration < ASRConstants.minimumAudioDurationSeconds {
                let samples = try AudioConverter().resampleAudioFile(url)
                result = try await manager.transcribe(
                    Self.paddingShortAudio(samples),
                    decoderState: &state
                )
            } else {
                result = try await manager.transcribe(url, decoderState: &state)
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
        }
        return TimedTranscription(
            text: processed(text),
            language: "en",
            segments: Self.segments(
                from: buildWordTimings(from: timings).map {
                    TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
                },
                vocabularyReplacer: vocabularyReplacer,
                maximumDuration: sourceDuration
            )
        )
    }

    nonisolated static func paddingShortAudio(_ samples: [Float]) -> [Float] {
        guard samples.count < minimumSamples else { return samples }
        return samples + repeatElement(0, count: minimumSamples - samples.count)
    }

    nonisolated static func isDownloaded(
        model: TranscriptionModel,
        storage: ModelStorage = .default
    ) -> Bool {
        guard let variant = Variant(modelID: model.id) else { return false }
        return isDownloaded(variant: variant, storage: storage)
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
        guard !words.isEmpty else { return [] }
        var output: [TimedTranscriptSegment] = []
        var group: [TimedWord] = []

        func flush() {
            guard let first = group.first, let last = group.last else { return }
            var text = group.map(\.text).joined(separator: " ")
            text = text.replacingOccurrences(
                of: #"\s+([,.;:!?])"#,
                with: "$1",
                options: .regularExpression
            )
            text = vocabularyReplacer.applying(to: TranscriptSanitizer.sanitize(text))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let start = min(max(0, first.start), maximumDuration ?? .infinity)
                let end = min(max(start, last.end), maximumDuration ?? .infinity)
                output.append(TimedTranscriptSegment(
                    startSeconds: start,
                    endSeconds: end,
                    text: text
                ))
            }
            group.removeAll(keepingCapacity: true)
        }

        for (index, word) in words.enumerated() {
            group.append(word)
            let nextGap = index + 1 < words.count
                ? words[index + 1].start - word.end
                : .infinity
            let sentenceEnded = word.text.last.map { ".!?".contains($0) } ?? false
            if sentenceEnded || nextGap >= 0.8 || group.count >= 28 {
                flush()
            }
        }
        flush()
        return output
    }

    private func processed(_ raw: String) -> String {
        vocabularyReplacer.applying(to: TranscriptSanitizer.sanitize(raw))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TimedWord: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

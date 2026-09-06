import XCTest

@testable import parrot

final class ParakeetTranscriberTests: XCTestCase {
    func testRegistryExposesFastLocalEngineWithoutChangingDefault() throws {
        let model = try XCTUnwrap(ModelRegistry.find("parakeet-unified.en"))

        XCTAssertEqual(model.engine, .parakeet)
        XCTAssertEqual(model.languages, ["en"])
        XCTAssertEqual(model.sizeMB, 614)
        XCTAssertFalse(model.recommended)
        XCTAssertEqual(ModelRegistry.recommended()?.id, "whisper-base.en")
        XCTAssertTrue(TranscriberFactory.make(model: model) is ParakeetTranscriber)

        let compact = try XCTUnwrap(ModelRegistry.find("parakeet-tdt-ctc-110m.en"))
        XCTAssertEqual(compact.engine, .parakeet)
        XCTAssertEqual(compact.sizeMB, 331)
        XCTAssertTrue(TranscriberFactory.make(model: compact) is ParakeetTranscriber)

        let streaming = try XCTUnwrap(
            ModelRegistry.find("parakeet-unified-streaming.en")
        )
        XCTAssertEqual(streaming.engine, .parakeet)
        XCTAssertEqual(streaming.languages, ["en"])
        XCTAssertEqual(streaming.sizeMB, 614)
        let realtime = try XCTUnwrap(
            TranscriberFactory.make(model: streaming) as? any RealtimeTranscriber
        )
        XCTAssertTrue(realtime.supportsRealtime)
    }

    func testDownloadedStateRequiresEveryRuntimeArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-parakeet-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ModelStorage(
            managedBase: root.appendingPathComponent("managed"),
            legacyBase: root.appendingPathComponent("legacy")
        )
        let model = try XCTUnwrap(ModelRegistry.find("parakeet-unified.en"))
        let variant = try XCTUnwrap(ParakeetTranscriber.Variant(modelID: model.id))
        let folder = storage.managedBase.appendingPathComponent(
            variant.folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertFalse(ParakeetTranscriber.isDownloaded(model: model, storage: storage))
        for artifact in variant.requiredArtifacts {
            let url = folder.appendingPathComponent(artifact)
            if artifact.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
            }
        }
        for supplemental in variant.supplementalArtifacts {
            try FileManager.default.createDirectory(
                at: storage.managedBase
                    .appendingPathComponent(supplemental.folder, isDirectory: true)
                    .appendingPathComponent(supplemental.artifact, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        XCTAssertTrue(ParakeetTranscriber.isDownloaded(model: model, storage: storage))

        try FileManager.default.removeItem(
            at: folder.appendingPathComponent(variant.requiredArtifacts[0])
        )
        XCTAssertFalse(ParakeetTranscriber.isDownloaded(model: model, storage: storage))
    }

    func testCompactDownloadedStateRequiresSupplementalCTCHead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-parakeet-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ModelStorage(
            managedBase: root.appendingPathComponent("managed"),
            legacyBase: root.appendingPathComponent("legacy")
        )
        let model = try XCTUnwrap(ModelRegistry.find("parakeet-tdt-ctc-110m.en"))
        let variant = try XCTUnwrap(ParakeetTranscriber.Variant(modelID: model.id))
        let folder = storage.managedBase.appendingPathComponent(
            variant.folderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for artifact in variant.requiredArtifacts {
            let url = folder.appendingPathComponent(artifact)
            if artifact.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
            }
        }

        XCTAssertFalse(ParakeetTranscriber.isDownloaded(model: model, storage: storage))
        let supplemental = try XCTUnwrap(variant.supplementalArtifacts.first)
        try FileManager.default.createDirectory(
            at: storage.managedBase
                .appendingPathComponent(supplemental.folder, isDirectory: true)
                .appendingPathComponent(supplemental.artifact, isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(ParakeetTranscriber.isDownloaded(model: model, storage: storage))
    }

    func testShortAudioIsPaddedToBackendMinimum() {
        let short = [Float](repeating: 0.25, count: 4_000)
        let padded = ParakeetTranscriber.paddingShortAudio(short)

        XCTAssertEqual(padded.count, ParakeetTranscriber.minimumSamples)
        XCTAssertEqual(Array(padded.prefix(short.count)), short)
        XCTAssertTrue(padded.dropFirst(short.count).allSatisfy { $0 == 0 })

        let long = [Float](repeating: 0.25, count: ParakeetTranscriber.minimumSamples + 1)
        XCTAssertEqual(ParakeetTranscriber.paddingShortAudio(long), long)
    }

    func testTimelineGroupsOnSentencePauseAndWordLimit() {
        let words = [
            TimedWord(text: "Project", start: 0.10, end: 0.30),
            TimedWord(text: "alpha.", start: 0.31, end: 0.55),
            TimedWord(text: "Next", start: 1.60, end: 1.80),
            TimedWord(text: "task", start: 1.81, end: 2.00),
        ]

        let segments = ParakeetTranscriber.segments(
            from: words,
            vocabularyReplacer: VocabularyReplacer(entries: [])
        )

        XCTAssertEqual(segments, [
            TimedTranscriptSegment(startSeconds: 0.10, endSeconds: 0.55, text: "Project alpha."),
            TimedTranscriptSegment(startSeconds: 1.60, endSeconds: 2.00, text: "Next task"),
        ])
    }

    func testTimelineNeverExtendsPastPaddedSourceDuration() {
        let segments = ParakeetTranscriber.segments(
            from: [TimedWord(text: "Yes.", start: 0, end: 0.24)],
            vocabularyReplacer: VocabularyReplacer(entries: []),
            maximumDuration: 0.124
        )

        XCTAssertEqual(segments, [
            TimedTranscriptSegment(startSeconds: 0, endSeconds: 0.124, text: "Yes."),
        ])
    }

    func testTimelineAppliesPrivateVocabularyReplacement() throws {
        var vocabulary = PersonalVocabulary()
        try vocabulary.set(spoken: "rust pond", written: "RustPond")

        let segments = ParakeetTranscriber.segments(
            from: [
                TimedWord(text: "rust", start: 0, end: 0.2),
                TimedWord(text: "pond", start: 0.2, end: 0.4),
            ],
            vocabularyReplacer: VocabularyReplacer(entries: vocabulary.entries)
        )

        XCTAssertEqual(segments.map(\.text), ["RustPond"])
    }
}

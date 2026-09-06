import Foundation
import XCTest

@testable import parrot

final class ModelStorageTests: XCTestCase {
    func testReusesCompleteLegacyModelWithoutRedownload() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = makeStorage(root)
        let variant = "openai_whisper-base.en"
        try createCompleteModel(at: storage.modelFolder(base: storage.legacyBase, variant: variant))

        let resolved = try XCTUnwrap(storage.existingModel(variant: variant))
        XCTAssertEqual(resolved.source, .legacyDocuments)
        XCTAssertEqual(resolved.downloadBase, storage.managedBase)
        XCTAssertEqual(resolved.tokenizerFolder, storage.legacyBase)
    }

    func testManagedModelTakesPriorityOverLegacyCopy() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = makeStorage(root)
        let variant = "openai_whisper-base.en"
        try createCompleteModel(at: storage.modelFolder(base: storage.legacyBase, variant: variant))
        let managed = storage.modelFolder(base: storage.managedBase, variant: variant)
        try createCompleteModel(at: managed)

        let resolved = try XCTUnwrap(storage.existingModel(variant: variant))
        XCTAssertEqual(resolved.source, .managed)
        XCTAssertEqual(resolved.modelFolder, managed)
        XCTAssertEqual(resolved.tokenizerFolder, storage.managedBase)
    }

    func testIncompleteLegacyModelIsIgnored() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = makeStorage(root)
        let variant = "openai_whisper-base.en"
        let incomplete = storage.modelFolder(base: storage.legacyBase, variant: variant)
        try FileManager.default.createDirectory(
            at: incomplete.appendingPathComponent("AudioEncoder.mlmodelc"),
            withIntermediateDirectories: true
        )

        XCTAssertNil(storage.existingModel(variant: variant))
    }

    func testMigrationMovesKnownModelAndLeavesCompatibilityLink() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = makeStorage(root)
        let model = try XCTUnwrap(ModelRegistry.find("whisper-base.en"))
        let variant = try XCTUnwrap(model.whisperKitID)
        let legacy = storage.modelFolder(base: storage.legacyBase, variant: variant)
        let managed = storage.modelFolder(base: storage.managedBase, variant: variant)
        try createCompleteModel(at: legacy)

        let results = try storage.migrateKnownModels([model])

        XCTAssertEqual(results, [ModelMigrationResult(modelID: model.id, outcome: .moved)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: legacy.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(storage.existingModel(variant: variant)?.source, .managed)
        XCTAssertEqual(storage.existingModel(variant: variant)?.tokenizerFolder, storage.legacyBase)
        let permissions = try FileManager.default.attributesOfItem(
            atPath: storage.managedBase.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
    }

    func testMigrationNeverOverwritesManagedDestination() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = makeStorage(root)
        let model = try XCTUnwrap(ModelRegistry.find("whisper-base.en"))
        let variant = try XCTUnwrap(model.whisperKitID)
        let legacy = storage.modelFolder(base: storage.legacyBase, variant: variant)
        let managed = storage.modelFolder(base: storage.managedBase, variant: variant)
        try createCompleteModel(at: legacy)
        try createCompleteModel(at: managed)

        let results = try storage.migrateKnownModels([model])

        XCTAssertEqual(
            results,
            [ModelMigrationResult(modelID: model.id, outcome: .destinationExists)]
        )
        XCTAssertFalse(isSymbolicLink(legacy))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path))
    }

    func testNonInteractiveProgressIsRateLimited() {
        let messages = MessageBox()
        let reporter = ModelDownloadProgress(interactive: false) { message in
            messages.append(message)
        }
        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 1
        reporter.update(progress)
        progress.completedUnitCount = 5
        reporter.update(progress)
        progress.completedUnitCount = 20
        reporter.update(progress)
        progress.completedUnitCount = 100
        reporter.update(progress)
        reporter.update(fractionCompleted: 1)
        reporter.finish()

        XCTAssertEqual(messages.values, [
            "downloading model… 1%\n",
            "downloading model… 20%\n",
            "downloading model… 100%\n",
        ])
    }

    func testInteractiveProgressRepaintsAndCanBeReused() {
        let messages = MessageBox()
        let reporter = ModelDownloadProgress(interactive: true) { message in
            messages.append(message)
        }
        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 2
        reporter.update(progress)
        progress.completedUnitCount = 2
        reporter.update(progress)
        reporter.finish()
        progress.completedUnitCount = 1
        reporter.update(progress)
        reporter.finish()

        XCTAssertEqual(messages.values, [
            "\rdownloading model… 2%",
            "\n",
            "\rdownloading model… 1%",
            "\n",
        ])
    }

    func testModelStorageCommandsParse() throws {
        XCTAssertNotNil(try Models.Path.parseAsRoot([]) as? Models.Path)
        XCTAssertNotNil(try Models.Migrate.parseAsRoot([]) as? Models.Migrate)
        let remove = try XCTUnwrap(
            try Models.Remove.parseAsRoot(["parakeet-unified.en"]) as? Models.Remove
        )
        XCTAssertEqual(remove.id, "parakeet-unified.en")
        XCTAssertFalse(remove.force)
    }

    func testRemovingManagedWhisperLeavesOtherModelsAndLegacyUntouched() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = makeStorage(root)
        let removed = try XCTUnwrap(ModelRegistry.find("whisper-base.en"))
        let kept = try XCTUnwrap(ModelRegistry.find("whisper-small.en"))
        let removedVariant = try XCTUnwrap(removed.whisperKitID)
        let keptVariant = try XCTUnwrap(kept.whisperKitID)
        let removedPath = storage.modelFolder(base: storage.managedBase, variant: removedVariant)
        let keptPath = storage.modelFolder(base: storage.managedBase, variant: keptVariant)
        let legacyPath = storage.modelFolder(base: storage.legacyBase, variant: removedVariant)
        try createCompleteModel(at: removedPath)
        try createCompleteModel(at: keptPath)
        try createCompleteModel(at: legacyPath)

        XCTAssertTrue(try storage.hasManagedArtifacts(for: removed))

        let result = try XCTUnwrap(storage.removeManagedModel(removed))

        XCTAssertEqual(result.removedPaths, [removedPath])
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPath.path))
        XCTAssertFalse(try storage.hasManagedArtifacts(for: removed))
    }

    func testRemovingOneUnifiedVariantPreservesSharedAndOtherEncoder() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = makeStorage(root)
        let batch = try XCTUnwrap(ModelRegistry.find("parakeet-unified.en"))
        let live = try XCTUnwrap(ModelRegistry.find("parakeet-unified-streaming.en"))
        let folder = storage.managedBase.appendingPathComponent(
            "parakeet-unified-en-0.6b",
            isDirectory: true
        )
        for artifact in [
            "parakeet_unified_encoder_int8.mlmodelc",
            "parakeet_unified_encoder_streaming_70_7_1_int8.mlmodelc",
            "parakeet_unified_decoder.mlmodelc",
            "parakeet_unified_joint_decision_single_step.mlmodelc",
        ] {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(artifact),
                withIntermediateDirectories: true
            )
        }
        XCTAssertTrue(FileManager.default.createFile(
            atPath: folder.appendingPathComponent("vocab.json").path,
            contents: Data("vocab".utf8)
        ))

        _ = try storage.removeManagedModel(batch)

        XCTAssertFalse(ParakeetTranscriber.isDownloaded(model: batch, storage: storage))
        XCTAssertTrue(ParakeetTranscriber.isDownloaded(model: live, storage: storage))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("parakeet_unified_decoder.mlmodelc").path
        ))

        _ = try storage.removeManagedModel(live)

        XCTAssertFalse(ParakeetTranscriber.isDownloaded(model: live, storage: storage))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("parakeet_unified_decoder.mlmodelc").path
        ))
    }

    func testRemovalRejectsEscapingManagedRoot() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = makeStorage(root)
        let outside = root.appendingPathComponent("outside")
        try createCompleteModel(at: outside)
        let malicious = TranscriptionModel(
            id: "unsafe",
            displayName: "Unsafe",
            engine: .whisperKit,
            whisperKitID: "../../../../../../outside",
            sizeMB: 1,
            languages: ["en"],
            recommended: false
        )

        XCTAssertThrowsError(try storage.removeManagedModel(malicious)) { error in
            XCTAssertTrue(error is ModelStorageError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testRemovalRejectsSymlinkedParentEscapingManagedRoot() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = makeStorage(root)
        let model = try XCTUnwrap(ModelRegistry.find("whisper-base.en"))
        let outside = root.appendingPathComponent("outside")
        try createCompleteModel(at: outside.appendingPathComponent("openai_whisper-base.en"))
        let parent = storage.managedBase
            .appendingPathComponent("models/argmaxinc", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: parent.appendingPathComponent("whisperkit-coreml"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try storage.removeManagedModel(model)) { error in
            XCTAssertTrue(error is ModelStorageError)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("openai_whisper-base.en").path
        ))
    }

    private func makeStorage(_ root: URL) -> ModelStorage {
        ModelStorage(
            managedBase: root.appendingPathComponent("Application Support/Parrot/models"),
            legacyBase: root.appendingPathComponent("Documents/huggingface")
        )
    }

    private func createCompleteModel(at url: URL) throws {
        for component in ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(component),
                withIntermediateDirectories: true
            )
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-model-storage-tests-\(UUID().uuidString)")
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }
}

private final class MessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

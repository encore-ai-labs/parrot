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

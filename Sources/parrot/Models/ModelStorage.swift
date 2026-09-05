import Foundation
import WhisperKit

enum ModelStorageSource: String, Equatable {
    case managed
    case legacyDocuments
}

struct ResolvedModelStorage: Equatable {
    let modelFolder: URL
    let downloadBase: URL
    let tokenizerFolder: URL
    let source: ModelStorageSource
}

struct ModelMigrationResult: Equatable {
    enum Outcome: Equatable {
        case moved
        case alreadyMigrated
        case destinationExists
    }

    let modelID: String
    let outcome: Outcome
}

struct ModelStorage {
    static var `default`: ModelStorage {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let managedBase: URL
        if let override = ProcessInfo.processInfo.environment["PARROT_MODELS_DIRECTORY"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            managedBase = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        } else {
            managedBase = home.appendingPathComponent(
                "Library/Application Support/Parrot/models", isDirectory: true
            )
        }
        return ModelStorage(
            managedBase: managedBase,
            legacyBase: home.appendingPathComponent("Documents/huggingface", isDirectory: true)
        )
    }

    let managedBase: URL
    let legacyBase: URL
    private let fileManager: FileManager

    init(
        managedBase: URL,
        legacyBase: URL,
        fileManager: FileManager = .default
    ) {
        self.managedBase = managedBase
        self.legacyBase = legacyBase
        self.fileManager = fileManager
    }

    func existingModel(variant: String) -> ResolvedModelStorage? {
        let managed = modelFolder(base: managedBase, variant: variant)
        if isCompleteModel(at: managed) {
            let migratedLink = modelFolder(base: legacyBase, variant: variant)
            let tokenizerBase = isSymbolicLink(at: migratedLink) ? legacyBase : managedBase
            return ResolvedModelStorage(
                modelFolder: managed,
                downloadBase: managedBase,
                tokenizerFolder: tokenizerBase,
                source: .managed
            )
        }

        let legacy = modelFolder(base: legacyBase, variant: variant)
        guard isCompleteModel(at: legacy) else { return nil }
        return ResolvedModelStorage(
            modelFolder: legacy,
            downloadBase: managedBase,
            tokenizerFolder: legacyBase,
            source: .legacyDocuments
        )
    }

    func resolve(
        variant: String,
        progressCallback: ProgressCallback? = nil
    ) async throws -> ResolvedModelStorage {
        if let existing = existingModel(variant: variant) { return existing }
        try prepareManagedDirectory()
        let folder = try await WhisperKit.download(
            variant: variant,
            downloadBase: managedBase,
            progressCallback: progressCallback
        )
        return ResolvedModelStorage(
            modelFolder: folder,
            downloadBase: managedBase,
            tokenizerFolder: managedBase,
            source: .managed
        )
    }

    func migrateKnownModels(_ models: [TranscriptionModel]) throws -> [ModelMigrationResult] {
        try prepareManagedDirectory()
        var results: [ModelMigrationResult] = []
        for model in models {
            guard let variant = model.whisperKitID else { continue }
            let source = modelFolder(base: legacyBase, variant: variant)
            let destination = modelFolder(base: managedBase, variant: variant)

            if isSymbolicLink(at: source), isCompleteModel(at: destination) {
                results.append(ModelMigrationResult(modelID: model.id, outcome: .alreadyMigrated))
                continue
            }
            guard isCompleteModel(at: source) else { continue }
            guard !fileManager.fileExists(atPath: destination.path) else {
                results.append(ModelMigrationResult(modelID: model.id, outcome: .destinationExists))
                continue
            }

            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: source, to: destination)
            do {
                try fileManager.createSymbolicLink(
                    at: source,
                    withDestinationURL: destination
                )
            } catch {
                // The model is already safe and usable at the destination. A
                // compatibility link is helpful to other tools, but failure to
                // create it must never roll back or delete the moved model.
                let warning = "warning: moved \(model.id), but couldn't create legacy "
                    + "compatibility link: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(warning.utf8))
            }
            results.append(ModelMigrationResult(modelID: model.id, outcome: .moved))
        }
        return results
    }

    func modelFolder(base: URL, variant: String) -> URL {
        base
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    private func prepareManagedDirectory() throws {
        try fileManager.createDirectory(
            at: managedBase,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: managedBase.path
        )
    }

    private func isCompleteModel(at url: URL) -> Bool {
        ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"]
            .allSatisfy {
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(
                    atPath: url.appendingPathComponent($0).path,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue
            }
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else { return false }
        return type == .typeSymbolicLink
    }
}

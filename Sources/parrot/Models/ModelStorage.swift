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

struct ModelRemovalResult: Equatable {
    let removedPaths: [URL]
    let reclaimedBytes: Int64
}

enum ModelStorageError: LocalizedError {
    case unsafeRemovalTarget(URL)

    var errorDescription: String? {
        switch self {
        case .unsafeRemovalTarget(let url):
            return "refusing to remove model path outside managed storage: \(url.path)"
        }
    }
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

    /// Removes only artifacts under Parrot's managed model root. Legacy
    /// Documents caches may be shared with other tools and are never deleted.
    func hasManagedArtifacts(for model: TranscriptionModel) throws -> Bool {
        try validatedRemovalCandidates(for: model).contains { itemExists(at: $0) }
    }

    func removeManagedModel(_ model: TranscriptionModel) throws -> ModelRemovalResult? {
        let candidates = try validatedRemovalCandidates(for: model)
        let existing = candidates.filter { itemExists(at: $0) }
        guard !existing.isEmpty else { return nil }

        let bytes = existing.reduce(Int64(0)) { $0 + logicalSize(of: $1) }
        for url in existing {
            try fileManager.removeItem(at: url)
        }
        return ModelRemovalResult(removedPaths: existing, reclaimedBytes: bytes)
    }

    private func validatedRemovalCandidates(
        for model: TranscriptionModel
    ) throws -> [URL] {
        let candidates: [URL]
        switch model.engine {
        case .whisperKit:
            guard let variant = model.whisperKitID else { return [] }
            candidates = [modelFolder(base: managedBase, variant: variant)]
        case .parakeet:
            candidates = ParakeetTranscriber.managedRemovalTargets(
                model: model,
                storage: self
            )
        }

        for url in candidates where !isStrictDescendant(url, of: managedBase) {
            throw ModelStorageError.unsafeRemovalTarget(url)
        }
        return candidates
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

    private func itemExists(at url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) { return true }
        return isSymbolicLink(at: url)
    }

    private func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL
            .resolvingSymlinksInPath()
            .pathComponents
        // Resolve every parent component but not the leaf itself: deleting a
        // leaf symlink is safe, while traversing a symlinked parent is not.
        let candidateComponents = candidate
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .appendingPathComponent(candidate.lastPathComponent)
            .pathComponents
        return candidateComponents.count > rootComponents.count
            && candidateComponents.starts(with: rootComponents)
    }

    private func logicalSize(of url: URL) -> Int64 {
        guard !isSymbolicLink(at: url) else { return 0 }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }

        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil)
        else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard !isSymbolicLink(at: item) else {
                enumerator.skipDescendants()
                continue
            }
            var childIsDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: item.path,
                isDirectory: &childIsDirectory
            ), !childIsDirectory.boolValue else { continue }
            let attributes = try? fileManager.attributesOfItem(atPath: item.path)
            total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }
}

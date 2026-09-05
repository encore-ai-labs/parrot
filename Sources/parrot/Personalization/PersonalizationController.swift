import Foundation

struct PersonalizationSnapshot: Sendable {
    let revision: UInt64
    let transcriber: TranscriberPersonalization
    let snippets: SnippetExpander
    let fillers: PersonalFillerRemover
    let vocabularyCount: Int
    let snippetCount: Int
    let fillerCount: Int
}

struct PersonalizationRefresh: Sendable {
    let snapshot: PersonalizationSnapshot
    let didReload: Bool
    let warnings: [String]
}

/// Keeps the daemon's private vocabulary, snippets, and fillers current without
/// a restart. Only three metadata reads occur on the steady-state recording path;
/// JSON decoding and regex/prompt rebuilding happen after an atomic file
/// replacement is observed.
actor PersonalizationController {
    private let vocabularyURL: URL
    private let snippetsURL: URL
    private let fillersURL: URL
    private var vocabularySignature: PersonalizationFileSignature?
    private var snippetsSignature: PersonalizationFileSignature?
    private var fillersSignature: PersonalizationFileSignature?
    private var vocabulary: PersonalVocabulary
    private var snippetLibrary: SnippetLibrary
    private var fillerLibrary: PersonalFillerLibrary
    private var snapshot: PersonalizationSnapshot

    init(
        vocabulary: PersonalVocabulary,
        snippets: SnippetLibrary,
        fillers: PersonalFillerLibrary,
        vocabularyURL: URL = PersonalVocabulary.url,
        snippetsURL: URL = SnippetLibrary.url,
        fillersURL: URL = PersonalFillerLibrary.url
    ) {
        self.vocabulary = vocabulary
        snippetLibrary = snippets
        fillerLibrary = fillers
        self.vocabularyURL = vocabularyURL
        self.snippetsURL = snippetsURL
        self.fillersURL = fillersURL
        vocabularySignature = Self.signature(vocabularyURL)
        snippetsSignature = Self.signature(snippetsURL)
        fillersSignature = Self.signature(fillersURL)
        snapshot = Self.makeSnapshot(
            revision: 0,
            vocabulary: vocabulary,
            snippets: snippets,
            fillers: fillers
        )
    }

    func refreshIfNeeded() -> PersonalizationRefresh {
        var didReload = false
        var warnings: [String] = []

        let currentVocabularySignature = Self.signature(vocabularyURL)
        if currentVocabularySignature != vocabularySignature {
            // Remember an invalid revision too, so one malformed hand edit
            // produces one warning rather than one warning per dictation.
            vocabularySignature = currentVocabularySignature
            do {
                vocabulary = try PersonalVocabulary.load(from: vocabularyURL)
                vocabularySignature = Self.signature(vocabularyURL)
                didReload = true
            } catch {
                warnings.append(
                    "couldn't reload vocabulary; keeping the previous terms: "
                        + error.localizedDescription
                )
            }
        }

        let currentSnippetsSignature = Self.signature(snippetsURL)
        if currentSnippetsSignature != snippetsSignature {
            snippetsSignature = currentSnippetsSignature
            do {
                snippetLibrary = try SnippetLibrary.load(from: snippetsURL)
                snippetsSignature = Self.signature(snippetsURL)
                didReload = true
            } catch {
                warnings.append(
                    "couldn't reload snippets; keeping the previous snippets: "
                        + error.localizedDescription
                )
            }
        }

        let currentFillersSignature = Self.signature(fillersURL)
        if currentFillersSignature != fillersSignature {
            fillersSignature = currentFillersSignature
            do {
                fillerLibrary = try PersonalFillerLibrary.load(from: fillersURL)
                fillersSignature = Self.signature(fillersURL)
                didReload = true
            } catch {
                warnings.append(
                    "couldn't reload personal fillers; keeping the previous phrases: "
                        + error.localizedDescription
                )
            }
        }

        if didReload {
            let nextRevision = snapshot.revision &+ 1
            snapshot = Self.makeSnapshot(
                revision: nextRevision,
                vocabulary: vocabulary,
                snippets: snippetLibrary,
                fillers: fillerLibrary
            )
        }
        return PersonalizationRefresh(
            snapshot: snapshot,
            didReload: didReload,
            warnings: warnings
        )
    }

    private static func makeSnapshot(
        revision: UInt64,
        vocabulary: PersonalVocabulary,
        snippets: SnippetLibrary,
        fillers: PersonalFillerLibrary
    ) -> PersonalizationSnapshot {
        let transcriber = TranscriberPersonalization(
            revision: revision,
            vocabularyReplacer: VocabularyReplacer(entries: vocabulary.entries),
            promptTerms: snippets.promptTerms + vocabulary.promptTerms
        )
        let fillerRemover = PersonalFillerRemover(entries: fillers.entries)
        return PersonalizationSnapshot(
            revision: revision,
            transcriber: transcriber,
            snippets: SnippetExpander(entries: snippets.entries),
            fillers: fillerRemover,
            vocabularyCount: vocabulary.entries.count,
            snippetCount: snippets.entries.count,
            fillerCount: fillerRemover.count
        )
    }

    private static func signature(_ url: URL) -> PersonalizationFileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        return PersonalizationFileSignature(
            modificationDate: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}

private struct PersonalizationFileSignature: Equatable {
    let modificationDate: Date?
    let size: UInt64?
    let fileNumber: UInt64?
}

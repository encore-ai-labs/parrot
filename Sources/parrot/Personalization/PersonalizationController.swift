import Foundation

struct PersonalizationSnapshot: Sendable {
    let revision: UInt64
    let transcriber: TranscriberPersonalization
    let snippets: SnippetExpander
    let fillers: PersonalFillerRemover
    let templates: NoteTemplateRenderer
    let vocabularyCount: Int
    let snippetCount: Int
    let fillerCount: Int
    let templateCount: Int
}

struct PersonalizationRefresh: Sendable {
    let snapshot: PersonalizationSnapshot
    let didReload: Bool
    let warnings: [String]
}

/// Keeps the daemon's private vocabulary, snippets, fillers, and templates current without
/// a restart. Only four metadata reads occur on the steady-state recording path;
/// JSON decoding and regex/prompt rebuilding happen after an atomic file
/// replacement is observed.
actor PersonalizationController {
    private let vocabularyURL: URL
    private let snippetsURL: URL
    private let fillersURL: URL
    private let templatesURL: URL
    private var vocabularySignature: PersonalizationFileSignature?
    private var snippetsSignature: PersonalizationFileSignature?
    private var fillersSignature: PersonalizationFileSignature?
    private var templatesSignature: PersonalizationFileSignature?
    private var vocabulary: PersonalVocabulary
    private var snippetLibrary: SnippetLibrary
    private var fillerLibrary: PersonalFillerLibrary
    private var templateLibrary: NoteTemplateLibrary
    private var snapshot: PersonalizationSnapshot

    init(
        vocabulary: PersonalVocabulary,
        snippets: SnippetLibrary,
        fillers: PersonalFillerLibrary,
        templates: NoteTemplateLibrary = NoteTemplateLibrary(),
        vocabularyURL: URL = PersonalVocabulary.url,
        snippetsURL: URL = SnippetLibrary.url,
        fillersURL: URL = PersonalFillerLibrary.url,
        templatesURL: URL = NoteTemplateLibrary.url
    ) {
        self.vocabulary = vocabulary
        snippetLibrary = snippets
        fillerLibrary = fillers
        self.vocabularyURL = vocabularyURL
        self.snippetsURL = snippetsURL
        self.fillersURL = fillersURL
        self.templatesURL = templatesURL
        vocabularySignature = Self.signature(vocabularyURL)
        snippetsSignature = Self.signature(snippetsURL)
        fillersSignature = Self.signature(fillersURL)
        templatesSignature = Self.signature(templatesURL)
        templateLibrary = templates
        snapshot = Self.makeSnapshot(
            revision: 0,
            vocabulary: vocabulary,
            snippets: snippets,
            fillers: fillers,
            templates: templates
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

        let currentTemplatesSignature = Self.signature(templatesURL)
        if currentTemplatesSignature != templatesSignature {
            templatesSignature = currentTemplatesSignature
            do {
                templateLibrary = try NoteTemplateLibrary.load(from: templatesURL)
                templatesSignature = Self.signature(templatesURL)
                didReload = true
            } catch {
                warnings.append(
                    "couldn't reload note templates; keeping the previous templates: "
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
                fillers: fillerLibrary,
                templates: templateLibrary
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
        fillers: PersonalFillerLibrary,
        templates: NoteTemplateLibrary
    ) -> PersonalizationSnapshot {
        let transcriber = TranscriberPersonalization(
            revision: revision,
            vocabularyReplacer: VocabularyReplacer(entries: vocabulary.entries),
            promptTerms: templates.promptTerms + snippets.promptTerms + vocabulary.promptTerms
        )
        let fillerRemover = PersonalFillerRemover(entries: fillers.entries)
        return PersonalizationSnapshot(
            revision: revision,
            transcriber: transcriber,
            snippets: SnippetExpander(entries: snippets.entries),
            fillers: fillerRemover,
            templates: NoteTemplateRenderer(library: templates),
            vocabularyCount: vocabulary.entries.count,
            snippetCount: snippets.entries.count,
            fillerCount: fillerRemover.count,
            templateCount: templates.entries.count
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

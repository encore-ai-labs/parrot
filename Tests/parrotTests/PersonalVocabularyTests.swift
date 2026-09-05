import XCTest

@testable import parrot

final class PersonalVocabularyTests: XCTestCase {
    func testAddsUpdatesAndRemovesCaseInsensitively() throws {
        var vocabulary = PersonalVocabulary()

        XCTAssertFalse(try vocabulary.set(spoken: "rust pond", written: "RustPond"))
        XCTAssertTrue(try vocabulary.set(spoken: "  RUST   POND ", written: "RustPond CLI"))
        XCTAssertEqual(
            vocabulary.entries,
            [VocabularyEntry(spoken: "RUST POND", written: "RustPond CLI")]
        )
        XCTAssertTrue(vocabulary.remove(spoken: "Rust Pond"))
        XCTAssertTrue(vocabulary.entries.isEmpty)
    }

    func testAppliesPhrasesCaseInsensitivelyWithoutTouchingSubstrings() throws {
        var vocabulary = PersonalVocabulary()
        try vocabulary.set(spoken: "rust pond", written: "RustPond")
        try vocabulary.set(spoken: "codex", written: "Codex")

        XCTAssertEqual(
            vocabulary.applying(to: "RUST POND works with codex, not codexical."),
            "RustPond works with Codex, not codexical."
        )
    }

    func testOverlappingEntriesUseLongestMatchAndDoNotCascade() throws {
        var vocabulary = PersonalVocabulary()
        try vocabulary.set(spoken: "pond", written: "lake")
        try vocabulary.set(spoken: "rust pond", written: "Parrot")
        try vocabulary.set(spoken: "parrot", written: "bird")

        XCTAssertEqual(
            vocabulary.applying(to: "rust pond by the pond"),
            "Parrot by the lake"
        )
    }

    func testPrecompiledReplacerHandlesLargeVocabulary() throws {
        var vocabulary = PersonalVocabulary()
        for index in 0..<500 {
            try vocabulary.set(spoken: "spoken term \(index)", written: "WrittenTerm\(index)")
        }
        let replacer = VocabularyReplacer(entries: vocabulary.entries)

        XCTAssertEqual(
            replacer.applying(to: "Use spoken term 499 with spoken term 12."),
            "Use WrittenTerm499 with WrittenTerm12."
        )
    }

    func testPrecompiledReplacerPerformanceWithLargeVocabulary() throws {
        var vocabulary = PersonalVocabulary()
        for index in 0..<500 {
            try vocabulary.set(spoken: "spoken term \(index)", written: "WrittenTerm\(index)")
        }
        let replacer = VocabularyReplacer(entries: vocabulary.entries)
        var output = ""

        measure {
            for _ in 0..<100 {
                output = replacer.applying(
                    to: "A short note using spoken term 499 and spoken term 12."
                )
            }
        }
        XCTAssertEqual(output, "A short note using WrittenTerm499 and WrittenTerm12.")
    }

    func testPromptTermsPrioritizeRecentUniqueShortSpellings() throws {
        var vocabulary = PersonalVocabulary()
        try vocabulary.set(spoken: "codex", written: "Codex")
        try vocabulary.set(spoken: "code x", written: "Codex")
        try vocabulary.set(spoken: "rust pond", written: "RustPond")
        try vocabulary.set(spoken: "snippet", written: String(repeating: "x", count: 65))

        XCTAssertEqual(vocabulary.promptTerms, ["RustPond", "Codex"])
    }

    func testPersistsToPrivateLocalJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-vocabulary-tests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("vocabulary.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        var vocabulary = PersonalVocabulary()
        try vocabulary.set(spoken: "rust pond", written: "RustPond")
        try vocabulary.save(to: url)

        XCTAssertEqual(try PersonalVocabulary.load(from: url), vocabulary)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(fileAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
    }

    func testRejectsEmptyForms() {
        var vocabulary = PersonalVocabulary()
        XCTAssertThrowsError(try vocabulary.set(spoken: "   ", written: "value"))
        XCTAssertThrowsError(try vocabulary.set(spoken: "value", written: " \n "))
    }
}

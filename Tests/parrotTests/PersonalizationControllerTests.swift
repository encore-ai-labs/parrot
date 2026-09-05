import XCTest

@testable import parrot

final class PersonalizationControllerTests: XCTestCase {
    func testReloadMakesVocabularyPromptAndSnippetAvailableTogether() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vocabularyURL = root.appendingPathComponent("vocabulary.json")
        let snippetsURL = root.appendingPathComponent("snippets.json")
        let fillersURL = root.appendingPathComponent("fillers.json")
        let controller = PersonalizationController(
            vocabulary: PersonalVocabulary(),
            snippets: SnippetLibrary(),
            fillers: PersonalFillerLibrary(),
            vocabularyURL: vocabularyURL,
            snippetsURL: snippetsURL,
            fillersURL: fillersURL
        )

        var vocabulary = PersonalVocabulary()
        try vocabulary.set(spoken: "rust pond", written: "RustPond")
        try vocabulary.save(to: vocabularyURL)
        var snippets = SnippetLibrary()
        try snippets.set(trigger: "meeting close", content: "Thanks,\nParth")
        try snippets.save(to: snippetsURL)
        var fillers = PersonalFillerLibrary()
        try fillers.set("you know")
        try fillers.save(to: fillersURL)

        let refresh = await controller.refreshIfNeeded()

        XCTAssertTrue(refresh.didReload)
        XCTAssertEqual(refresh.snapshot.revision, 1)
        XCTAssertEqual(refresh.snapshot.vocabularyCount, 1)
        XCTAssertEqual(refresh.snapshot.snippetCount, 1)
        XCTAssertEqual(refresh.snapshot.fillerCount, 1)
        XCTAssertEqual(
            refresh.snapshot.transcriber.promptTerms,
            ["insert snippet meeting close", "RustPond"]
        )
        XCTAssertEqual(
            refresh.snapshot.transcriber.vocabularyReplacer.applying(to: "ship rust pond"),
            "ship RustPond"
        )
        XCTAssertEqual(
            refresh.snapshot.snippets.applying(to: "insert snippet meeting close"),
            "Thanks,\nParth"
        )
        XCTAssertEqual(
            refresh.snapshot.fillers.applying(to: "We should, you know, ship."),
            "We should ship."
        )

        let unchanged = await controller.refreshIfNeeded()
        XCTAssertFalse(unchanged.didReload)
        XCTAssertTrue(unchanged.warnings.isEmpty)
        XCTAssertEqual(unchanged.snapshot.revision, 1)
    }

    func testMalformedEditWarnsOnceAndKeepsLastGoodSnapshot() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vocabularyURL = root.appendingPathComponent("vocabulary.json")
        let snippetsURL = root.appendingPathComponent("snippets.json")
        let fillersURL = root.appendingPathComponent("fillers.json")
        var vocabulary = PersonalVocabulary()
        try vocabulary.set(spoken: "jay son", written: "JSON")
        try vocabulary.save(to: vocabularyURL)
        let controller = PersonalizationController(
            vocabulary: vocabulary,
            snippets: SnippetLibrary(),
            fillers: PersonalFillerLibrary(),
            vocabularyURL: vocabularyURL,
            snippetsURL: snippetsURL,
            fillersURL: fillersURL
        )

        try "{not valid json".write(to: vocabularyURL, atomically: true, encoding: .utf8)
        let malformed = await controller.refreshIfNeeded()
        XCTAssertFalse(malformed.didReload)
        XCTAssertEqual(malformed.warnings.count, 1)
        XCTAssertEqual(
            malformed.snapshot.transcriber.vocabularyReplacer.applying(to: "use jay son"),
            "use JSON"
        )

        let unchangedMalformedFile = await controller.refreshIfNeeded()
        XCTAssertFalse(unchangedMalformedFile.didReload)
        XCTAssertTrue(unchangedMalformedFile.warnings.isEmpty)

        var repaired = PersonalVocabulary()
        try repaired.set(spoken: "rust pond", written: "RustPond")
        try repaired.save(to: vocabularyURL)
        let repairedRefresh = await controller.refreshIfNeeded()
        XCTAssertTrue(repairedRefresh.didReload)
        XCTAssertEqual(repairedRefresh.snapshot.revision, 1)
        XCTAssertEqual(
            repairedRefresh.snapshot.transcriber.vocabularyReplacer.applying(to: "rust pond"),
            "RustPond"
        )
        XCTAssertEqual(
            repairedRefresh.snapshot.transcriber.vocabularyReplacer.applying(to: "jay son"),
            "jay son"
        )
    }

    func testDeletingPersonalizationFileClearsItOnNextCapture() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vocabularyURL = root.appendingPathComponent("vocabulary.json")
        let snippetsURL = root.appendingPathComponent("snippets.json")
        let fillersURL = root.appendingPathComponent("fillers.json")
        var snippets = SnippetLibrary()
        try snippets.set(trigger: "signature", content: "Regards, Parth")
        try snippets.save(to: snippetsURL)
        var fillers = PersonalFillerLibrary()
        try fillers.set("basically")
        try fillers.save(to: fillersURL)
        let controller = PersonalizationController(
            vocabulary: PersonalVocabulary(),
            snippets: snippets,
            fillers: fillers,
            vocabularyURL: vocabularyURL,
            snippetsURL: snippetsURL,
            fillersURL: fillersURL
        )

        try FileManager.default.removeItem(at: snippetsURL)
        try FileManager.default.removeItem(at: fillersURL)
        let refresh = await controller.refreshIfNeeded()

        XCTAssertTrue(refresh.didReload)
        XCTAssertEqual(refresh.snapshot.snippetCount, 0)
        XCTAssertEqual(refresh.snapshot.fillerCount, 0)
        XCTAssertEqual(
            refresh.snapshot.snippets.applying(to: "insert snippet signature"),
            "insert snippet signature"
        )
        XCTAssertEqual(
            refresh.snapshot.fillers.applying(to: "Basically, ship."),
            "Basically, ship."
        )
    }

    func testMalformedFillerEditWarnsOnceAndKeepsLastGoodSnapshot() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vocabularyURL = root.appendingPathComponent("vocabulary.json")
        let snippetsURL = root.appendingPathComponent("snippets.json")
        let fillersURL = root.appendingPathComponent("fillers.json")
        var fillers = PersonalFillerLibrary()
        try fillers.set("basically")
        try fillers.save(to: fillersURL)
        let controller = PersonalizationController(
            vocabulary: PersonalVocabulary(),
            snippets: SnippetLibrary(),
            fillers: fillers,
            vocabularyURL: vocabularyURL,
            snippetsURL: snippetsURL,
            fillersURL: fillersURL
        )

        try "{not valid json".write(to: fillersURL, atomically: true, encoding: .utf8)
        let malformed = await controller.refreshIfNeeded()
        XCTAssertFalse(malformed.didReload)
        XCTAssertEqual(malformed.warnings.count, 1)
        XCTAssertEqual(
            malformed.snapshot.fillers.applying(to: "Basically, ship it."),
            "Ship it."
        )

        let unchangedMalformedFile = await controller.refreshIfNeeded()
        XCTAssertFalse(unchangedMalformedFile.didReload)
        XCTAssertTrue(unchangedMalformedFile.warnings.isEmpty)

        var repaired = PersonalFillerLibrary()
        try repaired.set("you know")
        try repaired.save(to: fillersURL)
        let repairedRefresh = await controller.refreshIfNeeded()
        XCTAssertTrue(repairedRefresh.didReload)
        XCTAssertEqual(repairedRefresh.snapshot.fillerCount, 1)
        XCTAssertEqual(
            repairedRefresh.snapshot.fillers.applying(to: "You know, ship it."),
            "Ship it."
        )
        XCTAssertEqual(
            repairedRefresh.snapshot.fillers.applying(to: "Basically, ship it."),
            "Basically, ship it."
        )
    }

    func testUnchangedMetadataCheckIsCheapAcrossLargeLibraries() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vocabularyURL = root.appendingPathComponent("vocabulary.json")
        let snippetsURL = root.appendingPathComponent("snippets.json")
        let fillersURL = root.appendingPathComponent("fillers.json")
        var vocabulary = PersonalVocabulary()
        var snippets = SnippetLibrary()
        for index in 0..<1_000 {
            try vocabulary.set(spoken: "term \(index)", written: "Term\(index)")
            try snippets.set(trigger: "template \(index)", content: "body \(index)")
        }
        var fillers = PersonalFillerLibrary()
        for index in 0..<PersonalFillerLibrary.maximumEntries {
            try fillers.set("filler \(index)")
        }
        try vocabulary.save(to: vocabularyURL)
        try snippets.save(to: snippetsURL)
        try fillers.save(to: fillersURL)
        let controller = PersonalizationController(
            vocabulary: vocabulary,
            snippets: snippets,
            fillers: fillers,
            vocabularyURL: vocabularyURL,
            snippetsURL: snippetsURL,
            fillersURL: fillersURL
        )

        var allChecksWereUnchanged = false
        measure {
            allChecksWereUnchanged = waitForUnchangedChecks(
                1_000,
                controller: controller
            )
        }
        XCTAssertTrue(allChecksWereUnchanged)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-personalization-tests-\(UUID().uuidString)")
    }

    private func waitForUnchangedChecks(
        _ count: Int,
        controller: PersonalizationController
    ) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let result = SendableBox<Bool>()
        Task.detached {
            var unchanged = true
            for _ in 0..<count {
                if await controller.refreshIfNeeded().didReload {
                    unchanged = false
                }
            }
            result.set(unchanged)
            semaphore.signal()
        }
        semaphore.wait()
        return result.get() ?? false
    }
}

private final class SendableBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

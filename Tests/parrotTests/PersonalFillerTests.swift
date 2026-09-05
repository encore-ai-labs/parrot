import XCTest

@testable import parrot

final class PersonalFillerTests: XCTestCase {
    func testLibraryNormalizesPersistsAndRemovesPhrasesPrivately() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("nested/fillers.json")
        var library = PersonalFillerLibrary()

        XCTAssertFalse(try library.set("  you   know  "))
        XCTAssertTrue(try library.set("You Know"))
        XCTAssertFalse(try library.set("basically"))
        try library.save(to: url)

        let loaded = try PersonalFillerLibrary.load(from: url)
        XCTAssertEqual(
            loaded.entries,
            [
                PersonalFillerEntry(phrase: "You Know"),
                PersonalFillerEntry(phrase: "basically"),
            ]
        )
        XCTAssertEqual(permissions(at: url), 0o600)
        XCTAssertEqual(permissions(at: url.deletingLastPathComponent()), 0o700)

        var edited = loaded
        XCTAssertTrue(edited.remove("you know"))
        XCTAssertFalse(edited.remove("not there"))
        XCTAssertEqual(edited.entries, [PersonalFillerEntry(phrase: "basically")])
    }

    func testLibraryRejectsUnsafeOrUnboundedEntries() throws {
        var library = PersonalFillerLibrary()
        XCTAssertThrowsError(try library.set(""))
        XCTAssertThrowsError(try library.set("one two three four five six seven"))
        XCTAssertThrowsError(try library.set("remove (this)"))
        XCTAssertThrowsError(try library.set(String(repeating: "a", count: 81)))

        for index in 0..<PersonalFillerLibrary.maximumEntries {
            try library.set("phrase \(index)")
        }
        XCTAssertThrowsError(try library.set("one more"))
        XCTAssertNoThrow(try library.set("Phrase 0"))
    }

    func testRemovesWholePhrasesAndRepairsLocalPunctuation() throws {
        var library = PersonalFillerLibrary()
        try library.set("basically")
        try library.set("you know")
        let remover = PersonalFillerRemover(entries: library.entries)

        XCTAssertEqual(
            remover.applying(to: "Basically, this is, you know, ready."),
            "This is ready."
        )
        XCTAssertEqual(remover.applying(to: "The plan is basically."), "The plan is.")
        XCTAssertEqual(remover.applying(to: "Basically."), "")
        XCTAssertEqual(
            remover.applying(to: "Literal basically, keep this. Say literal you know here."),
            "Basically, keep this. Say you know here."
        )
        XCTAssertEqual(
            remover.applying(
                to: "Keep basically-sound, basically_sound, basically.com, "
                    + "a@basically.com, #basically, and /basically paths."
            ),
            "Keep basically-sound, basically_sound, basically.com, "
                + "a@basically.com, #basically, and /basically paths."
        )
    }

    func testPersonalFillersRunBeforeFormattingAndNeverRewriteSnippetBodies() throws {
        var fillers = PersonalFillerLibrary()
        try fillers.set("you know")
        var snippets = SnippetLibrary()
        try snippets.set(trigger: "raw", content: "You know, keep this exact")

        XCTAssertEqual(
            TranscriptProcessing.process(
                "You know, heading two Plan. Insert snippet raw.",
                mode: .notes,
                lowercase: false,
                fillers: PersonalFillerRemover(entries: fillers.entries),
                snippets: SnippetExpander(entries: snippets.entries)
            ),
            "## Plan. You know, keep this exact"
        )
    }

    func testFileTimelineUsesPersonalFillersAndDropsEmptySegments() throws {
        var fillers = PersonalFillerLibrary()
        try fillers.set("basically")
        let remover = PersonalFillerRemover(entries: fillers.entries)
        let segments = [
            TimedTranscriptSegment(startSeconds: 0, endSeconds: 1, text: "Basically."),
            TimedTranscriptSegment(startSeconds: 1, endSeconds: 2, text: "Basically, ship."),
        ]

        XCTAssertEqual(
            TranscriptProcessing.processSegments(
                segments,
                cleanup: false,
                fillers: remover
            ),
            [TimedTranscriptSegment(startSeconds: 1, endSeconds: 2, text: "Ship.")]
        )
    }

    func testFillerCommandParsesMultiwordPhrase() throws {
        XCTAssertNoThrow(try Fillers.parseAsRoot(["add", "you know"]))
        XCTAssertNoThrow(try Fillers.parseAsRoot(["remove", "you know"]))
        XCTAssertNoThrow(try Fillers.parseAsRoot(["path"]))
    }

    func testCompiledRemovalCostStaysBoundedAtMaximumLibrarySize() throws {
        var library = PersonalFillerLibrary()
        for index in 0..<PersonalFillerLibrary.maximumEntries {
            try library.set("filler phrase \(index)")
        }
        let remover = PersonalFillerRemover(entries: library.entries)
        let draft = String(
            repeating: "We should, filler phrase 127, write this project note today. ",
            count: 40
        )

        measure {
            for _ in 0..<100 {
                _ = remover.applying(to: draft)
            }
        }
    }

    func testTypicalPersonalFillerCleanupPerformance() throws {
        var library = PersonalFillerLibrary()
        try library.set("basically")
        try library.set("you know")
        try library.set("to be honest")
        let remover = PersonalFillerRemover(entries: library.entries)
        let draft = "Basically, I think we should, you know, ship the project note today."

        measure {
            for _ in 0..<1_000 {
                _ = remover.applying(to: draft)
            }
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-filler-tests-\(UUID().uuidString)")
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
}

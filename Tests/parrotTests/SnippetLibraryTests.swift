import XCTest

@testable import parrot

final class SnippetLibraryTests: XCTestCase {
    func testAddsUpdatesFindsAndRemovesCaseInsensitively() throws {
        var library = SnippetLibrary()

        XCTAssertFalse(try library.set(trigger: " meeting   notes ", content: "# Meeting"))
        XCTAssertTrue(try library.set(trigger: "MEETING NOTES", content: "# Updated"))
        XCTAssertEqual(
            library.entries,
            [SnippetEntry(trigger: "MEETING NOTES", content: "# Updated")]
        )
        XCTAssertEqual(library.entry(matching: "meeting notes")?.content, "# Updated")
        XCTAssertTrue(library.remove(trigger: "Meeting Notes"))
        XCTAssertTrue(library.entries.isEmpty)
    }

    func testPersistsExactContentToPrivateLocalJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-snippet-tests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("snippets.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        var library = SnippetLibrary()
        try library.set(trigger: "meeting", content: "# Agenda\n\n- [ ] Follow up\n")
        try library.save(to: url)

        XCTAssertEqual(try SnippetLibrary.load(from: url), library)
        XCTAssertEqual(
            try SnippetLibrary.load(from: url).entries.first?.content,
            "# Agenda\n\n- [ ] Follow up\n"
        )
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(fileAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
    }

    func testExpandsOnlyExplicitCommandsAndKeepsBodyVerbatim() throws {
        var library = SnippetLibrary()
        try library.set(trigger: "daily note", content: "## Daily Note\n\n- [ ] Review API")
        let expander = SnippetExpander(entries: library.entries)

        XCTAssertEqual(
            expander.applying(to: "Start. Insert snippet daily note. End."),
            "Start. ## Daily Note\n\n- [ ] Review API End."
        )
        XCTAssertEqual(
            expander.applying(to: "Discuss the daily note and snippet system."),
            "Discuss the daily note and snippet system."
        )
    }

    func testOverlappingTriggersUseLongestMatchAndNeverCascade() throws {
        var library = SnippetLibrary()
        try library.set(trigger: "sign", content: "insert snippet closing")
        try library.set(trigger: "signature", content: "— Parth")
        try library.set(trigger: "closing", content: "Thanks!")
        let expander = SnippetExpander(entries: library.entries)

        XCTAssertEqual(expander.applying(to: "insert snippet signature"), "— Parth")
        XCTAssertEqual(
            expander.applying(to: "insert snippet sign"),
            "insert snippet closing"
        )
    }

    func testLiteralPrefixEscapesExpansion() throws {
        var library = SnippetLibrary()
        try library.set(trigger: "signature", content: "— Parth")
        let expander = SnippetExpander(entries: library.entries)

        XCTAssertEqual(
            expander.applying(to: "Say literal insert snippet signature."),
            "Say insert snippet signature."
        )
    }

    func testDoesNotMatchInsideLongerWordsOrTriggers() throws {
        var library = SnippetLibrary()
        try library.set(trigger: "sign", content: "— Parth")
        let expander = SnippetExpander(entries: library.entries)

        XCTAssertEqual(
            expander.applying(to: "reinsert snippet sign and insert snippet signature"),
            "reinsert snippet sign and insert snippet signature"
        )
    }

    func testExpansionRunsAfterNoteAndLowercaseFormatting() throws {
        var library = SnippetLibrary()
        try library.set(trigger: "template", content: "Owner: Parth\n- [ ] Ship API")
        let dictated = NoteFormatter.format(
            "Heading one plan. New paragraph. Insert snippet template"
        )
            .lowercased()

        XCTAssertEqual(
            SnippetExpander(entries: library.entries).applying(to: dictated),
            "# plan.\n\nOwner: Parth\n- [ ] Ship API"
        )
    }

    func testPromptTermsContainCommandsButNeverSnippetBodies() throws {
        var library = SnippetLibrary()
        for index in 1...5 {
            try library.set(
                trigger: "saved text \(index)",
                content: index == 1 ? "Private long-form body" : "Content \(index)"
            )
        }

        XCTAssertEqual(
            library.promptTerms,
            [
                "insert snippet saved text 5",
                "insert snippet saved text 4",
                "insert snippet saved text 3",
                "insert snippet saved text 2",
            ]
        )
        XCTAssertFalse(library.promptTerms.joined().contains("Private"))
    }

    func testRejectsInvalidAndOversizedEntries() {
        var library = SnippetLibrary()
        XCTAssertThrowsError(try library.set(trigger: " ", content: "value"))
        XCTAssertThrowsError(try library.set(trigger: "value", content: " \n "))
        XCTAssertThrowsError(
            try library.set(trigger: String(repeating: "x", count: 81), content: "value")
        )
        XCTAssertThrowsError(
            try library.set(trigger: "value", content: String(repeating: "x", count: 100_001))
        )
    }

    func testSnippetCommandParsesTextAndFileInputs() throws {
        let text = try XCTUnwrap(
            try Snippets.Add.parseAsRoot(["signature", "--text", "Thanks"]) as? Snippets.Add
        )
        XCTAssertEqual(text.trigger, "signature")
        XCTAssertEqual(text.text, "Thanks")

        let file = try XCTUnwrap(
            try Snippets.Add.parseAsRoot(["meeting", "--file", "template.md"])
                as? Snippets.Add
        )
        XCTAssertEqual(file.file, "template.md")

        XCTAssertThrowsError(try Snippets.Add.parseAsRoot(["meeting"]))
        XCTAssertThrowsError(
            try Snippets.Add.parseAsRoot([
                "meeting", "--text", "text", "--file", "template.md",
            ])
        )
    }

    func testPrecompiledExpanderPerformanceWithLargeLibrary() throws {
        var library = SnippetLibrary()
        for index in 0..<500 {
            try library.set(trigger: "saved text \(index)", content: "Expanded content \(index)")
        }
        let expander = SnippetExpander(entries: library.entries)
        var output = ""

        measure {
            for _ in 0..<100 {
                output = expander.applying(to: "Please insert snippet saved text 499 now.")
            }
        }
        XCTAssertEqual(output, "Please Expanded content 499 now.")
    }
}

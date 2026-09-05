import XCTest

@testable import parrot

final class NoteTemplateTests: XCTestCase {
    func testLibraryAddsUpdatesFindsAndRemovesCaseInsensitively() throws {
        var library = NoteTemplateLibrary()

        XCTAssertFalse(try library.set(
            name: " daily   standup ",
            body: "# Standup\n\n{{transcript}}"
        ))
        XCTAssertTrue(try library.set(
            name: "DAILY STANDUP",
            body: "# Updated\n\n{{transcript}}"
        ))
        XCTAssertEqual(library.entries, [NoteTemplateEntry(
            name: "DAILY STANDUP",
            body: "# Updated\n\n{{transcript}}"
        )])
        XCTAssertEqual(library.canonicalName(matching: "daily standup"), "DAILY STANDUP")
        XCTAssertTrue(library.remove(name: "Daily Standup"))
        XCTAssertTrue(library.entries.isEmpty)
    }

    func testLibraryValidatesNamesBoundsAndPlaceholders() throws {
        var library = NoteTemplateLibrary()
        XCTAssertThrowsError(try library.set(name: "", body: "{{transcript}}"))
        XCTAssertThrowsError(try library.set(name: "bad/name", body: "{{transcript}}"))
        XCTAssertThrowsError(try library.set(
            name: String(repeating: "x", count: 61),
            body: "{{transcript}}"
        ))
        XCTAssertThrowsError(try library.set(name: "empty", body: " \n "))
        XCTAssertThrowsError(try library.set(name: "missing", body: "# Date {{date}}"))
        XCTAssertThrowsError(try library.set(
            name: "repeated",
            body: "{{transcript}} and {{transcript}}"
        ))
        XCTAssertThrowsError(try library.set(
            name: "unknown",
            body: "{{transcript}} {{person}}"
        ))
        XCTAssertThrowsError(try library.set(
            name: "malformed",
            body: "{{transcript}} {{date}"
        ))
        XCTAssertThrowsError(try library.set(
            name: "huge",
            body: "{{transcript}}" + String(
                repeating: "x",
                count: NoteTemplateLibrary.maximumBodyCharacters
            )
        ))

        for index in 0..<NoteTemplateLibrary.maximumEntries {
            try library.set(name: "template \(index)", body: "{{transcript}}")
        }
        XCTAssertThrowsError(try library.set(name: "one more", body: "{{transcript}}"))
        XCTAssertNoThrow(try library.set(name: "template 0", body: "# Updated\n{{transcript}}"))
    }

    func testLibraryPersistsExactPrivateContentAndRejectsMalformedManualEdit() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("note-templates.json")
        var library = NoteTemplateLibrary()
        try library.set(
            name: "meeting",
            body: "# Meeting — {{date}}\n\n{{transcript}}\n"
        )
        try library.save(to: url)

        XCTAssertEqual(try NoteTemplateLibrary.load(from: url), library)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                as? NSNumber,
            NSNumber(value: 0o600)
        )
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
                as? NSNumber,
            NSNumber(value: 0o700)
        )

        let invalid = #"{"entries":[{"name":"bad/name","body":"{{transcript}}"}]}"#
        try invalid.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try NoteTemplateLibrary.load(from: url))
    }

    func testRendererUsesLocalDeterministicDateValuesAndExactStructure() throws {
        var library = NoteTemplateLibrary()
        try library.set(
            name: "daily",
            body: "# {{date}} at {{time}}\n\n{{transcript}}\n\n`{{datetime}}`"
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 6,
            hour: 1,
            minute: 1,
            second: 1
        )))

        XCTAssertEqual(
            NoteTemplateRenderer(library: library).render(
                "  - [ ] Ship it  ",
                templateName: "DAILY",
                at: date,
                calendar: calendar
            ),
            "# 2026-09-06 at 01:01\n\n- [ ] Ship it\n\n`2026-09-06T01:01:01+00:00`"
        )
    }

    func testSpokenTriggerUsesLongestNameAndLiteralEscape() throws {
        var library = NoteTemplateLibrary()
        try library.set(name: "daily", body: "Daily: {{transcript}}")
        try library.set(name: "daily standup", body: "Standup: {{transcript}}")
        let renderer = NoteTemplateRenderer(library: library)

        XCTAssertEqual(
            renderer.resolve(" Template daily\nstandup, bullet point ship it"),
            .init(
                text: "bullet point ship it",
                templateName: "daily standup",
                wasTriggered: true
            )
        )
        XCTAssertEqual(
            renderer.resolve("literal template daily, should stay"),
            .init(
                text: "template daily, should stay",
                templateName: nil,
                wasTriggered: false
            )
        )
        XCTAssertEqual(
            renderer.resolve("template unknown, unchanged").text,
            "template unknown, unchanged"
        )
    }

    func testPipelineTemplateTriggerForcesNotesAndRunsAfterFormatting() throws {
        var library = NoteTemplateLibrary()
        try library.set(
            name: "project",
            body: "# Project\n\n{{transcript}}\n\nGenerated {{date}}"
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 6,
            hour: 1,
            minute: 1,
            second: 1
        )))
        let result = TranscriptProcessing.processWithSpokenModeTrigger(
            "template project, bullet point Ship the API",
            fallbackMode: .dictation,
            lowercase: true,
            snippets: SnippetExpander(entries: []),
            templates: NoteTemplateRenderer(library: library),
            date: date,
            calendar: calendar
        )

        XCTAssertEqual(
            result,
            .init(
                text: "# Project\n\n- ship the api\n\nGenerated 2026-09-06",
                mode: .notes,
                usedSpokenModeTrigger: false,
                templateName: "project",
                usedSpokenTemplateTrigger: true
            )
        )
    }

    func testTemplateTriggerSurvivesAutomaticParagraphReconstruction() throws {
        var library = NoteTemplateLibrary()
        try library.set(name: "meeting", body: "# Meeting\n\n{{transcript}}")
        let raw = "template meeting, bullet point Capture the decision"
        let result = TranscriptProcessing.processWithSpokenModeTrigger(
            raw,
            fallbackMode: .dictation,
            lowercase: false,
            automaticParagraphs: true,
            segments: [
                TimedTranscriptSegment(
                    startSeconds: 0,
                    endSeconds: 0.8,
                    text: "template meeting,"
                ),
                TimedTranscriptSegment(
                    startSeconds: 2.2,
                    endSeconds: 3.5,
                    text: "bullet point Capture the decision"
                ),
            ],
            snippets: SnippetExpander(entries: []),
            templates: NoteTemplateRenderer(library: library)
        )

        XCTAssertEqual(result.text, "# Meeting\n\n- Capture the decision")
        XCTAssertEqual(result.mode, .notes)
        XCTAssertEqual(result.templateName, "meeting")
        XCTAssertTrue(result.usedSpokenTemplateTrigger)
    }

    func testConfiguredTemplateAppliesOnlyToNotesAndOffPathIsByteStable() throws {
        var library = NoteTemplateLibrary()
        try library.set(name: "daily", body: "# Daily\n\n{{transcript}}")
        let renderer = NoteTemplateRenderer(library: library)
        let snippets = SnippetExpander(entries: [])

        XCTAssertEqual(
            TranscriptProcessing.process(
                "Bullet point Keep This",
                mode: .notes,
                lowercase: false,
                snippets: snippets,
                templates: renderer,
                configuredNoteTemplate: "daily"
            ),
            "# Daily\n\n- Keep This"
        )
        XCTAssertEqual(
            TranscriptProcessing.process(
                "Keep This",
                mode: .dictation,
                lowercase: false,
                snippets: snippets,
                templates: renderer,
                configuredNoteTemplate: "daily"
            ),
            "Keep This"
        )
        XCTAssertEqual(
            TranscriptProcessing.process(
                "Keep This",
                mode: .dictation,
                lowercase: false,
                snippets: snippets
            ),
            "Keep This"
        )
        XCTAssertEqual(renderer.render("  \n", templateName: "daily"), "")
    }

    func testPromptTermsContainNamesButNeverPrivateBodies() throws {
        var library = NoteTemplateLibrary()
        for index in 1...5 {
            try library.set(
                name: "workflow \(index)",
                body: index == 1
                    ? "Private customer structure\n{{transcript}}"
                    : "# Workflow \(index)\n{{transcript}}"
            )
        }

        XCTAssertEqual(
            library.promptTerms,
            ["template workflow 5", "template workflow 4", "template workflow 3", "template workflow 2"]
        )
        XCTAssertFalse(library.promptTerms.joined().contains("Private"))
    }

    func testCommandsAndRunOverridesParseAndConflict() throws {
        let add = try XCTUnwrap(
            try Templates.parseAsRoot(["add", "daily", "--preset", "daily"])
                as? Templates.Add
        )
        XCTAssertEqual(add.name, "daily")
        XCTAssertEqual(add.preset, .daily)
        XCTAssertThrowsError(try Templates.parseAsRoot(["add", "daily"]))
        XCTAssertThrowsError(try Templates.parseAsRoot([
            "add", "daily", "--preset", "daily", "--text", "{{transcript}}",
        ]))

        let run = try XCTUnwrap(
            try Run.parseAsRoot(["--template", "daily"]) as? Run
        )
        XCTAssertEqual(run.noteTemplate, "daily")
        XCTAssertThrowsError(try Run.parseAsRoot([
            "--template", "daily", "--no-template",
        ]))
        XCTAssertThrowsError(try Run.parseAsRoot([
            "--template", "daily", "--dictation",
        ]))
        XCTAssertThrowsError(try Transcribe.parseAsRoot([
            "memo.wav", "--template", "daily", "--dictation",
        ]))
    }

    func testRuntimeOverrideSelectsNotesAndSavedTemplateCanBeDisabled() throws {
        var config = Config()
        config.noteTemplate = "daily"
        config.mode = .dictation

        let saved = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(saved.mode, .dictation)
        XCTAssertEqual(saved.noteTemplate, "daily")

        let overridden = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            noteTemplateOverride: "meeting",
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(overridden.mode, .notes)
        XCTAssertEqual(overridden.noteTemplate, "meeting")

        let disabled = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            disableNoteTemplate: true,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertNil(disabled.noteTemplate)
    }

    func testRenderingCostStaysNegligibleForLongNotes() throws {
        var library = NoteTemplateLibrary()
        try library.set(
            name: "project",
            body: "# Project — {{date}}\n\n{{transcript}}\n\n_End {{time}}_"
        )
        let renderer = NoteTemplateRenderer(library: library)
        let note = String(repeating: "A long local note sentence. ", count: 4_000)
        let start = ContinuousClock.now
        var rendered = ""
        for _ in 0..<100 {
            rendered = renderer.render(note, templateName: "project")
        }
        let elapsed = start.duration(to: .now)

        XCTAssertTrue(rendered.hasPrefix("# Project"))
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-template-tests-\(UUID().uuidString)")
    }
}

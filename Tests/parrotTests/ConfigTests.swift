import Foundation
import XCTest

@testable import parrot

final class ConfigTests: XCTestCase {
    func testLoadsOlderConfigWithoutNewRuntimeDefaults() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"lowercase":true,"inputDeviceUID":"mic-1","setupCompleted":true}"#.utf8)
            .write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: root.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: url.path
        )

        let config = Config.load(from: url)

        XCTAssertEqual(config.lowercase, true)
        XCTAssertEqual(config.inputDeviceUID, "mic-1")
        XCTAssertNil(config.inputDeviceUIDs)
        XCTAssertEqual(config.savedInputDeviceUIDs, ["mic-1"])
        XCTAssertEqual(config.setupCompleted, true)
        XCTAssertNil(config.hotkey)
        XCTAssertNil(config.noteHotkey)
        XCTAssertNil(config.noteJournalPath)
        XCTAssertNil(config.recognitionContext)
        XCTAssertNil(config.model)
        XCTAssertNil(config.language)
        XCTAssertNil(config.mode)
        XCTAssertNil(config.appRules)
        XCTAssertNil(config.journalPath)
        XCTAssertNil(config.deliveryCommand)
        XCTAssertNil(config.cleanup)
        XCTAssertNil(config.automaticParagraphs)
        XCTAssertNil(config.spaceAfterPaste)
        XCTAssertNil(config.insertionMethod)
        XCTAssertNil(config.clipboardRestoreDelayMilliseconds)
        XCTAssertNil(config.warmMicrophone)
        XCTAssertNil(config.historyRetentionDays)
        XCTAssertNil(config.audioHistoryRetentionDays)
        XCTAssertEqual(permissions(at: root), 0o700)
        XCTAssertEqual(permissions(at: url), 0o600)
    }

    func testWritesPrivateConfigAndRoundTripsRuntimeDefaults() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("nested/config.json")
        var config = Config()
        config.hotkey = "right-option"
        config.noteHotkey = "right-command"
        config.noteJournalPath = "/tmp/note-inbox.md"
        config.recognitionContext = "selected-text"
        config.model = "whisper-small.en"
        config.language = "en"
        config.mode = .notes
        config.journalPath = "/tmp/notes.md"
        config.cleanup = true
        config.automaticParagraphs = false
        config.spaceAfterPaste = false
        config.insertionMethod = .clipboard
        config.clipboardRestoreDelayMilliseconds = 1_500
        config.warmMicrophone = false
        config.historyRetentionDays = 30
        config.audioHistoryRetentionDays = 7
        config.inputDeviceUID = "studio"
        config.inputDeviceUIDs = ["studio", "built-in"]

        try config.write(to: url)

        XCTAssertEqual(Config.load(from: url), config)
        XCTAssertEqual(Config.load(from: url).savedInputDeviceUIDs, ["studio", "built-in"])
        XCTAssertEqual(permissions(at: url), 0o600)
        XCTAssertEqual(permissions(at: url.deletingLastPathComponent()), 0o700)
    }

    func testConfigRoundTripsPrivateLocalCommandSetting() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        var config = Config()
        config.deliveryCommand = "$HOME/bin/route-parrot-note --inbox"

        try config.write(to: url)

        XCTAssertEqual(
            Config.load(from: url).deliveryCommand,
            "$HOME/bin/route-parrot-note --inbox"
        )
        XCTAssertEqual(permissions(at: url), 0o600)
    }

    func testRuntimeDefaultsUseSavedValuesAndCLIOverrides() throws {
        var config = Config()
        config.hotkey = "right-option"
        config.noteHotkey = "right-command"
        config.noteJournalPath = "/tmp/note-inbox.md"
        config.model = "whisper-small.en"
        config.mode = .notes

        XCTAssertEqual(
            try RuntimeDefaults.resolve(
                config: config,
                hotkeyOverride: nil,
                modelOverride: nil,
                notes: false,
                dictation: false,
                recommendedModel: "whisper-base.en"
            ),
            RuntimeDefaults(
                hotkey: "right-option",
                noteHotkey: "right-command",
                noteJournalPath: "/tmp/note-inbox.md",
                recognitionContext: .off,
                model: "whisper-small.en",
                language: "auto",
                mode: .notes,
                journalPath: nil,
                deliveryCommand: nil,
                cleanup: false,
                automaticParagraphs: true,
                spaceAfterPaste: true,
                insertionMethod: .keystrokes,
                clipboardRestoreDelayMilliseconds: 1_000,
                warmMicrophone: true,
                historyRetentionDays: nil,
                audioHistoryRetentionDays: nil
            )
        )
        XCTAssertEqual(
            try RuntimeDefaults.resolve(
                config: config,
                hotkeyOverride: "end",
                modelOverride: "whisper-base.en",
                notes: false,
                dictation: true,
                recommendedModel: "ignored"
            ),
            RuntimeDefaults(
                hotkey: "end",
                noteHotkey: "right-command",
                noteJournalPath: "/tmp/note-inbox.md",
                recognitionContext: .off,
                model: "whisper-base.en",
                language: "auto",
                mode: .dictation,
                journalPath: nil,
                deliveryCommand: nil,
                cleanup: false,
                automaticParagraphs: true,
                spaceAfterPaste: true,
                insertionMethod: .keystrokes,
                clipboardRestoreDelayMilliseconds: 1_000,
                warmMicrophone: true,
                historyRetentionDays: nil,
                audioHistoryRetentionDays: nil
            )
        )
    }

    func testRuntimeDefaultsRecognitionContextIsOptInAndCanonicalized() throws {
        let builtIn = try RuntimeDefaults.resolve(
            config: Config(),
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(builtIn.recognitionContext, .off)

        var config = Config()
        config.recognitionContext = "selection"
        let saved = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(saved.recognitionContext, .selectedText)

        let overridden = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            recognitionContextOverride: "pasteboard",
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(overridden.recognitionContext, .clipboard)

        config.recognitionContext = "screen"
        XCTAssertThrowsError(try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        ))
    }

    func testRuntimeDefaultsResolveJournalAndPasteOverrides() throws {
        var config = Config()
        config.journalPath = "/tmp/saved.md"

        let saved = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(saved.journalPath, "/tmp/saved.md")

        let overridden = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            journalOverride: "/tmp/override.md",
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(overridden.journalPath, "/tmp/override.md")

        let pasted = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            paste: true,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertNil(pasted.journalPath)
        XCTAssertNil(pasted.deliveryCommand)

        XCTAssertThrowsError(try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            journalOverride: "/tmp/override.md",
            paste: true,
            recommendedModel: "whisper-base.en"
        ))
    }

    func testRuntimeDefaultsResolveExclusiveLocalCommandDelivery() throws {
        var config = Config()
        config.deliveryCommand = "/Users/me/bin/save-note"

        let saved = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(saved.deliveryCommand, "/Users/me/bin/save-note")
        XCTAssertNil(saved.journalPath)

        let journalOverride = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            journalOverride: "/tmp/note.md",
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(journalOverride.journalPath, "/tmp/note.md")
        XCTAssertNil(journalOverride.deliveryCommand)

        config.deliveryCommand = nil
        config.journalPath = "/tmp/saved.md"
        let commandOverride = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            commandOverride: "/Users/me/bin/save-note",
            recommendedModel: "whisper-base.en"
        )
        XCTAssertNil(commandOverride.journalPath)
        XCTAssertEqual(commandOverride.deliveryCommand, "/Users/me/bin/save-note")

        XCTAssertThrowsError(try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            journalOverride: "/tmp/override.md",
            commandOverride: "/Users/me/bin/save-note",
            recommendedModel: "whisper-base.en"
        ))

        config.deliveryCommand = "/Users/me/bin/save-note"
        XCTAssertThrowsError(try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        ))
    }

    func testRuntimeDefaultsResolveSavedAndOneRunCleanup() throws {
        var config = Config()
        config.cleanup = true

        let saved = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertTrue(saved.cleanup)

        let overridden = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            cleanupOverride: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertFalse(overridden.cleanup)
    }

    func testRuntimeDefaultsEnableNoteParagraphsByDefaultAndAllowOverrides() throws {
        var config = Config()
        let builtIn = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertTrue(builtIn.automaticParagraphs)

        config.automaticParagraphs = false
        let saved = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertFalse(saved.automaticParagraphs)

        let overridden = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            automaticParagraphsOverride: true,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertTrue(overridden.automaticParagraphs)
    }

    func testRuntimeDefaultsAddPasteSpaceByDefaultAndAllowOverrides() throws {
        var config = Config()
        let builtIn = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertTrue(builtIn.spaceAfterPaste)

        config.spaceAfterPaste = false
        let saved = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertFalse(saved.spaceAfterPaste)

        let overridden = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            spaceAfterPasteOverride: true,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertTrue(overridden.spaceAfterPaste)
    }

    func testRuntimeDefaultsKeepClipboardInsertionExplicitAndBounded() throws {
        let builtIn = try RuntimeDefaults.resolve(
            config: Config(),
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(builtIn.insertionMethod, .keystrokes)
        XCTAssertEqual(builtIn.clipboardRestoreDelayMilliseconds, 1_000)

        var config = Config()
        config.insertionMethod = .clipboard
        config.clipboardRestoreDelayMilliseconds = 2_000
        let saved = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(saved.insertionMethod, .clipboard)
        XCTAssertEqual(saved.clipboardRestoreDelayMilliseconds, 2_000)

        let overridden = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            insertionMethodOverride: .keystrokes,
            clipboardRestoreDelayMillisecondsOverride: 500,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(overridden.insertionMethod, .keystrokes)
        XCTAssertEqual(overridden.clipboardRestoreDelayMilliseconds, 500)

        config.clipboardRestoreDelayMilliseconds = 5_001
        XCTAssertThrowsError(try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        ))
    }

    func testRuntimeDefaultsKeepMicWarmByDefaultAndAllowOverrides() throws {
        var config = Config()
        let builtIn = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertTrue(builtIn.warmMicrophone)

        config.warmMicrophone = false
        let saved = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertFalse(saved.warmMicrophone)

        let overridden = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            warmMicrophoneOverride: true,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertTrue(overridden.warmMicrophone)
    }

    func testRuntimeDefaultsValidateOptionalHistoryRetention() throws {
        var config = Config()
        XCTAssertNil(try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        ).historyRetentionDays)

        config.historyRetentionDays = 30
        XCTAssertEqual(try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        ).historyRetentionDays, 30)

        config.historyRetentionDays = 0
        XCTAssertThrowsError(try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        ))

        config.historyRetentionDays = nil
        config.audioHistoryRetentionDays = 7
        XCTAssertEqual(try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        ).audioHistoryRetentionDays, 7)

        config.historyRetentionDays = 3
        XCTAssertEqual(try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        ).audioHistoryRetentionDays, 3)

        config.historyRetentionDays = nil
        config.audioHistoryRetentionDays = 0
        XCTAssertThrowsError(try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        ))
    }

    func testRuntimeDefaultsRejectConflictingModeOverrides() {
        XCTAssertThrowsError(
            try RuntimeDefaults.resolve(
                config: Config(),
                hotkeyOverride: nil,
                modelOverride: nil,
                notes: true,
                dictation: true,
                recommendedModel: "whisper-base.en"
            )
        )
    }

    func testRuntimeDefaultsResolveAndValidateDedicatedNoteHotkey() throws {
        var config = Config()
        config.hotkey = "fn"
        config.noteHotkey = "right-option"
        config.noteJournalPath = "/tmp/note-inbox.md"

        let saved = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(saved.noteHotkey, "right-option")
        XCTAssertEqual(saved.noteJournalPath, "/tmp/note-inbox.md")

        let overridden = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            noteHotkeyOverride: "end",
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(overridden.noteHotkey, "end")

        let journalOverridden = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            noteJournalOverride: "/tmp/quick-notes.md",
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(journalOverridden.noteJournalPath, "/tmp/quick-notes.md")

        let journalDisabled = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            disableNoteJournal: true,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertNil(journalDisabled.noteJournalPath)

        let disabled = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            disableNoteHotkey: true,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertNil(disabled.noteHotkey)

        config.noteHotkey = "globe"
        XCTAssertThrowsError(try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        ))

        config.hotkey = "end"
        config.noteHotkey = "keycode:119"
        XCTAssertThrowsError(try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        ))

        let run = try XCTUnwrap(try Run.parseAsRoot([
            "--hotkey", "fn", "--note-hotkey", "right-option",
            "--note-journal", "/tmp/note-inbox.md",
        ]) as? Run)
        XCTAssertEqual(run.noteHotkey, "right-option")
        XCTAssertEqual(run.noteJournal, "/tmp/note-inbox.md")
        XCTAssertTrue(try XCTUnwrap(
            try Run.parseAsRoot(["--no-note-hotkey"]) as? Run
        ).noNoteHotkey)
        XCTAssertThrowsError(try Run.parseAsRoot([
            "--note-hotkey", "end", "--no-note-hotkey",
        ]))
        XCTAssertThrowsError(try Run.parseAsRoot([
            "--note-journal", "/tmp/inbox.md", "--no-note-journal",
        ]))
        XCTAssertThrowsError(try RuntimeDefaults.resolve(
            config: Config(),
            hotkeyOverride: nil,
            noteJournalOverride: "/tmp/inbox.md",
            modelOverride: nil,
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        ))
    }

    func testSettingsCommandsParseAndValidateValues() throws {
        XCTAssertTrue(try Settings.parseAsRoot([]) is Settings.Show)
        let set = try XCTUnwrap(
            try Settings.parseAsRoot([
                "set", "--hotkey", "ralt", "--model", "whisper-small.en",
                "--note-hotkey", "right-command",
                "--note-journal", "/tmp/note-inbox.md",
                "--context", "selection",
                "--language", "English", "--mode", "notes",
                "--journal", "/tmp/inbox.md", "--cleanup", "--auto-paragraphs",
                "--no-space-after-paste", "--clipboard-paste",
                "--clipboard-restore-delay-ms", "1500", "--cold-mic",
                "--history-retention-days", "30", "--audio-history-days", "7",
            ]) as? Settings.Set
        )
        XCTAssertEqual(set.hotkey, "ralt")
        XCTAssertEqual(set.noteHotkey, "right-command")
        XCTAssertEqual(set.noteJournal, "/tmp/note-inbox.md")
        XCTAssertEqual(set.recognitionContext, "selection")
        XCTAssertEqual(set.model, "whisper-small.en")
        XCTAssertEqual(set.language, "English")
        XCTAssertEqual(set.mode, "notes")
        XCTAssertEqual(set.journal, "/tmp/inbox.md")
        XCTAssertTrue(set.cleanup)
        XCTAssertTrue(set.automaticParagraphs)
        XCTAssertTrue(set.noSpaceAfterPaste)
        XCTAssertTrue(set.clipboardPaste)
        XCTAssertEqual(set.clipboardRestoreDelayMilliseconds, 1_500)
        XCTAssertTrue(set.coldMicrophone)
        XCTAssertEqual(set.historyRetentionDays, 30)
        XCTAssertEqual(set.audioHistoryRetentionDays, 7)
        XCTAssertTrue(try Settings.parseAsRoot(["reset"]) is Settings.Reset)

        let paste = try XCTUnwrap(
            try Settings.parseAsRoot(["set", "--paste"]) as? Settings.Set
        )
        XCTAssertTrue(paste.paste)
        let command = try XCTUnwrap(
            try Settings.parseAsRoot([
                "set", "--command", "/Users/me/bin/save-note --tag inbox",
            ]) as? Settings.Set
        )
        XCTAssertEqual(command.command, "/Users/me/bin/save-note --tag inbox")

        XCTAssertThrowsError(try Settings.parseAsRoot(["set"]))
        XCTAssertThrowsError(try Settings.parseAsRoot(["set", "--hotkey", "space"]))
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--note-hotkey", "space",
        ]))
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--hotkey", "fn", "--note-hotkey", "globe",
        ]))
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--note-hotkey", "end", "--no-note-hotkey",
        ]))
        XCTAssertTrue(try Settings.parseAsRoot([
            "set", "--no-note-hotkey",
        ]) is Settings.Set)
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--note-journal", "/tmp/inbox.md", "--no-note-journal",
        ]))
        XCTAssertTrue(try Settings.parseAsRoot([
            "set", "--no-note-journal",
        ]) is Settings.Set)
        XCTAssertThrowsError(try Settings.parseAsRoot(["set", "--model", "imaginary"]))
        XCTAssertThrowsError(try Settings.parseAsRoot(["set", "--context", "screen"]))
        XCTAssertThrowsError(try Settings.parseAsRoot(["set", "--language", "Klingon"]))
        XCTAssertThrowsError(try Settings.parseAsRoot(["set", "--mode", "email"]))
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--journal", "/tmp/inbox.md", "--paste",
        ]))
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--journal", "/tmp/inbox.md", "--command", "/usr/bin/true",
        ]))
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--command", "/usr/bin/true", "--paste",
        ]))
        XCTAssertThrowsError(try Settings.parseAsRoot(["set", "--command", "   "]))
        XCTAssertThrowsError(try Settings.parseAsRoot(["set", "--journal", "/tmp/inbox.txt"]))
        XCTAssertThrowsError(try Settings.parseAsRoot(["set", "--cleanup", "--no-cleanup"]))
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--auto-paragraphs", "--no-auto-paragraphs",
        ]))
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--space-after-paste", "--no-space-after-paste",
        ]))
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--clipboard-paste", "--keystroke-paste",
        ]))
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--clipboard-restore-delay-ms", "99",
        ]))
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--warm-mic", "--cold-mic",
        ]))
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--history-retention-days", "0",
        ]))
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--history-retention-days", "30", "--keep-history-forever",
        ]))
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--audio-history-days", "0",
        ]))
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--audio-history-days", "7", "--no-audio-history",
        ]))
        XCTAssertTrue(try Settings.parseAsRoot([
            "set", "--no-audio-history",
        ]) is Settings.Set)
    }

    func testRuntimeDefaultsCanonicalizeSavedAndOneRunLanguages() throws {
        var config = Config()
        config.language = "Spanish"
        let saved = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: "whisper-base",
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(saved.language, "es")

        let overridden = try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: "whisper-base",
            languageOverride: "pt-BR",
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        )
        XCTAssertEqual(overridden.language, "pt")

        XCTAssertThrowsError(try RuntimeDefaults.resolve(
            config: config,
            hotkeyOverride: nil,
            modelOverride: nil,
            languageOverride: "Klingon",
            notes: false,
            dictation: false,
            recommendedModel: "whisper-base.en"
        ))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-config-tests-\(UUID().uuidString)")
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }
}

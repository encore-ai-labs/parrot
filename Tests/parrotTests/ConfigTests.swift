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
        XCTAssertEqual(config.setupCompleted, true)
        XCTAssertNil(config.hotkey)
        XCTAssertNil(config.model)
        XCTAssertNil(config.mode)
        XCTAssertNil(config.appRules)
        XCTAssertNil(config.journalPath)
        XCTAssertEqual(permissions(at: root), 0o700)
        XCTAssertEqual(permissions(at: url), 0o600)
    }

    func testWritesPrivateConfigAndRoundTripsRuntimeDefaults() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("nested/config.json")
        var config = Config()
        config.hotkey = "right-option"
        config.model = "whisper-small.en"
        config.mode = .notes
        config.journalPath = "/tmp/notes.md"

        try config.write(to: url)

        XCTAssertEqual(Config.load(from: url), config)
        XCTAssertEqual(permissions(at: url), 0o600)
        XCTAssertEqual(permissions(at: url.deletingLastPathComponent()), 0o700)
    }

    func testRuntimeDefaultsUseSavedValuesAndCLIOverrides() throws {
        var config = Config()
        config.hotkey = "right-option"
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
                model: "whisper-small.en",
                mode: .notes,
                journalPath: nil
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
                model: "whisper-base.en",
                mode: .dictation,
                journalPath: nil
            )
        )
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

    func testSettingsCommandsParseAndValidateValues() throws {
        XCTAssertTrue(try Settings.parseAsRoot([]) is Settings.Show)
        let set = try XCTUnwrap(
            try Settings.parseAsRoot([
                "set", "--hotkey", "ralt", "--model", "whisper-small.en",
                "--mode", "notes", "--journal", "/tmp/inbox.md",
            ]) as? Settings.Set
        )
        XCTAssertEqual(set.hotkey, "ralt")
        XCTAssertEqual(set.model, "whisper-small.en")
        XCTAssertEqual(set.mode, "notes")
        XCTAssertEqual(set.journal, "/tmp/inbox.md")
        XCTAssertTrue(try Settings.parseAsRoot(["reset"]) is Settings.Reset)

        let paste = try XCTUnwrap(
            try Settings.parseAsRoot(["set", "--paste"]) as? Settings.Set
        )
        XCTAssertTrue(paste.paste)

        XCTAssertThrowsError(try Settings.parseAsRoot(["set"]))
        XCTAssertThrowsError(try Settings.parseAsRoot(["set", "--hotkey", "space"]))
        XCTAssertThrowsError(try Settings.parseAsRoot(["set", "--model", "imaginary"]))
        XCTAssertThrowsError(try Settings.parseAsRoot(["set", "--mode", "email"]))
        XCTAssertThrowsError(try Settings.parseAsRoot([
            "set", "--journal", "/tmp/inbox.md", "--paste",
        ]))
        XCTAssertThrowsError(try Settings.parseAsRoot(["set", "--journal", "/tmp/inbox.txt"]))
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

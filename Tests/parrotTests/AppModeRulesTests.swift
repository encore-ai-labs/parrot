import Foundation
import XCTest

@testable import parrot

final class AppModeRulesTests: XCTestCase {
    func testRuleOverridesFallbackAndRevertsForAnotherApp() {
        let controller = DictationModeController(
            fallbackMode: .dictation,
            rules: [AppModeRule(
                bundleIdentifier: "com.apple.Notes",
                applicationName: "Notes",
                mode: .notes
            )]
        )

        XCTAssertEqual(
            controller.selection(frontmostBundleIdentifier: "COM.APPLE.NOTES"),
            AppModeSelection(mode: .notes, automaticApplicationName: "Notes")
        )
        XCTAssertEqual(
            controller.selection(frontmostBundleIdentifier: "com.apple.TextEdit"),
            AppModeSelection(mode: .dictation, automaticApplicationName: nil)
        )
    }

    func testExplicitRunModeDisablesAutomaticRulesButMenuCanChangeFallback() {
        let controller = DictationModeController(
            fallbackMode: .notes,
            rules: [AppModeRule(
                bundleIdentifier: "com.apple.TextEdit",
                applicationName: "TextEdit",
                mode: .dictation
            )],
            automaticRulesEnabled: false
        )

        XCTAssertEqual(
            controller.selection(frontmostBundleIdentifier: "com.apple.TextEdit").mode,
            .notes
        )
        controller.setFallbackMode(.dictation)
        XCTAssertEqual(controller.selection(frontmostBundleIdentifier: nil).mode, .dictation)
    }

    func testConfigUpsertsSortsAndRemovesRules() {
        var config = Config()
        config.setAppRule(AppModeRule(
            bundleIdentifier: "com.apple.TextEdit",
            applicationName: "TextEdit",
            mode: .dictation
        ))
        config.setAppRule(AppModeRule(
            bundleIdentifier: "com.apple.Notes",
            applicationName: "Notes",
            mode: .notes
        ))
        config.setAppRule(AppModeRule(
            bundleIdentifier: "COM.APPLE.NOTES",
            applicationName: "Notes",
            mode: .dictation
        ))

        XCTAssertEqual(config.savedAppRules.count, 2)
        XCTAssertEqual(config.savedAppRules.first?.bundleIdentifier, "COM.APPLE.NOTES")
        XCTAssertEqual(config.savedAppRules.first?.mode, .dictation)
        XCTAssertEqual(config.removeAppRule(matching: "notes")?.mode, .dictation)
        XCTAssertEqual(config.savedAppRules.map(\.bundleIdentifier), ["com.apple.TextEdit"])
        XCTAssertNil(config.removeAppRule(matching: "missing"))
    }

    func testRulesHotReloadAfterConfigFileChanges() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        var config = Config()
        config.setAppRule(AppModeRule(
            bundleIdentifier: "com.example.Editor",
            applicationName: "Editor",
            mode: .notes
        ))
        try config.write(to: url)
        let controller = DictationModeController(
            fallbackMode: .dictation,
            rules: config.savedAppRules,
            reloadRulesFrom: url
        )
        XCTAssertEqual(
            controller.selection(frontmostBundleIdentifier: "com.example.Editor").mode,
            .notes
        )

        config.setAppRule(AppModeRule(
            bundleIdentifier: "com.example.Editor",
            applicationName: "Editor",
            mode: .dictation
        ))
        try config.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 5)],
            ofItemAtPath: url.path
        )

        XCTAssertEqual(
            controller.selection(frontmostBundleIdentifier: "com.example.Editor").mode,
            .dictation
        )
    }

    func testAppCommandsAndBundleIdentifiersValidate() throws {
        XCTAssertTrue(try Apps.parseAsRoot([]) is Apps.List)
        let add = try XCTUnwrap(
            try Apps.parseAsRoot(["add", "com.apple.Notes", "--mode", "notes"])
                as? Apps.Add
        )
        XCTAssertEqual(add.application, "com.apple.Notes")
        XCTAssertEqual(add.mode, "notes")
        XCTAssertTrue(try Apps.parseAsRoot(["remove", "Notes"]) is Apps.Remove)
        XCTAssertTrue(try Apps.parseAsRoot(["clear"]) is Apps.Clear)
        XCTAssertTrue(try Apps.parseAsRoot(["current"]) is Apps.Current)
        XCTAssertThrowsError(
            try Apps.parseAsRoot(["add", "com.apple.Notes", "--mode", "email"])
        )
        XCTAssertTrue(ApplicationIdentity.looksLikeBundleIdentifier("com.example.Editor-2"))
        XCTAssertFalse(ApplicationIdentity.looksLikeBundleIdentifier("Notes"))
        XCTAssertFalse(ApplicationIdentity.looksLikeBundleIdentifier("com.example bad"))
    }

    func testRuleResolutionPerformance() {
        let rules = (0..<100).map { index in
            AppModeRule(
                bundleIdentifier: "com.example.app\(index)",
                applicationName: "App \(index)",
                mode: index.isMultiple(of: 2) ? .notes : .dictation
            )
        }
        let controller = DictationModeController(fallbackMode: .dictation, rules: rules)
        var selection = AppModeSelection(mode: .dictation, automaticApplicationName: nil)
        measure {
            for _ in 0..<10_000 {
                selection = controller.selection(
                    frontmostBundleIdentifier: "com.example.app99"
                )
            }
        }
        XCTAssertEqual(selection.mode, .dictation)
    }

    func testHotReloadCheckPerformance() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        var config = Config()
        config.appRules = (0..<100).map { index in
            AppModeRule(
                bundleIdentifier: "com.example.app\(index)",
                applicationName: "App \(index)",
                mode: index.isMultiple(of: 2) ? .notes : .dictation
            )
        }
        try config.write(to: url)
        let controller = DictationModeController(
            fallbackMode: .dictation,
            rules: config.savedAppRules,
            reloadRulesFrom: url
        )
        var selection = AppModeSelection(mode: .dictation, automaticApplicationName: nil)
        measure {
            for _ in 0..<1_000 {
                selection = controller.selection(
                    frontmostBundleIdentifier: "com.example.app98"
                )
            }
        }
        XCTAssertEqual(selection.mode, .notes)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-app-mode-tests-\(UUID().uuidString)")
    }
}

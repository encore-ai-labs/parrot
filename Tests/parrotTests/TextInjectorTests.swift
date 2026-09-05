import AppKit
import XCTest

@testable import parrot

final class TextInjectorTests: XCTestCase {
    func testAddsOneDeliveryOnlyBoundarySpace() {
        XCTAssertEqual(
            TextInjector.preparedText("First thought.", appendSpace: true),
            "First thought. "
        )
        XCTAssertEqual(
            TextInjector.preparedText("- [ ] Follow up", appendSpace: true),
            "- [ ] Follow up "
        )
    }

    func testDoesNotDoubleExistingWhitespace() {
        for text in ["Already spaced ", "Line break\n", "Tabbed\t"] {
            XCTAssertEqual(TextInjector.preparedText(text, appendSpace: true), text)
        }
    }

    func testExactModeAndEmptyTextRemainByteStable() {
        let text = "Exact\nMarkdown"
        XCTAssertEqual(TextInjector.preparedText(text, appendSpace: false), text)
        XCTAssertEqual(TextInjector.preparedText("", appendSpace: true), "")
    }

    func testRunFlagsParseAndConflict() throws {
        let enabled = try XCTUnwrap(
            try Run.parseAsRoot(["--space-after-paste"]) as? Run
        )
        XCTAssertTrue(enabled.spaceAfterPaste)

        let disabled = try XCTUnwrap(
            try Run.parseAsRoot(["--no-space-after-paste"]) as? Run
        )
        XCTAssertTrue(disabled.noSpaceAfterPaste)

        XCTAssertThrowsError(try Run.parseAsRoot([
            "--space-after-paste", "--no-space-after-paste",
        ]))

        let clipboard = try XCTUnwrap(
            try Run.parseAsRoot([
                "--clipboard-paste", "--clipboard-restore-delay-ms", "1500",
            ]) as? Run
        )
        XCTAssertTrue(clipboard.clipboardPaste)
        XCTAssertEqual(clipboard.clipboardRestoreDelayMilliseconds, 1_500)
        XCTAssertThrowsError(try Run.parseAsRoot([
            "--clipboard-paste", "--keystroke-paste",
        ]))
        XCTAssertThrowsError(try Run.parseAsRoot([
            "--clipboard-restore-delay-ms", "5001",
        ]))
    }

    func testUnicodeChunksNeverSplitSurrogatePairs() {
        let text = String(repeating: "a", count: 19) + "🦜" + " notes 𐐷 café"
        let chunks = TextInjector.utf16Chunks(text)

        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(
            String(decoding: chunks.flatMap { $0 }, as: UTF16.self),
            text
        )
        for chunk in chunks {
            if let first = chunk.first {
                XCTAssertFalse((0xDC00...0xDFFF).contains(first))
            }
            if let last = chunk.last {
                XCTAssertFalse((0xD800...0xDBFF).contains(last))
            }
        }
    }

    @MainActor
    func testLastTranscriptStorePreservesExactDeliveredText() {
        let store = LastTranscriptStore()
        store.update("  # Note\n\nBody\n")
        XCTAssertEqual(store.text, "  # Note\n\nBody\n")
        store.update(" \n\t")
        XCTAssertEqual(store.text, "  # Note\n\nBody\n")
    }

    @MainActor
    func testClipboardInsertionRestoresEveryOriginalPasteboardType() throws {
        let pasteboard = temporaryPasteboard()
        defer { pasteboard.clearContents() }
        let original = NSPasteboardItem()
        original.setString("original text", forType: .string)
        original.setData(Data([0x7B, 0x5C, 0x72, 0x74, 0x66]), forType: .rtf)
        XCTAssertTrue(pasteboard.writeObjects([original]))
        var pasteShortcutCount = 0
        var scheduledDelay: TimeInterval?
        var scheduledWork: (@MainActor @Sendable () -> Void)?
        let coordinator = ClipboardPasteCoordinator(
            pasteboard: pasteboard,
            postPasteShortcut: { pasteShortcutCount += 1 },
            schedule: { delay, work in
                scheduledDelay = delay
                scheduledWork = work
            }
        )

        XCTAssertTrue(coordinator.paste("new transcript", restoreAfter: 1.25))
        XCTAssertEqual(pasteboard.string(forType: .string), "new transcript")
        XCTAssertEqual(pasteShortcutCount, 1)
        XCTAssertEqual(try XCTUnwrap(scheduledDelay), 1.25, accuracy: 0.0001)

        try XCTUnwrap(scheduledWork)()
        XCTAssertEqual(pasteboard.string(forType: .string), "original text")
        XCTAssertEqual(pasteboard.data(forType: .rtf), Data([0x7B, 0x5C, 0x72, 0x74, 0x66]))
    }

    @MainActor
    func testClipboardInsertionNeverOverwritesANewerUserCopy() throws {
        let pasteboard = temporaryPasteboard()
        defer { pasteboard.clearContents() }
        pasteboard.setString("original", forType: .string)
        var scheduledWork: (@MainActor @Sendable () -> Void)?
        let coordinator = ClipboardPasteCoordinator(
            pasteboard: pasteboard,
            postPasteShortcut: {},
            schedule: { _, work in scheduledWork = work }
        )

        XCTAssertTrue(coordinator.paste("transcript", restoreAfter: 1))
        pasteboard.clearContents()
        pasteboard.setString("user copied this", forType: .string)
        try XCTUnwrap(scheduledWork)()

        XCTAssertEqual(pasteboard.string(forType: .string), "user copied this")
        XCTAssertTrue(coordinator.paste("another transcript", restoreAfter: 1))
        try XCTUnwrap(scheduledWork)()
        XCTAssertEqual(pasteboard.string(forType: .string), "user copied this")
    }

    @MainActor
    func testOverlappingClipboardInsertionsRestoreTheTrueOriginal() throws {
        let pasteboard = temporaryPasteboard()
        defer { pasteboard.clearContents() }
        pasteboard.setString("original", forType: .string)
        var scheduledWork: [@MainActor @Sendable () -> Void] = []
        let coordinator = ClipboardPasteCoordinator(
            pasteboard: pasteboard,
            postPasteShortcut: {},
            schedule: { _, work in scheduledWork.append(work) }
        )

        XCTAssertTrue(coordinator.paste("first", restoreAfter: 1))
        XCTAssertTrue(coordinator.paste("second", restoreAfter: 1))
        XCTAssertEqual(pasteboard.string(forType: .string), "second")
        XCTAssertEqual(scheduledWork.count, 2)
        scheduledWork[0]()
        XCTAssertEqual(pasteboard.string(forType: .string), "second")
        scheduledWork[1]()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    @MainActor
    func testOversizedClipboardSnapshotRefusesToReplaceOriginal() {
        let pasteboard = temporaryPasteboard()
        defer { pasteboard.clearContents() }
        pasteboard.setData(Data(repeating: 0xAA, count: 9), forType: .png)
        var posted = false
        let coordinator = ClipboardPasteCoordinator(
            pasteboard: pasteboard,
            maximumSnapshotBytes: 8,
            postPasteShortcut: { posted = true },
            schedule: { _, _ in XCTFail("an unavailable paste must not schedule restoration") }
        )

        XCTAssertFalse(coordinator.paste("transcript", restoreAfter: 1))
        XCTAssertEqual(pasteboard.data(forType: .png), Data(repeating: 0xAA, count: 9))
        XCTAssertFalse(posted)
    }

    @MainActor
    func testShutdownRestorePreservesOriginalUnlessUserCopied() {
        let pasteboard = temporaryPasteboard()
        defer { pasteboard.clearContents() }
        pasteboard.setString("original", forType: .string)
        let coordinator = ClipboardPasteCoordinator(
            pasteboard: pasteboard,
            postPasteShortcut: {},
            schedule: { _, _ in }
        )

        XCTAssertTrue(coordinator.paste("transcript", restoreAfter: 5))
        coordinator.restorePendingIfUnchanged()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")

        XCTAssertTrue(coordinator.paste("second", restoreAfter: 5))
        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)
        coordinator.restorePendingIfUnchanged()
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    func testBoundaryPreparationCostStaysNegligibleForLongNotes() {
        let input = String(repeating: "A representative dictated sentence. ", count: 250)
            .trimmingCharacters(in: .whitespaces)
        var output = ""
        measure {
            for _ in 0..<1_000 {
                output = TextInjector.preparedText(input, appendSpace: true)
            }
        }
        XCTAssertEqual(output.count, input.count + 1)
    }

    func testUnicodeChunkPreparationCostStaysBoundedForLongNotes() {
        let input = String(repeating: "Local notes 🦜 stay private. ", count: 350)
        var chunks: [[UniChar]] = []
        measure {
            for _ in 0..<100 {
                chunks = TextInjector.utf16Chunks(input)
            }
        }
        XCTAssertEqual(String(decoding: chunks.flatMap { $0 }, as: UTF16.self), input)
    }

    @MainActor
    private func temporaryPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("parrot-tests-\(UUID().uuidString)"))
    }
}

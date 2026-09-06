import AppKit
import CoreGraphics
import Foundation

enum TextInsertionMethod: String, Codable {
    case keystrokes
    case clipboard
}

struct PasteboardSnapshot {
    static let maximumBytes = 32 * 1_024 * 1_024
    let items: [[NSPasteboard.PasteboardType: Data]]

    @MainActor
    init?(pasteboard: NSPasteboard, maximumBytes: Int = Self.maximumBytes) {
        var totalBytes = 0
        var captured: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var fields: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                guard data.count <= maximumBytes - totalBytes else { return nil }
                totalBytes += data.count
                fields[type] = data
            }
            captured.append(fields)
        }
        items = captured
    }

    @MainActor
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { fields -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in fields {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }
}

/// Coordinates temporary clipboard use without overwriting a clipboard value
/// the user copies while the target application is still consuming Command-V.
@MainActor
final class ClipboardPasteCoordinator {
    typealias Scheduler = (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

    private let pasteboard: NSPasteboard
    private let postPasteShortcut: () -> Void
    private let schedule: Scheduler
    private let maximumSnapshotBytes: Int
    private var generation = 0
    private var pendingOriginal: PasteboardSnapshot?
    private var expectedChangeCount: Int?

    init(
        pasteboard: NSPasteboard,
        maximumSnapshotBytes: Int = PasteboardSnapshot.maximumBytes,
        postPasteShortcut: @escaping () -> Void,
        schedule: @escaping Scheduler
    ) {
        self.pasteboard = pasteboard
        self.maximumSnapshotBytes = max(0, maximumSnapshotBytes)
        self.postPasteShortcut = postPasteShortcut
        self.schedule = schedule
    }

    @discardableResult
    func paste(_ text: String, restoreAfter delay: TimeInterval) -> Bool {
        let original: PasteboardSnapshot
        if let pendingOriginal,
           let expectedChangeCount,
           pasteboard.changeCount == expectedChangeCount {
            // A second Parrot insertion arrived before the first restore.
            // Preserve the user's true original clipboard, not Parrot's text.
            original = pendingOriginal
        } else {
            guard let snapshot = PasteboardSnapshot(
                pasteboard: pasteboard,
                maximumBytes: maximumSnapshotBytes
            ) else { return false }
            original = snapshot
        }

        generation += 1
        let thisGeneration = generation
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            original.restore(to: pasteboard)
            pendingOriginal = nil
            expectedChangeCount = nil
            return false
        }
        pendingOriginal = original
        expectedChangeCount = pasteboard.changeCount
        let insertedChangeCount = pasteboard.changeCount
        postPasteShortcut()

        schedule(max(0, delay)) { [weak self] in
            guard let self, self.generation == thisGeneration else { return }
            guard self.expectedChangeCount == insertedChangeCount,
                  self.pasteboard.changeCount == insertedChangeCount,
                  let original = self.pendingOriginal else {
                // The user copied something new. It is authoritative, and the
                // old snapshot should not remain resident in Parrot's memory.
                self.pendingOriginal = nil
                self.expectedChangeCount = nil
                return
            }
            original.restore(to: self.pasteboard)
            self.pendingOriginal = nil
            self.expectedChangeCount = nil
        }
        return true
    }

    func restorePendingIfUnchanged() {
        generation += 1
        guard let expectedChangeCount,
              pasteboard.changeCount == expectedChangeCount,
              let original = pendingOriginal else {
            pendingOriginal = nil
            self.expectedChangeCount = nil
            return
        }
        original.restore(to: pasteboard)
        pendingOriginal = nil
        self.expectedChangeCount = nil
    }
}

/// Inserts text at the current cursor either with privacy-first Unicode events
/// or an explicitly selected compatibility clipboard path.
enum TextInjector {
    static let defaultClipboardRestoreDelayMilliseconds = 1_000
    static let validClipboardRestoreDelayMilliseconds = 100...5_000

    @MainActor private static var clipboardCoordinator: ClipboardPasteCoordinator?

    /// Inject the given text at the current cursor location.
    /// Splits long strings into chunks because the underlying API has a
    /// per-event character limit (~20 chars).
    @MainActor
    static func inject(
        _ text: String,
        appendSpace: Bool,
        smartInsertion: Bool = true,
        context: CursorInsertionSnapshot? = nil,
        method: TextInsertionMethod = .keystrokes,
        clipboardRestoreDelayMilliseconds: Int = defaultClipboardRestoreDelayMilliseconds
    ) {
        let boundary = smartInsertion
            ? CursorInsertionContextCapture.boundaryForCurrentApplication(context)
            : nil
        let text = preparedText(
            text,
            appendSpace: appendSpace,
            smartBoundary: boundary
        )
        guard !text.isEmpty else { return }

        if method == .clipboard {
            if compatibilityClipboardCoordinator().paste(
                text,
                restoreAfter: TimeInterval(clipboardRestoreDelayMilliseconds) / 1_000
            ) {
                return
            }
            FileHandle.standardError.write(Data(
                "clipboard insertion unavailable; used privacy-first keystrokes\n".utf8
            ))
        }

        for var chunk in utf16Chunks(text) {
            postChunk(&chunk)
        }
    }

    @MainActor
    static func restoreClipboardIfNeeded() {
        clipboardCoordinator?.restorePendingIfUnchanged()
    }

    /// Keeps delivery-only whitespace out of history and other output paths.
    /// Existing whitespace is authoritative and never doubled.
    static func preparedText(
        _ text: String,
        appendSpace: Bool,
        smartBoundary: CursorTextBoundary? = nil
    ) -> String {
        if let smartBoundary {
            return CursorInsertionFormatter.prepare(
                text,
                appendSpace: appendSpace,
                boundary: smartBoundary
            )
        }
        guard appendSpace,
              let last = text.unicodeScalars.last,
              !CharacterSet.whitespacesAndNewlines.contains(last)
        else { return text }
        return text + " "
    }

    /// Keep each synthesized event small without ever dividing a UTF-16
    /// surrogate pair. Splitting arbitrary code units can corrupt emoji and
    /// supplementary-plane writing-system characters at a chunk boundary.
    static func utf16Chunks(_ text: String, maximumUnits: Int = 20) -> [[UniChar]] {
        let maximumUnits = max(2, maximumUnits)
        var chunks: [[UniChar]] = []
        var chunk: [UniChar] = []
        chunk.reserveCapacity(maximumUnits)
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if !chunk.isEmpty, chunk.count + units.count > maximumUnits {
                chunks.append(chunk)
                chunk = []
                chunk.reserveCapacity(maximumUnits)
            }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    private static func postChunk(_ chunk: inout [UniChar]) {
        let length = chunk.count
        guard length > 0 else { return }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: length, unicodeString: &chunk)
        up?.post(tap: .cgSessionEventTap)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cgSessionEventTap)
    }

    @MainActor
    private static func compatibilityClipboardCoordinator() -> ClipboardPasteCoordinator {
        if let clipboardCoordinator { return clipboardCoordinator }
        let coordinator = ClipboardPasteCoordinator(
            pasteboard: .general,
            postPasteShortcut: postCommandV,
            schedule: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        )
        clipboardCoordinator = coordinator
        return coordinator
    }
}

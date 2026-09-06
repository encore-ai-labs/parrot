import AppKit
import Foundation
import SwiftUI

/// Keeps the latest meter sample while allowing at most one scheduled UI hop.
/// Audio buffers can arrive faster than the main actor renders; stale levels
/// have no value, so bounded latest-wins delivery avoids an unbounded task tail.
final class AudioLevelCoalescer: @unchecked Sendable {
    typealias Scheduler = (DispatchWorkItem) -> Void

    private let lock = NSLock()
    private let schedule: Scheduler
    private let deliver: (Float) -> Void
    private var latest: Float?
    private var deliveryPending = false

    init(
        schedule: @escaping Scheduler,
        deliver: @escaping (Float) -> Void
    ) {
        self.schedule = schedule
        self.deliver = deliver
    }

    func submit(_ level: Float) {
        lock.lock()
        latest = level
        guard !deliveryPending else {
            lock.unlock()
            return
        }
        deliveryPending = true
        lock.unlock()

        schedule(DispatchWorkItem { [weak self] in
            self?.drain()
        })
    }

    private func drain() {
        lock.lock()
        let level = latest
        latest = nil
        deliveryPending = false
        lock.unlock()

        if let level { deliver(level) }
    }
}

/// Borderless, click-through pill near the bottom of the active screen.
/// Driven by the daemon's hotkey + transcription lifecycle.
@MainActor
final class RecordingOverlay {
    enum State: Equatable {
        case hidden
        case recording
        case transcribing
    }

    private var window: NSPanel?
    private let model: OverlayModel
    private let levelCoalescer: AudioLevelCoalescer
    private var hideWorkItem: DispatchWorkItem?
    private var previewGate = RealtimePreviewGate()
    private static let compactSize = NSSize(width: 96, height: 44)
    private static let previewSize = NSSize(width: 420, height: 52)

    init() {
        let model = OverlayModel()
        self.model = model
        levelCoalescer = AudioLevelCoalescer(
            schedule: { DispatchQueue.main.async(execute: $0) },
            deliver: { level in
                MainActor.assumeIsolated {
                    model.pushLevel(level)
                }
            }
        )
    }

    func show(_ state: State, previewSessionID: UUID? = nil) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        ensureWindow()
        if state == .recording {
            previewGate.begin(sessionID: previewSessionID)
            model.resetLevels()
            model.partialText = ""
            window?.setContentSize(Self.compactSize)
        } else if state == .transcribing {
            previewGate.end()
            model.partialText = ""
            window?.setContentSize(Self.compactSize)
        } else {
            previewGate.end()
        }
        guard let window else { return }
        let needsAppear = !window.isVisible
        if needsAppear {
            positionAtBottomCenter(window)
            window.orderFrontRegardless()
            // Defer the state change so SwiftUI lays out in the .hidden style
            // first, then animates to the visible style on the next runloop tick.
            DispatchQueue.main.async { [model] in
                model.state = state
            }
        } else {
            model.state = state
        }
    }

    func hide() {
        previewGate.end()
        model.state = .hidden
        // Let the SwiftUI scale+fade animation play out before yanking the
        // window — otherwise it just pops away.
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.window?.orderOut(nil)
            self?.hideWorkItem = nil
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    /// Push a new audio level (0…~1). Safe to call from any thread.
    nonisolated func pushLevel(_ level: Float) {
        levelCoalescer.submit(level)
    }

    /// Streaming partials are presentation-only. The completed model result is
    /// still the sole text that can reach history, a journal, or the cursor.
    nonisolated func pushPartial(_ text: String, sessionID: UUID) {
        DispatchQueue.main.async { [weak self] in
            self?.showPartial(text, sessionID: sessionID)
        }
    }

    private func ensureWindow() {
        if window != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 96, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: OverlayPill(model: model))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        window = panel
    }

    private func showPartial(_ text: String, sessionID: UUID) {
        guard model.state == .recording, previewGate.accepts(sessionID) else { return }
        let preview = Self.previewText(text)
        guard !preview.isEmpty, preview != model.partialText else { return }
        model.partialText = preview
        window?.setContentSize(Self.previewSize)
        if let window { positionAtBottomCenter(window) }
    }

    nonisolated static func previewText(_ text: String, maximumCharacters: Int = 180) -> String {
        let normalized = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard normalized.count > maximumCharacters else { return normalized }
        let suffix = String(normalized.suffix(maximumCharacters))
        guard let firstSpace = suffix.firstIndex(of: " ") else { return suffix }
        return "…" + suffix[suffix.index(after: firstSpace)...]
    }

    private func positionAtBottomCenter(_ window: NSPanel) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.main
        else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.minY + 32
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// A recording identity keeps delayed callbacks from a completed/cancelled
/// stream from repainting the next recording's overlay.
struct RealtimePreviewGate: Equatable {
    private(set) var activeSessionID: UUID?

    mutating func begin(sessionID: UUID?) {
        activeSessionID = sessionID
    }

    mutating func end() {
        activeSessionID = nil
    }

    func accepts(_ sessionID: UUID) -> Bool {
        activeSessionID == sessionID
    }
}

/// Observable state for the SwiftUI pill.
@MainActor
final class OverlayModel: ObservableObject {
    static let barCount = 6
    /// Per-bar height multiplier — center bars peak higher than edge bars.
    private static let envelope: [Float] = [0.55, 0.85, 1.0, 1.0, 0.85, 0.55]

    @Published var state: RecordingOverlay.State = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: barCount)
    @Published var partialText = ""

    func pushLevel(_ level: Float) {
        guard state == .recording else { return }
        let shaped = min(1.0, sqrt(max(0, level)) * 3.4)
        var next = [Float]()
        next.reserveCapacity(Self.barCount)
        for i in 0..<Self.barCount {
            // Small per-bar jitter so the bars don't all move in lockstep.
            let jitter = Float.random(in: 0.78...1.0)
            next.append(shaped * Self.envelope[i] * jitter)
        }
        levels = next
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

private struct OverlayPill: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(Color(red: 16/255, green: 18/255, blue: 18/255))
            )
            .scaleEffect(model.state == .hidden ? 0 : 1)
            .animation(
                .timingCurve(0.16, 1, 0.3, 1, duration: 0.3),
                value: model.state
            )
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden:
            Waveform(levels: model.levels)
                .frame(width: 54, height: 22)
        case .recording:
            HStack(spacing: model.partialText.isEmpty ? 0 : 12) {
                Waveform(levels: model.levels)
                    .frame(width: 54, height: 22)
                if !model.partialText.isEmpty {
                    Text(model.partialText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(2)
                        .frame(maxWidth: 320, alignment: .leading)
                }
            }
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
                .frame(width: 54, height: 22)
        }
    }
}

private struct Waveform: View {
    let levels: [Float]
    private let color = Color(red: 181/255.0, green: 209/255.0, blue: 255/255.0)

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5)
                    .frame(maxHeight: .infinity)
                    .scaleEffect(y: max(0.10, CGFloat(level)), anchor: .center)
                    .animation(.easeOut(duration: 0.09), value: level)
            }
        }
    }
}

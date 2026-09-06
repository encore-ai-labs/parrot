import Foundation
import XCTest

@testable import parrot

final class RealtimeTranscriptionSessionTests: XCTestCase {
    func testSessionPreservesAudioOrderAndReturnsOneAuthoritativeResult() async throws {
        let transcriber = MockRealtimeTranscriber()
        let partials = LockedStrings()
        let session = RealtimeTranscriptionSession(
            transcriber: transcriber,
            partial: { partials.append($0) }
        )

        session.submit([Float](repeating: 1, count: 1_000))
        session.submit([Float](repeating: 2, count: 2_000))
        let completion = await session.finish(mode: .notes, sourceDuration: 0.1875)

        XCTAssertNil(completion.fallbackReason)
        XCTAssertEqual(completion.transcription?.text, "final transcript")
        let state = await transcriber.snapshot()
        XCTAssertEqual(state.beginCount, 1)
        XCTAssertEqual(state.finishCount, 1)
        XCTAssertEqual(state.cancelCount, 0)
        XCTAssertEqual(state.audio, [Float](repeating: 1, count: 1_000)
            + [Float](repeating: 2, count: 2_000))
        XCTAssertFalse(partials.values.isEmpty)
    }

    func testBoundedQueueFallsBackInsteadOfDroppingSpeech() async {
        let gate = AsyncGate()
        let transcriber = MockRealtimeTranscriber()
        let session = RealtimeTranscriptionSession(
            transcriber: transcriber,
            prepare: { await gate.wait() },
            partial: { _ in }
        )

        let chunk = [Float](
            repeating: 1,
            count: RealtimeTranscriptionSession.maximumBufferedSamples / 2 + 1
        )
        session.submit(chunk)
        session.submit(chunk)
        await gate.open()
        let completion = await session.finish(mode: .dictation, sourceDuration: 1)

        XCTAssertNil(completion.transcription)
        XCTAssertTrue(completion.fallbackReason?.contains("fell behind") == true)
        let state = await transcriber.snapshot()
        XCTAssertEqual(state.cancelCount, 1)
    }

    func testCancelResetsModelAndNextSessionWaitsForTeardown() async {
        let transcriber = MockRealtimeTranscriber()
        let first = RealtimeTranscriptionSession(
            transcriber: transcriber,
            partial: { _ in }
        )
        first.submit([1, 2, 3])
        let teardown = first.cancel()

        let second = RealtimeTranscriptionSession(
            transcriber: transcriber,
            after: teardown,
            partial: { _ in }
        )
        second.submit([4, 5, 6])
        let completion = await second.finish(mode: .dictation, sourceDuration: 0.1)

        XCTAssertEqual(completion.transcription?.text, "final transcript")
        let state = await transcriber.snapshot()
        XCTAssertEqual(state.cancelCount, 1)
        XCTAssertEqual(state.finishCount, 1)
        XCTAssertEqual(Array(state.audio.suffix(3)), [4, 5, 6])
    }

    func testOverlayPreviewIsBoundedAndWhitespaceNormalized() {
        XCTAssertEqual(
            RecordingOverlay.previewText("  a\n\tshort   live transcript  "),
            "a short live transcript"
        )
        let long = (0..<100).map { "word\($0)" }.joined(separator: " ")
        let preview = RecordingOverlay.previewText(long, maximumCharacters: 60)
        XCTAssertTrue(preview.hasPrefix("…"))
        XCTAssertLessThanOrEqual(preview.count, 61)
        XCTAssertTrue(long.hasSuffix(String(preview.dropFirst())))
    }

    func testOverlayRejectsDelayedPartialsFromPreviousRecording() {
        let first = UUID()
        let second = UUID()
        var gate = RealtimePreviewGate()

        gate.begin(sessionID: first)
        XCTAssertTrue(gate.accepts(first))
        XCTAssertFalse(gate.accepts(second))

        gate.end()
        XCTAssertFalse(gate.accepts(first))

        gate.begin(sessionID: second)
        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))
    }
}

private actor MockRealtimeTranscriber: RealtimeTranscriber {
    struct State: Sendable {
        let beginCount: Int
        let finishCount: Int
        let cancelCount: Int
        let audio: [Float]
    }

    nonisolated let modelID = "mock-live"
    nonisolated let supportsRealtime = true
    private var beginCount = 0
    private var finishCount = 0
    private var cancelCount = 0
    private var audio: [Float] = []
    private var partial: (@Sendable (String) -> Void)?

    func warmUp() async throws {}
    func updatePersonalization(_ personalization: TranscriberPersonalization) async {}

    func transcribe(
        _ audio: [Float],
        mode: DictationMode,
        recognitionContext: String?
    ) async throws -> LiveTranscription {
        LiveTranscription(text: "fallback", language: "en")
    }

    func transcribeFile(
        at url: URL,
        mode: DictationMode,
        recognitionContext: String?
    ) async throws -> TimedTranscription {
        TimedTranscription(text: "fallback", language: "en", segments: [])
    }

    func beginRealtime(partial: @escaping @Sendable (String) -> Void) async throws {
        beginCount += 1
        audio.removeAll()
        self.partial = partial
    }

    func appendRealtime(_ audio: [Float]) async throws {
        self.audio.append(contentsOf: audio)
        partial?("partial \(self.audio.count)")
    }

    func finishRealtime(
        mode: DictationMode,
        sourceDuration: TimeInterval
    ) async throws -> LiveTranscription {
        finishCount += 1
        return LiveTranscription(text: "final transcript", language: "en")
    }

    func cancelRealtime() async {
        cancelCount += 1
        partial = nil
    }

    func snapshot() -> State {
        State(
            beginCount: beginCount,
            finishCount: finishCount,
            cancelCount: cancelCount,
            audio: audio
        )
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

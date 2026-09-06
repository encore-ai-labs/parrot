import Foundation

/// Bounded bridge from the realtime audio callback to an async local ASR actor.
///
/// Audio delivery never waits on Core ML. A single worker preserves sample
/// order, coalesces tiny capture buffers, and caps queued audio. If inference
/// ever falls more than a few seconds behind, the session declines its partial
/// result so the normal recovery WAV is transcribed after release instead of
/// silently dropping speech.
final class RealtimeTranscriptionSession: @unchecked Sendable {
    struct Completion: Sendable {
        let transcription: LiveTranscription?
        let fallbackReason: String?

        static func completed(_ transcription: LiveTranscription) -> Self {
            Self(transcription: transcription, fallbackReason: nil)
        }

        static func fallback(_ reason: String) -> Self {
            Self(transcription: nil, fallbackReason: reason)
        }
    }

    private enum WorkerOutcome: Sendable {
        case ready
        case failed(String)
    }

    static let processingBatchSamples = 2_560 // 160 ms at 16 kHz
    static let maximumBufferedChunks = 256
    static let maximumBufferedSamples = 80_000 // five seconds at 16 kHz

    private let transcriber: any RealtimeTranscriber
    private let continuation: AsyncStream<[Float]>.Continuation
    private let lock = NSLock()
    private var worker: Task<WorkerOutcome, Never>!
    private var closed = false
    private var overloaded = false
    private var bufferedSamples = 0

    init(
        transcriber: any RealtimeTranscriber,
        after previousTeardown: Task<Void, Never>? = nil,
        prepare: @escaping @Sendable () async -> Void = {},
        partial: @escaping @Sendable (String) -> Void
    ) {
        self.transcriber = transcriber
        let pair = AsyncStream<[Float]>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.maximumBufferedChunks)
        )
        continuation = pair.continuation
        worker = Task.detached(priority: .userInitiated) { [transcriber] in
            if let previousTeardown { await previousTeardown.value }
            guard !Task.isCancelled else { return .failed("cancelled") }
            await prepare()
            guard !Task.isCancelled else { return .failed("cancelled") }
            do {
                try await transcriber.beginRealtime(partial: partial)
                var batch: [Float] = []
                batch.reserveCapacity(Self.processingBatchSamples * 2)
                for await samples in pair.stream {
                    self.markDequeued(samples.count)
                    guard !Task.isCancelled else { return .failed("cancelled") }
                    batch.append(contentsOf: samples)
                    if batch.count >= Self.processingBatchSamples {
                        try await transcriber.appendRealtime(batch)
                        batch.removeAll(keepingCapacity: true)
                    }
                }
                if !batch.isEmpty, !Task.isCancelled {
                    try await transcriber.appendRealtime(batch)
                }
                return Task.isCancelled ? .failed("cancelled") : .ready
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    /// Called synchronously from the capture queue. It only enqueues one
    /// copy-on-write array and never blocks on recognition.
    func submit(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        guard samples.count <= Self.maximumBufferedSamples - bufferedSamples else {
            overloaded = true
            closed = true
            lock.unlock()
            continuation.finish()
            worker.cancel()
            return
        }
        bufferedSamples += samples.count
        switch continuation.yield(samples) {
        case .enqueued:
            lock.unlock()
        case .dropped:
            overloaded = true
            closed = true
            lock.unlock()
            continuation.finish()
            worker.cancel()
        case .terminated:
            closed = true
            lock.unlock()
        @unknown default:
            overloaded = true
            closed = true
            lock.unlock()
            continuation.finish()
            worker.cancel()
        }
    }

    func finish(
        mode: DictationMode,
        sourceDuration: TimeInterval
    ) async -> Completion {
        closeInput()
        let outcome = await worker.value
        if didOverload() {
            await transcriber.cancelRealtime()
            return .fallback("live recognition fell behind; finalized from recovery audio")
        }
        switch outcome {
        case .failed(let reason):
            await transcriber.cancelRealtime()
            return .fallback("live recognition unavailable: \(reason)")
        case .ready:
            do {
                return .completed(try await transcriber.finishRealtime(
                    mode: mode,
                    sourceDuration: sourceDuration
                ))
            } catch {
                await transcriber.cancelRealtime()
                return .fallback("live finalization unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Ends partial work and returns a task that fully resets the shared model.
    /// A subsequent session can wait for it without delaying a new recording.
    func cancel() -> Task<Void, Never> {
        closeInput()
        worker.cancel()
        return Task { [worker, transcriber] in
            _ = await worker?.value
            await transcriber.cancelRealtime()
        }
    }

    private func closeInput() {
        lock.lock()
        let shouldFinish = !closed
        closed = true
        lock.unlock()
        if shouldFinish { continuation.finish() }
    }

    private func didOverload() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return overloaded
    }

    private func markDequeued(_ sampleCount: Int) {
        lock.lock()
        bufferedSamples = max(0, bufferedSamples - sampleCount)
        lock.unlock()
    }
}

/// Synchronous handoff used by `AudioCapture` while it holds its ordering
/// lock. Session replacement happens only at capture boundaries.
final class RealtimeCaptureRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var active: RealtimeTranscriptionSession?

    func activate(_ session: RealtimeTranscriptionSession) {
        lock.lock()
        active = session
        lock.unlock()
    }

    func submit(_ samples: [Float]) {
        lock.lock()
        let session = active
        lock.unlock()
        session?.submit(samples)
    }

    func deactivate() -> RealtimeTranscriptionSession? {
        lock.lock()
        defer { lock.unlock() }
        let session = active
        active = nil
        return session
    }
}

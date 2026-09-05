import Foundation

/// Main-thread state for one-at-a-time dictation. Whisper completion is
/// asynchronous, so a generation token prevents an old task from changing UI
/// or injecting text after its session is no longer current.
final class DictationLifecycle: @unchecked Sendable {
    enum Phase: Equatable {
        case idle
        case recording(Int)
        case transcribing(Int)
    }

    private let lock = NSLock()
    private var phase: Phase = .idle
    private var nextID = 0

    var isTranscribing: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .transcribing = phase { return true }
        return false
    }

    func start() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .idle else { return nil }
        nextID += 1
        phase = .recording(nextID)
        return nextID
    }

    func beginTranscription() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard case .recording(let id) = phase else { return nil }
        phase = .transcribing(id)
        return id
    }

    /// Begin inference for audio that was captured previously. This takes the
    /// same single-flight slot as a live transcription without pretending a
    /// microphone recording is active.
    func beginRetry() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .idle else { return nil }
        nextID += 1
        phase = .transcribing(nextID)
        return nextID
    }

    func cancelRecording() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .recording = phase else { return false }
        phase = .idle
        return true
    }

    func finish(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .transcribing(id) else { return false }
        phase = .idle
        return true
    }

    func failStart(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .recording(id) else { return }
        phase = .idle
    }
}

enum CaptureQuality {
    enum Rejection: Equatable {
        case tooShort
        case tooQuiet

        var message: String {
            switch self {
            case .tooShort: return "capture was too short"
            case .tooQuiet: return "no clear speech detected"
            }
        }
    }

    static let minimumDuration: TimeInterval = 0.25
    static let minimumRMS: Float = 0.0005

    static func rejection(
        duration: TimeInterval,
        rms: Float,
        enabled: Bool = true
    ) -> Rejection? {
        guard enabled else { return nil }
        if duration < minimumDuration { return .tooShort }
        if rms < minimumRMS { return .tooQuiet }
        return nil
    }
}

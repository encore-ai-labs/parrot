import Foundation

/// Turns hotkey edges into push-to-talk or double-tap-to-lock behavior.
///
/// A held press stops as soon as it is released. A quick tap gets a short
/// grace period in which a second press can lock recording on; without the
/// second press, recording stops when that grace period expires.
struct HotkeyGesture {
    enum Input: Equatable {
        case hotkeyPressed(source: String)
        case hotkeyReleased(source: String)
        case cancelKeyPressed
        case timeout
    }

    enum Effect: Equatable {
        case startRecording(source: String)
        case stopRecording
        case cancelRecording
        case setLatched(Bool, source: String)
        case scheduleTimeout(after: TimeInterval)
        case cancelTimeout
    }

    private enum State: Equatable {
        case idle
        case firstPress(source: String, startedAt: TimeInterval)
        case awaitingSecondPress(source: String, deadline: TimeInterval)
        case secondPress(source: String)
        case latched(source: String)
    }

    static let defaultDoubleTapInterval: TimeInterval = 0.55

    private let doubleTapInterval: TimeInterval
    private var state: State = .idle

    init(doubleTapInterval: TimeInterval = Self.defaultDoubleTapInterval) {
        self.doubleTapInterval = doubleTapInterval
    }

    mutating func handle(_ input: Input, at now: TimeInterval) -> [Effect] {
        var effects: [Effect] = []

        // A late second press is a fresh recording, not a double-tap. Expire
        // the first recording before processing that new press.
        if case .awaitingSecondPress(_, let deadline) = state, now >= deadline {
            state = .idle
            effects.append(contentsOf: [.cancelTimeout, .stopRecording])
            if input == .timeout { return effects }
        }

        switch (state, input) {
        case (.idle, .hotkeyPressed(let source)):
            state = .firstPress(source: source, startedAt: now)
            effects.append(.startRecording(source: source))

        case (.firstPress(let active, let startedAt), .hotkeyReleased(let source))
            where source == active:
            let deadline = startedAt + doubleTapInterval
            if now < deadline {
                state = .awaitingSecondPress(source: source, deadline: deadline)
                effects.append(.scheduleTimeout(after: deadline - now))
            } else {
                state = .idle
                effects.append(.stopRecording)
            }

        case (.awaitingSecondPress(let active, _), .hotkeyPressed(let source))
            where source == active:
            state = .secondPress(source: source)
            effects.append(.cancelTimeout)

        case (.awaitingSecondPress(let source, let deadline), .timeout):
            // Dispatch timers can occasionally wake early. Keep the original
            // deadline rather than ending a recording ahead of time.
            state = .awaitingSecondPress(source: source, deadline: deadline)
            effects.append(.scheduleTimeout(after: max(0, deadline - now)))

        case (.secondPress(let active), .hotkeyReleased(let source)) where source == active:
            state = .latched(source: source)
            effects.append(.setLatched(true, source: source))

        case (.latched(let active), .hotkeyPressed(let source)) where source == active:
            state = .idle
            effects.append(contentsOf: [
                .setLatched(false, source: source),
                .stopRecording,
            ])

        case (.firstPress, .cancelKeyPressed), (.secondPress, .cancelKeyPressed):
            state = .idle
            effects.append(.cancelRecording)

        case (.awaitingSecondPress, .cancelKeyPressed):
            state = .idle
            effects.append(contentsOf: [.cancelTimeout, .cancelRecording])

        case (.latched(let source), .cancelKeyPressed):
            state = .idle
            effects.append(contentsOf: [
                .setLatched(false, source: source),
                .cancelRecording,
            ])

        default:
            break
        }

        return effects
    }
}

/// Owns the one-shot timer needed by `HotkeyGesture`, leaving its state
/// transitions deterministic and easy to test.
final class HotkeyGestureController {
    private var gesture: HotkeyGesture
    private var timeoutWorkItem: DispatchWorkItem?
    private let onEffect: (HotkeyGesture.Effect) -> Void

    init(
        gesture: HotkeyGesture = HotkeyGesture(),
        onEffect: @escaping (HotkeyGesture.Effect) -> Void
    ) {
        self.gesture = gesture
        self.onEffect = onEffect
    }

    func handle(_ input: HotkeyGesture.Input) {
        let now = ProcessInfo.processInfo.systemUptime
        apply(gesture.handle(input, at: now))
    }

    private func apply(_ effects: [HotkeyGesture.Effect]) {
        for effect in effects {
            switch effect {
            case .scheduleTimeout(let delay):
                timeoutWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    self?.handle(.timeout)
                }
                timeoutWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)

            case .cancelTimeout:
                timeoutWorkItem?.cancel()
                timeoutWorkItem = nil

            default:
                onEffect(effect)
            }
        }
    }
}

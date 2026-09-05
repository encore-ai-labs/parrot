import Foundation

/// Turns hotkey edges into push-to-talk or double-tap-to-lock behavior.
///
/// A held press stops as soon as it is released. A quick tap gets a short
/// grace period in which a second press can lock recording on; without the
/// second press, recording stops when that grace period expires.
struct HotkeyGesture {
    enum Input: Equatable {
        case hotkeyPressed
        case hotkeyReleased
        case cancelKeyPressed
        case timeout
    }

    enum Effect: Equatable {
        case startRecording
        case stopRecording
        case cancelRecording
        case setLatched(Bool)
        case scheduleTimeout(after: TimeInterval)
        case cancelTimeout
    }

    private enum State: Equatable {
        case idle
        case firstPress(startedAt: TimeInterval)
        case awaitingSecondPress(deadline: TimeInterval)
        case secondPress
        case latched
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
        if case .awaitingSecondPress(let deadline) = state, now >= deadline {
            state = .idle
            effects.append(contentsOf: [.cancelTimeout, .stopRecording])
            if input == .timeout { return effects }
        }

        switch (state, input) {
        case (.idle, .hotkeyPressed):
            state = .firstPress(startedAt: now)
            effects.append(.startRecording)

        case (.firstPress(let startedAt), .hotkeyReleased):
            let deadline = startedAt + doubleTapInterval
            if now < deadline {
                state = .awaitingSecondPress(deadline: deadline)
                effects.append(.scheduleTimeout(after: deadline - now))
            } else {
                state = .idle
                effects.append(.stopRecording)
            }

        case (.awaitingSecondPress, .hotkeyPressed):
            state = .secondPress
            effects.append(.cancelTimeout)

        case (.awaitingSecondPress(let deadline), .timeout):
            // Dispatch timers can occasionally wake early. Keep the original
            // deadline rather than ending a recording ahead of time.
            state = .awaitingSecondPress(deadline: deadline)
            effects.append(.scheduleTimeout(after: max(0, deadline - now)))

        case (.secondPress, .hotkeyReleased):
            state = .latched
            effects.append(.setLatched(true))

        case (.latched, .hotkeyPressed):
            state = .idle
            effects.append(contentsOf: [.setLatched(false), .stopRecording])

        case (.firstPress, .cancelKeyPressed), (.secondPress, .cancelKeyPressed):
            state = .idle
            effects.append(.cancelRecording)

        case (.awaitingSecondPress, .cancelKeyPressed):
            state = .idle
            effects.append(contentsOf: [.cancelTimeout, .cancelRecording])

        case (.latched, .cancelKeyPressed):
            state = .idle
            effects.append(contentsOf: [.setLatched(false), .cancelRecording])

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

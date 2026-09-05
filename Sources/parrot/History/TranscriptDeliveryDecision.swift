import Foundation

/// Keeps live delivery failure semantics explicit and regression-testable.
/// Journal writes can safely fall back to cursor insertion because they are a
/// single atomic append. An arbitrary command may have completed only some of
/// its side effects, so retry—not a second automatic destination—is safer.
struct TranscriptDeliveryDecision: Equatable {
    let injectAtCursor: Bool
    /// Commit history and clear the recovery slot only after delivery is
    /// considered complete.
    let deliveryCompleted: Bool

    static func resolve(
        deliveredToJournal: Bool,
        commandConfigured: Bool,
        commandSucceeded: Bool
    ) -> TranscriptDeliveryDecision {
        if commandConfigured {
            return TranscriptDeliveryDecision(
                injectAtCursor: false,
                deliveryCompleted: commandSucceeded
            )
        }
        return TranscriptDeliveryDecision(
            injectAtCursor: !deliveredToJournal,
            deliveryCompleted: true
        )
    }
}

import XCTest

@testable import parrot

final class TranscriptDeliveryDecisionTests: XCTestCase {
    func testCursorDeliveryInjectsAndClearsRecovery() {
        XCTAssertEqual(
            TranscriptDeliveryDecision.resolve(
                deliveredToJournal: false,
                commandConfigured: false,
                commandSucceeded: true
            ),
            TranscriptDeliveryDecision(injectAtCursor: true, deliveryCompleted: true)
        )
    }

    func testSuccessfulJournalSuppressesPasteAndClearsRecovery() {
        XCTAssertEqual(
            TranscriptDeliveryDecision.resolve(
                deliveredToJournal: true,
                commandConfigured: false,
                commandSucceeded: true
            ),
            TranscriptDeliveryDecision(injectAtCursor: false, deliveryCompleted: true)
        )
    }

    func testFailedJournalFallsBackToPasteAndClearsRecovery() {
        XCTAssertEqual(
            TranscriptDeliveryDecision.resolve(
                deliveredToJournal: false,
                commandConfigured: false,
                commandSucceeded: true
            ),
            TranscriptDeliveryDecision(injectAtCursor: true, deliveryCompleted: true)
        )
    }

    func testSuccessfulCommandSuppressesPasteAndClearsRecovery() {
        XCTAssertEqual(
            TranscriptDeliveryDecision.resolve(
                deliveredToJournal: false,
                commandConfigured: true,
                commandSucceeded: true
            ),
            TranscriptDeliveryDecision(injectAtCursor: false, deliveryCompleted: true)
        )
    }

    func testFailedCommandSuppressesFallbackAndKeepsRecovery() {
        XCTAssertEqual(
            TranscriptDeliveryDecision.resolve(
                deliveredToJournal: false,
                commandConfigured: true,
                commandSucceeded: false
            ),
            TranscriptDeliveryDecision(injectAtCursor: false, deliveryCompleted: false)
        )
    }
}

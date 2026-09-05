import XCTest

@testable import parrot

final class AudioLevelEfficiencyTests: XCTestCase {
    func testLevelWorkRequiresBothActiveCaptureAndConsumer() {
        XCTAssertFalse(shouldEmitAudioLevel(isCapturing: false, hasConsumer: false))
        XCTAssertFalse(shouldEmitAudioLevel(isCapturing: false, hasConsumer: true))
        XCTAssertFalse(shouldEmitAudioLevel(isCapturing: true, hasConsumer: false))
        XCTAssertTrue(shouldEmitAudioLevel(isCapturing: true, hasConsumer: true))
    }

    func testCoalescerKeepsLatestLevelWithOnePendingDelivery() {
        var scheduled: [DispatchWorkItem] = []
        var delivered: [Float] = []
        let coalescer = AudioLevelCoalescer(
            schedule: { scheduled.append($0) },
            deliver: { delivered.append($0) }
        )

        for value in 0..<1_000 {
            coalescer.submit(Float(value))
        }

        XCTAssertEqual(scheduled.count, 1)
        XCTAssertTrue(delivered.isEmpty)
        scheduled.removeFirst().perform()
        XCTAssertEqual(delivered, [999])

        coalescer.submit(1_001)
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst().perform()
        XCTAssertEqual(delivered, [999, 1_001])
    }

    func testRunCapturePolicyFlagsAreExclusive() throws {
        XCTAssertTrue(try XCTUnwrap(try Run.parseAsRoot(["--cold-mic"]) as? Run).coldMic)
        XCTAssertTrue(try XCTUnwrap(try Run.parseAsRoot(["--warm-mic"]) as? Run).warmMic)
        XCTAssertThrowsError(try Run.parseAsRoot(["--cold-mic", "--warm-mic"]))
    }

    func testCoalescerBurstCostStaysBounded() {
        var scheduled: [DispatchWorkItem] = []
        var delivered = 0
        let coalescer = AudioLevelCoalescer(
            schedule: { scheduled.append($0) },
            deliver: { _ in delivered += 1 }
        )

        measure {
            for value in 0..<10_000 {
                coalescer.submit(Float(value))
            }
            XCTAssertEqual(scheduled.count, 1)
            scheduled.removeFirst().perform()
        }

        XCTAssertEqual(delivered, 10)
    }
}

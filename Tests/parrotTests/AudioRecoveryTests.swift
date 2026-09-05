import CoreAudio
import XCTest

@testable import parrot

final class AudioRecoveryTests: XCTestCase {
    func testDevicePriorityCommandsParseAndBoundRankedMicrophones() throws {
        XCTAssertTrue(try Devices.parseAsRoot([]) is Devices.List)
        let priority = try XCTUnwrap(
            try Devices.parseAsRoot([
                "prioritize", "Studio USB", "MacBook Pro Microphone",
            ]) as? Devices.Prioritize
        )
        XCTAssertEqual(priority.devices, ["Studio USB", "MacBook Pro Microphone"])
        XCTAssertTrue(try Devices.parseAsRoot(["automatic"]) is Devices.Automatic)
        XCTAssertThrowsError(try Devices.parseAsRoot(
            ["prioritize"] + (0...AudioDevices.maximumPriorityCount).map { "mic-\($0)" }
        ))
    }

    func testRuntimeErrorCancelsPartialCaptureAndReconfiguresWarmSession() {
        var state = AudioRecoveryState(keepsSessionWarm: true)
        state.beginCapture()

        XCTAssertEqual(
            state.handle(.runtimeError("media services reset")),
            [
                .cancelCapture("media services reset"),
                .recover(reconfigure: true, reason: "media services reset"),
            ]
        )
        XCTAssertFalse(state.isCapturing)
        XCTAssertTrue(state.wantsSessionRunning)
    }

    func testColdSessionInvalidatesAfterFailureWithoutRemainingOpen() {
        var state = AudioRecoveryState(keepsSessionWarm: false)
        state.beginCapture()

        XCTAssertEqual(
            state.handle(.activeDeviceDisconnected("USB mic disconnected")),
            [
                .cancelCapture("USB mic disconnected"),
                .recover(reconfigure: true, reason: "USB mic disconnected"),
            ]
        )
        XCTAssertFalse(state.wantsSessionRunning)
    }

    func testSleepCancelsCaptureStopsSessionAndWakeRecoversWarmMic() {
        var state = AudioRecoveryState(keepsSessionWarm: true)
        state.beginCapture()

        XCTAssertEqual(
            state.handle(.willSleep),
            [.cancelCapture("Mac went to sleep"), .stopSession]
        )
        XCTAssertTrue(state.isSleeping)
        XCTAssertFalse(state.wantsSessionRunning)

        XCTAssertEqual(
            state.handle(.didWake),
            [.recover(reconfigure: true, reason: "Mac woke from sleep")]
        )
        XCTAssertFalse(state.isSleeping)
        XCTAssertTrue(state.wantsSessionRunning)
    }

    func testInterruptionWaitsForEndBeforeRestarting() {
        var state = AudioRecoveryState(keepsSessionWarm: true)
        state.beginCapture()

        XCTAssertEqual(
            state.handle(.sessionInterrupted("another app took the mic")),
            [.cancelCapture("another app took the mic")]
        )
        XCTAssertTrue(state.isInterrupted)
        XCTAssertFalse(state.beginCapture())
        XCTAssertEqual(
            state.handle(.interruptionEnded),
            [.recover(reconfigure: false, reason: "capture interruption ended")]
        )
        XCTAssertFalse(state.isInterrupted)
        XCTAssertTrue(state.beginCapture())
    }

    func testRawRecoveryStateStillRejectsAnUnsafeMidCaptureDeviceSwitch() {
        var state = AudioRecoveryState(keepsSessionWarm: true)
        state.beginCapture()

        XCTAssertEqual(
            state.handle(.preferredDeviceConnected("Studio USB")),
            [
                .cancelCapture("preferred microphone reconnected"),
                .recover(
                    reconfigure: true,
                    reason: "preferred microphone reconnected: Studio USB"
                ),
            ]
        )
    }

    func testRMSAcceptsAudioBufferWithoutArrayMaterialization() {
        let samples: [Float] = [0.5, -0.5, 0.5, -0.5]
        let rms = samples.withUnsafeBufferPointer { computeRMS($0) }

        XCTAssertEqual(rms, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(computeRMS([Float]()), 0)
    }

    func testRecoveryBackoffIsBoundedAndMonotonic() {
        XCTAssertEqual(AudioCapture.recoveryDelays, [0, 0.25, 1, 3, 10])
        XCTAssertEqual(AudioCapture.recoveryDelays, AudioCapture.recoveryDelays.sorted())
    }

    func testRecoveryFallbackPrefersSafeSystemDefault() throws {
        let selected = device(id: 1, uid: "usb", transport: kAudioDeviceTransportTypeUSB)
        let builtIn = device(id: 2, uid: "built-in", transport: kAudioDeviceTransportTypeBuiltIn)
        let safeDefault = device(id: 3, uid: "display", transport: kAudioDeviceTransportTypeDisplayPort)

        let fallback = AudioDevices.recoveryFallback(
            from: [selected, builtIn, safeDefault],
            defaultDeviceID: safeDefault.id,
            excluding: selected.uid
        )

        XCTAssertEqual(try XCTUnwrap(fallback).uid, safeDefault.uid)
    }

    func testRecoveryFallbackRejectsSelectedBluetoothAndVirtualDevices() throws {
        let selected = device(id: 1, uid: "usb", transport: kAudioDeviceTransportTypeUSB)
        let bluetooth = device(id: 2, uid: "airpods", transport: kAudioDeviceTransportTypeBluetooth)
        let virtual = device(id: 3, uid: "zoom", transport: kAudioDeviceTransportTypeVirtual)
        let builtIn = device(id: 4, uid: "built-in", transport: kAudioDeviceTransportTypeBuiltIn)

        let fallback = AudioDevices.recoveryFallback(
            from: [selected, bluetooth, virtual, builtIn],
            defaultDeviceID: bluetooth.id,
            excluding: selected.uid
        )
        XCTAssertEqual(try XCTUnwrap(fallback).uid, builtIn.uid)

        XCTAssertNil(AudioDevices.recoveryFallback(
            from: [selected, bluetooth, virtual],
            defaultDeviceID: bluetooth.id,
            excluding: selected.uid
        ))
    }

    func testMicrophonePrioritySelectsHighestConnectedAndBoundsEditedConfig() throws {
        let studio = device(id: 1, uid: "studio", transport: kAudioDeviceTransportTypeUSB)
        let builtIn = device(id: 2, uid: "built-in", transport: kAudioDeviceTransportTypeBuiltIn)
        let duplicateAndOversized = ["", "studio", "studio", "built-in"]
            + (0..<20).map { "extra-\($0)" }

        XCTAssertEqual(
            AudioDevices.normalizedPriorityUIDs(duplicateAndOversized),
            ["studio", "built-in", "extra-0", "extra-1", "extra-2", "extra-3", "extra-4", "extra-5"]
        )
        XCTAssertEqual(
            try XCTUnwrap(AudioDevices.highestPriority(
                from: [builtIn],
                priorityUIDs: [studio.uid, builtIn.uid]
            )).uid,
            builtIn.uid
        )
        XCTAssertEqual(
            try XCTUnwrap(AudioDevices.highestPriority(
                from: [builtIn, studio],
                priorityUIDs: [studio.uid, builtIn.uid]
            )).uid,
            studio.uid
        )
        XCTAssertEqual(try XCTUnwrap(AudioDevices.find(" Studio ", in: [studio])).uid, studio.uid)
        XCTAssertNil(AudioDevices.find("   ", in: [studio]))
    }

    func testOnlyHigherPriorityConnectionPromotesAndActiveCaptureDefersIt() {
        let priorities = ["studio", "display", "built-in"]

        XCTAssertEqual(
            AudioDevices.promotion(
                connectedUID: "studio",
                over: "built-in",
                priorityUIDs: priorities,
                isCapturing: false
            ),
            .immediately
        )
        XCTAssertEqual(
            AudioDevices.promotion(
                connectedUID: "studio",
                over: "built-in",
                priorityUIDs: priorities,
                isCapturing: true
            ),
            .afterCapture
        )
        XCTAssertEqual(
            AudioDevices.promotion(
                connectedUID: "built-in",
                over: "studio",
                priorityUIDs: priorities,
                isCapturing: false
            ),
            .none
        )
        XCTAssertEqual(
            AudioDevices.promotion(
                connectedUID: "unranked",
                over: "built-in",
                priorityUIDs: priorities,
                isCapturing: false
            ),
            .none
        )
    }

    func testFallbackExcludesEveryUnavailableRankedMicrophone() throws {
        let studio = device(id: 1, uid: "studio", transport: kAudioDeviceTransportTypeUSB)
        let display = device(id: 2, uid: "display", transport: kAudioDeviceTransportTypeDisplayPort)
        let builtIn = device(id: 3, uid: "built-in", transport: kAudioDeviceTransportTypeBuiltIn)

        let fallback = AudioDevices.recoveryFallback(
            from: [studio, display, builtIn],
            defaultDeviceID: display.id,
            excluding: [studio.uid, display.uid]
        )

        XCTAssertEqual(try XCTUnwrap(fallback).uid, builtIn.uid)
    }

    func testPriorityConnectionRoutingCostStaysNegligible() {
        let priorities = (0..<AudioDevices.maximumPriorityCount).map { "mic-\($0)" }
        var promotion = AudioDevices.Promotion.none

        measure {
            for _ in 0..<100_000 {
                promotion = AudioDevices.promotion(
                    connectedUID: "mic-0",
                    over: "mic-7",
                    priorityUIDs: priorities,
                    isCapturing: false
                )
            }
        }
        XCTAssertEqual(promotion, .immediately)
    }

    private func device(
        id: AudioDeviceID,
        uid: String,
        transport: UInt32
    ) -> AudioInputDevice {
        AudioInputDevice(
            id: id,
            name: uid,
            uid: uid,
            transport: transport,
            inputChannels: 1
        )
    }
}

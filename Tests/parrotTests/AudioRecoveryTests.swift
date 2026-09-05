import CoreAudio
import XCTest

@testable import parrot

final class AudioRecoveryTests: XCTestCase {
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

    func testPreferredMicReconnectCancelsMixedDeviceCapture() {
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

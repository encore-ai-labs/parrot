import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Pure state transitions for capture-loss events. Keeping this separate from
/// AVFoundation makes the cancellation/recovery contract deterministic and
/// testable without opening a microphone.
struct AudioRecoveryState: Equatable {
    enum Event: Equatable {
        case sessionInterrupted(String)
        case interruptionEnded
        case runtimeError(String)
        case activeDeviceDisconnected(String)
        case preferredDeviceConnected(String)
        case willSleep
        case didWake
    }

    enum Action: Equatable {
        case cancelCapture(String)
        case stopSession
        case recover(reconfigure: Bool, reason: String)
    }

    let keepsSessionWarm: Bool
    private(set) var isCapturing = false
    private(set) var isSleeping = false
    private(set) var isInterrupted = false

    var wantsSessionRunning: Bool {
        !isSleeping && !isInterrupted && (keepsSessionWarm || isCapturing)
    }

    @discardableResult
    mutating func beginCapture() -> Bool {
        guard !isSleeping, !isInterrupted else { return false }
        isCapturing = true
        return true
    }

    @discardableResult
    mutating func endCapture() -> Bool {
        let wasCapturing = isCapturing
        isCapturing = false
        return wasCapturing
    }

    mutating func handle(_ event: Event) -> [Action] {
        var actions: [Action] = []
        switch event {
        case .sessionInterrupted(let reason):
            isInterrupted = true
            cancelIfNeeded(reason, into: &actions)

        case .interruptionEnded:
            isInterrupted = false
            if wantsSessionRunning {
                actions.append(.recover(reconfigure: false, reason: "capture interruption ended"))
            }

        case .runtimeError(let reason):
            cancelIfNeeded(reason, into: &actions)
            actions.append(.recover(reconfigure: true, reason: reason))

        case .activeDeviceDisconnected(let reason):
            cancelIfNeeded(reason, into: &actions)
            actions.append(.recover(reconfigure: true, reason: reason))

        case .preferredDeviceConnected(let name):
            cancelIfNeeded("preferred microphone reconnected", into: &actions)
            actions.append(.recover(
                reconfigure: true,
                reason: "preferred microphone reconnected: \(name)"
            ))

        case .willSleep:
            cancelIfNeeded("Mac went to sleep", into: &actions)
            isSleeping = true
            actions.append(.stopSession)

        case .didWake:
            isSleeping = false
            actions.append(.recover(reconfigure: true, reason: "Mac woke from sleep"))
        }
        return actions
    }

    private mutating func cancelIfNeeded(_ reason: String, into actions: inout [Action]) {
        if endCapture() {
            actions.append(.cancelCapture(reason))
        }
    }
}

/// Lock-protected admission state for live input replacement. Both capture
/// start and menu switching consult this while holding the same lock, making
/// the pre-roll/device boundary an atomic decision rather than a timing bet.
struct AudioInputSwitchGate: Equatable {
    private(set) var isSwitching = false

    var permitsCaptureStart: Bool { !isSwitching }

    mutating func begin(isCapturing: Bool) -> Bool {
        guard !isCapturing, !isSwitching else { return false }
        isSwitching = true
        return true
    }

    mutating func end() {
        isSwitching = false
    }
}

/// Captures microphone audio and returns 16 kHz mono Float32 when stopped.
///
/// Built on `AVCaptureSession` rather than `AVAudioEngine`, for one decisive
/// reason: `AVAudioEngine` binds and opens the *system default* input device the
/// instant `engine.inputNode` is touched, before any code can rebind it. When
/// the default is a Bluetooth headset that drags it off A2DP onto HFP and the
/// user's music collapses to call quality — even if we then select a different
/// mic. `AVCaptureSession` opens only the device it's given. Measured with a
/// WH-1000XM4 as system default while capturing from a USB mic:
///
///     AVAudioEngine      inputNode accessed -> headset 44100 Hz -> 16000 Hz
///     AVCaptureSession   full session cycle -> headset 44100 Hz throughout
///
/// The session also asks for 16 kHz mono Float32 directly via `audioSettings`,
/// which macOS honors, so there's no sample-rate conversion to do here.
///
/// The session runs continuously from `startSession()` rather than starting on
/// each keypress. Device startup costs ~170 ms before the first sample arrives,
/// which was clipping the front of every utterance; a hot session plus a
/// pre-roll ring buffer means a capture begins *before* the key went down. The
/// cost is that macOS shows the mic-in-use indicator the whole time parrot runs.
struct CapturedAudio: Sendable {
    let samples: [Float]?
    let fileURL: URL?
    let sampleRate: Int
    let sampleCount: Int
    let rms: Float

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(sampleCount) / TimeInterval(sampleRate)
    }

    var isEmpty: Bool { sampleCount == 0 }
}

final class AudioCapture: NSObject {
    struct InputStatus: Equatable, Sendable {
        let uid: String
        let name: String
        let isTemporaryFallback: Bool
    }

    enum InputSwitchResult: Equatable, Sendable {
        case switched(InputStatus)
        case busy
        case unavailable(String)
        case failed(String)
    }

    enum MemoryAction: Equatable {
        case append
        case switchToFile
    }
    enum CaptureError: LocalizedError {
        case deviceNotFound(String)
        case inputCreationFailed(Error)
        case cannotAddInput
        case cannotAddOutput
        case temporarilyUnavailable

        var errorDescription: String? {
            switch self {
            case .deviceNotFound(let identifier):
                return "microphone is unavailable: \(identifier)"
            case .inputCreationFailed(let error):
                return "couldn't open microphone input: \(error.localizedDescription)"
            case .cannotAddInput:
                return "capture session rejected the microphone input"
            case .cannotAddOutput:
                return "capture session rejected the audio output"
            case .temporarilyUnavailable:
                return "microphone is temporarily unavailable while the session recovers"
            }
        }
    }

    static let targetSampleRate: Double = 16_000
    /// The common path stays in memory; longer locked notes continue through
    /// the live WAV without capture RAM growing with their duration.
    static let maximumInMemorySeconds: TimeInterval = 120
    static let maximumInMemorySamples = Int(targetSampleRate * maximumInMemorySeconds)

    static func memoryAction(
        currentSamples: Int,
        incomingSamples: Int,
        hasLiveSpool: Bool
    ) -> MemoryAction {
        hasLiveSpool && currentSamples + incomingSamples > maximumInMemorySamples
            ? .switchToFile
            : .append
    }

    /// How much audio to keep from before the hotkey went down.
    static let preRollSeconds: Double = 0.3
    private static let preRollSamples = Int(targetSampleRate * preRollSeconds)

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(label: "ai.encore.parrot.audio")
    private let sessionQueue = DispatchQueue(label: "ai.encore.parrot.audio-session")

    private let lock = NSLock()
    private var captured: [Float] = []
    private var recordingSpool: LiveRecordingSpool?
    private var recordingIsFileBacked = false
    private var recoveryState: AudioRecoveryState

    /// Fixed-size circular pre-roll. Always written, even mid-capture, so the
    /// next capture is seeded correctly too.
    private var ring = [Float](repeating: 0, count: preRollSamples)
    private var ringWrite = 0
    private var ringCount = 0

    /// Accessed only on `sessionQueue`. A menu selection moves one device to
    /// the front while preserving the remaining automatic fallback order.
    private var preferredDeviceUIDs: [String]
    /// Startup's already-resolved automatic fallback (including an explicitly
    /// allowed Bluetooth default) when no ranked device is currently present.
    private let startupFallbackDeviceUID: String?
    private let usePreRoll: Bool
    private let liveRecordingURL: URL?
    /// Accessed only on `sessionQueue`.
    private var configured = false
    private var activeDeviceUID: String?
    private var activeDeviceName: String?
    private var recoveryGeneration = 0
    private var recoveryScheduled = false
    private var recoveryFailures = 0
    /// Protected by `lock`; consumed synchronously before a new capture.
    private var reconfigurationRequired = false
    /// Protected by `lock`; avoids scheduling work for every healthy buffer.
    private var needsAudioFlowConfirmation = false
    /// Protected by `lock`. A better mic that appears mid-dictation is
    /// promoted only after that capture ends, preserving one continuous source.
    private var pendingPreferredDevice: (uid: String, name: String)?
    /// Protected by `lock`. Starting a capture while the session input is
    /// being replaced could seed a note with pre-roll from the previous mic.
    private var inputSwitchGate = AudioInputSwitchGate()
    private var sessionObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Called for every buffer with its RMS level (0…~1). Arbitrary thread.
    var onLevel: ((Float) -> Void)?

    /// Operational messages such as disconnect/recovery. Arbitrary thread.
    var onStatus: ((String) -> Void)?

    /// Reports the input actually opened by AVFoundation, including temporary
    /// fallback state. Arbitrary thread; callers should hop to their UI queue.
    var onDeviceChanged: ((InputStatus) -> Void)?

    /// Connection notifications invalidate the menu's device list without
    /// requiring a timer or idle polling. Arbitrary thread.
    var onAvailableDevicesChanged: (() -> Void)?

    /// A partial recording was discarded because its audio stream became
    /// discontinuous. Arbitrary thread; callers should hop to their UI queue.
    var onCaptureInterrupted: ((String) -> Void)?

    /// The private live recovery stream failed. Continuing could silently
    /// truncate a long note, so callers should cancel the active gesture.
    var onCaptureStorageFailed: ((String) -> Void)?

    /// - Parameter usePreRoll: when false, the session only runs while the
    ///   hotkey is held (no mic indicator at idle, but the front of each
    ///   utterance is clipped).
    init(
        device: AudioInputDevice?,
        preferredDeviceUIDs: [String]? = nil,
        usePreRoll: Bool = true,
        liveRecordingURL: URL? = nil
    ) {
        let requested = preferredDeviceUIDs ?? device.map { [$0.uid] } ?? []
        self.preferredDeviceUIDs = AudioDevices.normalizedPriorityUIDs(requested)
        self.startupFallbackDeviceUID = device?.uid
        self.usePreRoll = usePreRoll
        self.liveRecordingURL = liveRecordingURL
        self.recoveryState = AudioRecoveryState(keepsSessionWarm: usePreRoll)
        super.init()
        installObservers()
    }

    deinit {
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Open the device and (when pre-rolling) begin streaming. Call once at
    /// startup, off the main thread — this is the slow part.
    func startSession() throws {
        try sessionQueue.sync {
            try configureIfNeeded()
            if usePreRoll, !session.isRunning {
                session.startRunning()
            }
        }
    }

    func stopSession() {
        sessionQueue.sync {
            recoveryGeneration += 1
            recoveryScheduled = false
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Begin recording. Idempotent.
    func start() throws {
        let newSpool = try liveRecordingURL.map {
            try LiveRecordingSpool(fileURL: $0, sampleRate: Int(Self.targetSampleRate))
        }
        lock.lock()
        guard inputSwitchGate.permitsCaptureStart else {
            newSpool?.cancel()
            lock.unlock()
            throw CaptureError.temporarilyUnavailable
        }
        captured.removeAll(keepingCapacity: true)
        recordingIsFileBacked = false
        if usePreRoll, ringCount > 0 {
            // Drain the ring oldest-first so the capture starts ~300 ms before
            // the keypress.
            captured.reserveCapacity(ringCount)
            let start = (ringWrite - ringCount + ring.count) % ring.count
            for i in 0..<ringCount {
                captured.append(ring[(start + i) % ring.count])
            }
        }
        do {
            try newSpool?.append(captured)
        } catch {
            newSpool?.cancel()
            captured.removeAll(keepingCapacity: true)
            lock.unlock()
            throw error
        }
        recordingSpool = newSpool
        guard recoveryState.beginCapture() else {
            recordingSpool?.cancel()
            recordingSpool = nil
            captured.removeAll(keepingCapacity: true)
            lock.unlock()
            throw CaptureError.temporarilyUnavailable
        }
        lock.unlock()

        do {
            try sessionQueue.sync {
                // A user-initiated capture takes precedence over a delayed
                // retry. Resolve any stale session before accepting samples so
                // recovery can never switch devices in the middle of a note.
                recoveryGeneration += 1
                recoveryScheduled = false
                recoveryFailures = 0
                if isReconfigurationRequired() {
                    resetConfiguration()
                }
                try configureIfNeeded()
                if !session.isRunning {
                    session.startRunning()
                }
                clearReconfigurationRequirement()
            }
        } catch {
            lock.lock()
            _ = recoveryState.endCapture()
            captured.removeAll(keepingCapacity: true)
            recordingSpool?.cancel()
            recordingSpool = nil
            recordingIsFileBacked = false
            lock.unlock()
            throw error
        }
    }

    /// Stop recording and return everything captured, pre-roll included.
    @discardableResult
    func stop() throws -> CapturedAudio {
        lock.lock()
        let wasCapturing = recoveryState.endCapture()
        let out = captured
        captured.removeAll(keepingCapacity: true)
        let spool = recordingSpool
        recordingSpool = nil
        let fileBacked = recordingIsFileBacked
        recordingIsFileBacked = false
        let pendingPromotion = pendingPreferredDevice
        pendingPreferredDevice = nil
        lock.unlock()

        // Without pre-roll there's no reason to hold the device open at idle.
        if !usePreRoll {
            sessionQueue.sync {
                recoveryGeneration += 1
                recoveryScheduled = false
                if session.isRunning { session.stopRunning() }
            }
        }
        if let pendingPromotion {
            sessionQueue.async { [weak self] in
                self?.handlePreferredDeviceConnected(
                    uid: pendingPromotion.uid,
                    name: pendingPromotion.name
                )
            }
        }
        guard wasCapturing else {
            spool?.cancel()
            return CapturedAudio(
                samples: [], fileURL: nil, sampleRate: Int(Self.targetSampleRate),
                sampleCount: 0, rms: 0
            )
        }
        if let summary = try spool?.finish() {
            return CapturedAudio(
                samples: fileBacked ? nil : out,
                fileURL: summary.fileURL,
                sampleRate: summary.sampleRate,
                sampleCount: summary.sampleCount,
                rms: summary.rms
            )
        }
        return CapturedAudio(
            samples: out,
            fileURL: nil,
            sampleRate: Int(Self.targetSampleRate),
            sampleCount: out.count,
            rms: computeRMS(out)
        )
    }

    /// Escape/capture interruption discards the live spool instead of making
    /// it available for transcription or retry.
    func cancel() {
        lock.lock()
        _ = recoveryState.endCapture()
        captured.removeAll(keepingCapacity: true)
        let spool = recordingSpool
        recordingSpool = nil
        recordingIsFileBacked = false
        let pendingPromotion = pendingPreferredDevice
        pendingPreferredDevice = nil
        lock.unlock()
        spool?.cancel()

        if !usePreRoll {
            sessionQueue.sync {
                recoveryGeneration += 1
                recoveryScheduled = false
                if session.isRunning { session.stopRunning() }
            }
        }
        if let pendingPromotion {
            sessionQueue.async { [weak self] in
                self?.handlePreferredDeviceConnected(
                    uid: pendingPromotion.uid,
                    name: pendingPromotion.name
                )
            }
        }
    }

    /// Replace the live AVCaptureSession input without blocking the main
    /// thread. Switching is deliberately rejected during capture so one note
    /// can never contain audio from two microphones.
    func switchInput(
        toUID uid: String,
        name: String,
        priorityUIDs: [String],
        completion: @escaping @Sendable (InputSwitchResult) -> Void
    ) {
        let priorities = AudioDevices.priorities(selecting: uid, existing: priorityUIDs)
        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.lock.lock()
            guard self.inputSwitchGate.begin(
                isCapturing: self.recoveryState.isCapturing
            ) else {
                self.lock.unlock()
                completion(.busy)
                return
            }
            self.lock.unlock()

            defer {
                self.lock.lock()
                self.inputSwitchGate.end()
                self.lock.unlock()
            }

            guard let selected = AVCaptureDevice(uniqueID: uid),
                  selected.isConnected,
                  selected.hasMediaType(.audio)
            else {
                completion(.unavailable(name))
                return
            }

            let previousPriorities = self.preferredDeviceUIDs
            self.preferredDeviceUIDs = priorities
            if self.activeDeviceUID == uid {
                let status = self.currentInputStatus()
                self.onDeviceChanged?(status)
                completion(.switched(status))
                return
            }

            self.lock.lock()
            self.ringWrite = 0
            self.ringCount = 0
            self.pendingPreferredDevice = nil
            self.lock.unlock()
            self.recoveryGeneration += 1
            self.recoveryScheduled = false
            self.recoveryFailures = 0

            do {
                self.resetConfiguration()
                try self.configureIfNeeded()
                if self.usePreRoll, !self.session.isRunning {
                    self.session.startRunning()
                }
                self.clearReconfigurationRequirement()
                let status = self.currentInputStatus()
                guard status.uid == uid else {
                    throw CaptureError.deviceNotFound(name)
                }
                completion(.switched(status))
            } catch {
                let selectionError = error.localizedDescription
                self.preferredDeviceUIDs = previousPriorities
                self.resetConfiguration()
                do {
                    try self.configureIfNeeded()
                    if self.usePreRoll, !self.session.isRunning {
                        self.session.startRunning()
                    }
                    self.clearReconfigurationRequirement()
                } catch {
                    self.lock.lock()
                    self.reconfigurationRequired = true
                    self.lock.unlock()
                    self.requestRecovery(
                        reconfigure: true,
                        reason: "restoring microphone after failed live switch"
                    )
                }
                completion(.failed(selectionError))
            }
        }
    }

    // MARK: -

    private func configureIfNeeded() throws {
        guard !configured else { return }

        let device = try resolveDevice()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureError.inputCreationFailed(error)
        }
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)

        // macOS honors this exactly, so no resampling is needed downstream.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Int(Self.targetSampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        if !session.outputs.contains(where: { $0 === output }) {
            guard session.canAddOutput(output) else {
                session.removeInput(input)
                throw CaptureError.cannotAddOutput
            }
            session.addOutput(output)
        }

        activeDeviceUID = device.uniqueID
        activeDeviceName = device.localizedName
        configured = true
        onDeviceChanged?(currentInputStatus())
    }

    private func currentInputStatus() -> InputStatus {
        let uid = activeDeviceUID ?? ""
        return InputStatus(
            uid: uid,
            name: activeDeviceName ?? "system default",
            isTemporaryFallback: preferredDeviceUIDs.first.map { $0 != uid } ?? false
        )
    }

    /// Tear down stale input objects after wake, media-service reset, or a
    /// device change. The output and delegate can be reused safely.
    private func resetConfiguration() {
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for input in session.inputs {
            session.removeInput(input)
        }
        session.commitConfiguration()
        configured = false
        activeDeviceUID = nil
        activeDeviceName = nil
    }

    /// Map our CoreAudio device onto an `AVCaptureDevice`. UIDs line up between
    /// the two APIs, and direct lookup avoids AVFoundation's noisy microphone
    /// discovery path (which currently emits a false Continuity Camera warning).
    private func resolveDevice() throws -> AVCaptureDevice {
        for uid in preferredDeviceUIDs {
            if let device = AVCaptureDevice(uniqueID: uid),
               device.isConnected,
               device.hasMediaType(.audio) {
                return device
            }
        }
        if !preferredDeviceUIDs.isEmpty {
            if let uid = startupFallbackDeviceUID,
               !preferredDeviceUIDs.contains(uid),
               let device = AVCaptureDevice(uniqueID: uid),
               device.isConnected,
               device.hasMediaType(.audio) {
                return device
            }
            // Keep dictation available when every ranked USB/interface mic is
            // unplugged. Never prefer Bluetooth for this fallback because that
            // would silently degrade headphone playback to call quality.
            if let fallbackUID = AudioDevices.recoveryFallback(
                from: AudioDevices.inputs(),
                defaultDeviceID: AudioDevices.defaultInput()?.id,
                excluding: Set(preferredDeviceUIDs)
            )?.uid,
               let fallback = AVCaptureDevice(uniqueID: fallbackUID),
               fallback.isConnected,
               fallback.hasMediaType(.audio)
            {
                return fallback
            }
            throw CaptureError.deviceNotFound(preferredDeviceUIDs.joined(separator: ", "))
        }
        guard let fallback = AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.deviceNotFound("default")
        }
        return fallback
    }

    private func installObservers() {
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.handleRecoveryEvent(.sessionInterrupted("microphone session was interrupted"))
        })
        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.handleRecoveryEvent(.interruptionEnded)
        })
        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            let reason = error.map { "microphone runtime error: \($0.localizedDescription)" }
                ?? "microphone runtime error"
            self?.handleRecoveryEvent(.runtimeError(reason))
        })
        sessionObservers.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice else { return }
            self?.onAvailableDevicesChanged?()
            self?.sessionQueue.async { [weak self] in
                guard let self, device.uniqueID == self.activeDeviceUID else { return }
                self.handleRecoveryEvent(
                    .activeDeviceDisconnected("microphone disconnected: \(device.localizedName)")
                )
            }
        })
        sessionObservers.append(center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let device = notification.object as? AVCaptureDevice
            else { return }
            self.onAvailableDevicesChanged?()
            let uid = device.uniqueID
            let name = device.localizedName
            self.sessionQueue.async { [weak self] in
                self?.handlePreferredDeviceConnected(uid: uid, name: name)
            }
        })

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleRecoveryEvent(.willSleep)
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleRecoveryEvent(.didWake)
        })
    }

    private func handleRecoveryEvent(_ event: AudioRecoveryState.Event) {
        lock.lock()
        let actions = recoveryState.handle(event)
        // Pre-roll must never bridge a device, interruption, or sleep boundary;
        // otherwise an immediate post-recovery capture can contain stale audio.
        ringWrite = 0
        ringCount = 0
        if actions.contains(where: {
            if case .cancelCapture = $0 { return true }
            return false
        }) {
            captured.removeAll(keepingCapacity: true)
        }
        if actions.contains(where: {
            if case .recover(reconfigure: true, reason: _) = $0 { return true }
            return false
        }) {
            reconfigurationRequired = true
        }
        lock.unlock()

        applyRecoveryActions(actions)
    }

    /// Evaluate rank and capture state atomically. This closes the boundary
    /// where a new recording could begin between a connection check and the
    /// reconfiguration event, causing the old single-mic behavior to cancel it.
    private func handlePreferredDeviceConnected(uid: String, name: String) {
        lock.lock()
        let promotion = AudioDevices.promotion(
            connectedUID: uid,
            over: activeDeviceUID,
            priorityUIDs: preferredDeviceUIDs,
            isCapturing: recoveryState.isCapturing
        )
        switch promotion {
        case .none:
            lock.unlock()
            return
        case .afterCapture:
            pendingPreferredDevice = (uid, name)
            lock.unlock()
            onStatus?("higher-priority microphone connected · switching after this dictation")
            return
        case .immediately:
            let actions = recoveryState.handle(.preferredDeviceConnected(name))
            ringWrite = 0
            ringCount = 0
            reconfigurationRequired = true
            lock.unlock()
            applyRecoveryActions(actions)
        }
    }

    private func applyRecoveryActions(_ actions: [AudioRecoveryState.Action]) {
        for action in actions {
            switch action {
            case .cancelCapture(let reason):
                onCaptureInterrupted?(reason)
            case .stopSession:
                sessionQueue.async { [weak self] in
                    guard let self else { return }
                    self.recoveryGeneration += 1
                    self.recoveryScheduled = false
                    if self.session.isRunning { self.session.stopRunning() }
                }
            case .recover(let reconfigure, let reason):
                requestRecovery(reconfigure: reconfigure, reason: reason)
            }
        }
    }

    private func requestRecovery(reconfigure: Bool, reason: String) {
        sessionQueue.async { [weak self] in
            guard let self, !self.recoveryScheduled else { return }
            guard self.wantsSessionRunning() else {
                if reconfigure || self.isReconfigurationRequired() {
                    self.resetConfiguration()
                    self.clearReconfigurationRequirement()
                }
                return
            }
            let delay = Self.recoveryDelays[min(self.recoveryFailures, Self.recoveryDelays.count - 1)]
            self.recoveryFailures += 1
            self.recoveryGeneration += 1
            let generation = self.recoveryGeneration
            self.recoveryScheduled = true
            self.lock.lock()
            self.needsAudioFlowConfirmation = true
            self.lock.unlock()
            self.onStatus?(String(
                format: "microphone recovery scheduled in %.2fs · %@",
                delay,
                reason
            ))
            self.sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.recoveryGeneration == generation else { return }
                guard self.wantsSessionRunning() else {
                    self.recoveryScheduled = false
                    if reconfigure || self.isReconfigurationRequired() {
                        self.resetConfiguration()
                        self.clearReconfigurationRequirement()
                    }
                    return
                }
                self.recoveryScheduled = false
                do {
                    if reconfigure || self.isReconfigurationRequired() {
                        self.resetConfiguration()
                    }
                    try self.configureIfNeeded()
                    if !self.session.isRunning { self.session.startRunning() }
                    self.clearReconfigurationRequirement()
                    let name = self.activeDeviceName ?? "system default"
                    let fallback = self.preferredDeviceUIDs.first.map {
                        self.activeDeviceUID != $0
                    } ?? false
                    self.onStatus?(
                        "✓ microphone recovered · \(name)\(fallback ? " · temporary fallback" : "")"
                    )
                } catch {
                    self.onStatus?("microphone recovery failed: \(error.localizedDescription)")
                    self.requestRecovery(reconfigure: true, reason: reason)
                }
            }
        }
    }

    private func wantsSessionRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return recoveryState.wantsSessionRunning
    }

    private func markAudioFlowing() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.recoveryFailures = 0
        }
    }

    private func isReconfigurationRequired() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reconfigurationRequired
    }

    private func clearReconfigurationRequirement() {
        lock.lock()
        reconfigurationRequired = false
        lock.unlock()
    }

    static let recoveryDelays: [TimeInterval] = [0, 0.25, 1, 3, 10]
}

extension AudioCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(&abl)
        guard let data = buffers[0].mData else { return }
        let count = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let samples = UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Float.self),
            count: count
        )

        lock.lock()
        let isCapturing = recoveryState.isCapturing
        var storageFailure: String?
        if isCapturing {
            do {
                try recordingSpool?.append(samples)
                if !recordingIsFileBacked {
                    switch Self.memoryAction(
                        currentSamples: captured.count,
                        incomingSamples: samples.count,
                        hasLiveSpool: recordingSpool != nil
                    ) {
                    case .append:
                        captured.append(contentsOf: samples)
                    case .switchToFile:
                        captured.removeAll(keepingCapacity: false)
                        recordingIsFileBacked = true
                    }
                }
            } catch {
                storageFailure = error.localizedDescription
                _ = recoveryState.endCapture()
                captured.removeAll(keepingCapacity: false)
                recordingSpool?.cancel()
                recordingSpool = nil
                recordingIsFileBacked = false
            }
        }
        if usePreRoll {
            for s in samples {
                ring[ringWrite] = s
                ringWrite = (ringWrite + 1) % ring.count
                if ringCount < ring.count { ringCount += 1 }
            }
        }
        let confirmsRecovery = needsAudioFlowConfirmation
        needsAudioFlowConfirmation = false
        lock.unlock()

        if let storageFailure { onCaptureStorageFailed?(storageFailure) }
        if confirmsRecovery { markAudioFlowing() }

        // A warm session streams continuously for pre-roll. Waveform work is
        // useful only during an active capture: skipping RMS here removes an
        // O(samples) pass and a UI hop from every idle audio buffer.
        if shouldEmitAudioLevel(isCapturing: isCapturing, hasConsumer: onLevel != nil),
           let onLevel {
            onLevel(computeRMS(samples))
        }
    }
}

// MARK: - WAV writer (for debugging captures)

enum WAVWriter {
    /// Write Float32 mono samples as 16-bit PCM WAV to `path`.
    static func write(samples: [Float], sampleRate: Int, to path: String) throws {
        let bytesPerSample = 2
        let (dataSize, overflow) = samples.count.multipliedReportingOverflow(by: bytesPerSample)
        guard !overflow, dataSize <= Int(UInt32.max) - 36 else {
            throw CocoaError(.fileWriteOutOfSpace)
        }

        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(uint32LE(36 + UInt32(dataSize)))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(uint32LE(16))                       // fmt chunk size
        header.append(uint16LE(1))                        // PCM
        header.append(uint16LE(1))                        // mono
        header.append(uint32LE(UInt32(sampleRate)))
        header.append(uint32LE(UInt32(sampleRate * bytesPerSample)))
        header.append(uint16LE(UInt16(bytesPerSample)))   // block align
        header.append(uint16LE(16))                       // bits per sample
        header.append(contentsOf: Array("data".utf8))
        header.append(uint32LE(UInt32(dataSize)))

        let fileManager = FileManager.default
        guard fileManager.createFile(
            atPath: path,
            contents: header,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()

        // Stream conversion in modest chunks. A long hands-free note already
        // occupies one Float array; building a second whole-file Data buffer
        // here would add avoidable memory pressure at the latency-critical
        // transition from recording to inference.
        let chunkSize = 8_192
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            var pcm = Data(capacity: (end - offset) * bytesPerSample)
            for sample in samples[offset..<end] {
                let clamped = max(-1.0, min(1.0, sample))
                let value = Int16(clamped * 32767.0)
                pcm.append(uint16LE(UInt16(bitPattern: value)))
            }
            try handle.write(contentsOf: pcm)
            offset = end
        }
        try handle.synchronize()
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }
    private static func uint16LE(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }
}

@inline(__always)
func shouldEmitAudioLevel(isCapturing: Bool, hasConsumer: Bool) -> Bool {
    isCapturing && hasConsumer
}

func computeRMS<S: Collection>(_ samples: S) -> Float where S.Element == Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Double = 0
    for s in samples { sum += Double(s * s) }
    return Float((sum / Double(samples.count)).squareRoot())
}

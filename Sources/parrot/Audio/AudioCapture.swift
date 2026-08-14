import AVFoundation
import CoreAudio
import Foundation

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
final class AudioCapture: NSObject {
    enum CaptureError: Error {
        case deviceNotFound(String)
        case inputCreationFailed(Error)
        case cannotAddInput
        case cannotAddOutput
    }

    static let targetSampleRate: Double = 16_000

    /// How much audio to keep from before the hotkey went down.
    static let preRollSeconds: Double = 0.3
    private static let preRollSamples = Int(targetSampleRate * preRollSeconds)

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(label: "ai.encore.parrot.audio")

    private let lock = NSLock()
    private var captured: [Float] = []
    private var capturing = false

    /// Fixed-size circular pre-roll. Always written, even mid-capture, so the
    /// next capture is seeded correctly too.
    private var ring = [Float](repeating: 0, count: preRollSamples)
    private var ringWrite = 0
    private var ringCount = 0

    private let deviceUID: String?
    private let deviceName: String?
    private let usePreRoll: Bool
    private var configured = false

    /// Called for every buffer with its RMS level (0…~1). Arbitrary thread.
    var onLevel: ((Float) -> Void)?

    /// - Parameter usePreRoll: when false, the session only runs while the
    ///   hotkey is held (no mic indicator at idle, but the front of each
    ///   utterance is clipped).
    init(device: AudioInputDevice?, usePreRoll: Bool = true) {
        self.deviceUID = device?.uid
        self.deviceName = device?.name
        self.usePreRoll = usePreRoll
        super.init()
    }

    /// Open the device and (when pre-rolling) begin streaming. Call once at
    /// startup, off the main thread — this is the slow part.
    func startSession() throws {
        try configureIfNeeded()
        if usePreRoll, !session.isRunning {
            session.startRunning()
        }
    }

    func stopSession() {
        if session.isRunning { session.stopRunning() }
    }

    /// Begin recording. Idempotent.
    func start() throws {
        try configureIfNeeded()
        if !session.isRunning {
            session.startRunning()
        }

        lock.lock()
        captured.removeAll(keepingCapacity: true)
        if usePreRoll, ringCount > 0 {
            // Drain the ring oldest-first so the capture starts ~300 ms before
            // the keypress.
            captured.reserveCapacity(ringCount)
            let start = (ringWrite - ringCount + ring.count) % ring.count
            for i in 0..<ringCount {
                captured.append(ring[(start + i) % ring.count])
            }
        }
        capturing = true
        lock.unlock()
    }

    /// Stop recording and return everything captured, pre-roll included.
    @discardableResult
    func stop() -> [Float] {
        lock.lock()
        let wasCapturing = capturing
        capturing = false
        let out = captured
        captured.removeAll(keepingCapacity: true)
        lock.unlock()

        // Without pre-roll there's no reason to hold the device open at idle.
        if !usePreRoll, session.isRunning {
            session.stopRunning()
        }
        return wasCapturing ? out : []
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
        guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
        session.addOutput(output)

        configured = true
    }

    /// Map our CoreAudio device onto an `AVCaptureDevice`. UIDs line up between
    /// the two APIs; the name is a fallback for anything that doesn't match.
    private func resolveDevice() throws -> AVCaptureDevice {
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices

        if let uid = deviceUID, let match = discovered.first(where: { $0.uniqueID == uid }) {
            return match
        }
        if let name = deviceName, let match = discovered.first(where: { $0.localizedName == name }) {
            return match
        }
        if deviceUID == nil, let fallback = AVCaptureDevice.default(for: .audio) {
            return fallback
        }
        throw CaptureError.deviceNotFound(deviceName ?? deviceUID ?? "default")
    }
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
        let chunk = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))

        lock.lock()
        if capturing {
            captured.append(contentsOf: chunk)
        }
        if usePreRoll {
            for s in chunk {
                ring[ringWrite] = s
                ringWrite = (ringWrite + 1) % ring.count
                if ringCount < ring.count { ringCount += 1 }
            }
        }
        lock.unlock()

        if let onLevel {
            onLevel(computeRMS(chunk))
        }
    }
}

// MARK: - WAV writer (for debugging captures)

enum WAVWriter {
    /// Write Float32 mono samples as 16-bit PCM WAV to `path`.
    static func write(samples: [Float], sampleRate: Int, to path: String) throws {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(uint32LE(36 + UInt32(dataSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(uint32LE(16))                       // fmt chunk size
        data.append(uint16LE(1))                        // PCM
        data.append(uint16LE(1))                        // mono
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(UInt32(sampleRate * bytesPerSample)))
        data.append(uint16LE(UInt16(bytesPerSample)))   // block align
        data.append(uint16LE(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(uint32LE(UInt32(dataSize)))

        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i = Int16(clamped * 32767.0)
            data.append(uint16LE(UInt16(bitPattern: i)))
        }

        try data.write(to: URL(fileURLWithPath: path))
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

func computeRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Double = 0
    for s in samples { sum += Double(s * s) }
    return Float((sum / Double(samples.count)).squareRoot())
}

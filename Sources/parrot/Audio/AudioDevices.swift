import CoreAudio
import Foundation

/// CoreAudio input-device enumeration and selection.
///
/// This exists for one reason: Bluetooth headsets can't do high-quality
/// playback and microphone capture at the same time. Opening the mic on a
/// WH-1000XM4 / AirPods forces the headset off A2DP (stereo, 44.1 kHz) and onto
/// HFP/SCO (mono, 16 kHz), and whatever you were listening to collapses to
/// telephone quality until the mic closes.
///
/// So by default parrot refuses to record from a Bluetooth input when any wired
/// or built-in mic is available. Dictation loses nothing — Whisper resamples to
/// 16 kHz regardless, and a headset mic *is* 16 kHz mono — while your music
/// stays in A2DP.
struct AudioInputDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let transport: UInt32
    let inputChannels: Int

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    /// Virtual devices (Zoom, Loopback, iPhone continuity mics) are poor
    /// automatic choices — they may be silent or route through another app.
    var isVirtual: Bool {
        transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeUnknown
    }

    var transportName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypePCI: return "pci"
        case kAudioDeviceTransportTypeFireWire: return "firewire"
        default: return "unknown"
        }
    }
}

enum AudioDevices {
    /// Every device with at least one input channel.
    static func inputs() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
            ) == noErr
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
            ) == noErr
        else { return [] }

        return ids.compactMap(describe).filter { $0.inputChannels > 0 }
    }

    static func defaultInput() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
            ) == noErr, id != 0
        else { return nil }
        return describe(id)
    }

    /// Resolve `--input-device`. Matches a UID exactly, or a name
    /// case-insensitively by prefix/substring so `--input-device brio` works.
    static func find(_ query: String) -> AudioInputDevice? {
        let devices = inputs()
        let q = query.lowercased()
        if let exact = devices.first(where: { $0.uid.lowercased() == q }) { return exact }
        if let exact = devices.first(where: { $0.name.lowercased() == q }) { return exact }
        return devices.first { $0.name.lowercased().contains(q) }
    }

    /// The device parrot should record from — the system default, or the best
    /// wired alternative when the default is Bluetooth.
    static func preferred(allowBluetooth: Bool) -> AudioInputDevice? {
        guard let systemDefault = defaultInput() else { return nil }
        if allowBluetooth || !systemDefault.isBluetooth { return systemDefault }

        let candidates = inputs().filter { !$0.isBluetooth && !$0.isVirtual }
        return candidates.first(where: \.isBuiltIn) ?? candidates.first ?? systemDefault
    }

    /// Warn when the *system default* input is a Bluetooth device.
    ///
    /// This keys off the system default rather than whatever `--input-device`
    /// selected, and that distinction is the whole point. `AVAudioEngine` binds
    /// and opens the default input device the instant `engine.inputNode` is
    /// touched — before any code gets a chance to rebind it. Measured:
    ///
    ///     0 start              headset=44100 Hz
    ///     1 engine created     headset=44100 Hz
    ///     2 inputNode accessed headset=16000 Hz   <-- already too late
    ///
    /// So `--input-device` controls which mic the samples come from, but it
    /// cannot stop a Bluetooth *default* from being dragged onto HFP, which is
    /// what wrecks playback quality. Only changing the system default input (or
    /// rewriting this on AUHAL, which never touches the default) avoids it.
    static func bluetoothDefaultWarning() -> String? {
        guard let systemDefault = defaultInput(), systemDefault.isBluetooth else { return nil }

        let alternatives = inputs().filter { !$0.isBluetooth && !$0.isVirtual }
        let suggestion = alternatives.first(where: \.isBuiltIn) ?? alternatives.first

        var lines = [
            "warning: your default input is \(systemDefault.name), a Bluetooth device.",
            "  macOS can't run high-quality playback and mic capture on the same Bluetooth",
            "  headset, so recording will drop it to call quality until parrot lets go.",
        ]
        if let suggestion {
            lines.append("  fix: System Settings → Sound → Input → \(suggestion.name)")
        }
        return lines.joined(separator: "\n")
    }

    /// True when there's a terminal to prompt at. Under `launchd` there isn't,
    /// and blocking a background daemon on `readLine()` would hang it forever.
    static var isInteractive: Bool { isatty(STDIN_FILENO) == 1 }

    /// Interactive microphone picker. Enter accepts the suggested device, so
    /// the common case is one keystroke.
    static func prompt(suggested: AudioInputDevice?) -> AudioInputDevice? {
        let devices = inputs()
        guard !devices.isEmpty else { return nil }
        guard devices.count > 1 else { return devices.first }

        func render() {
            var out = "\nmicrophone:\n"
            for (i, d) in devices.enumerated() {
                let mark = d.id == suggested?.id ? "★" : " "
                var tags = [d.transportName]
                if d.isBluetooth { tags.append("⚠ drops headset playback to call quality") }
                if d.isVirtual { tags.append("⚠ virtual — may be silent") }
                let name = d.name.padding(toLength: 30, withPad: " ", startingAt: 0)
                out += "  \(mark) \(i + 1)) \(name) \(tags.joined(separator: ", "))\n"
            }
            out += "choose [1-\(devices.count)], or Enter for ★: "
            FileHandle.standardError.write(Data(out.utf8))
        }

        for attempt in 0..<3 {
            render()
            guard let line = readLine(strippingNewline: true) else { return suggested }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return suggested }
            if let n = Int(trimmed), n >= 1, n <= devices.count { return devices[n - 1] }
            if let byName = find(trimmed) { return byName }
            if attempt < 2 {
                FileHandle.standardError.write(Data("  no match for '\(trimmed)'\n".utf8))
            }
        }
        FileHandle.standardError.write(Data("  giving up — using ★\n".utf8))
        return suggested
    }

    // MARK: -

    private static func describe(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
        return AudioInputDevice(
            id: id,
            name: name,
            uid: uid,
            transport: uint32Property(id, kAudioDevicePropertyTransportType) ?? 0,
            inputChannels: inputChannelCount(id)
        )
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String
    }

    private static func uint32Property(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

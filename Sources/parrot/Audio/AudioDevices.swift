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
    enum Promotion: Equatable {
        case none
        case immediately
        case afterCapture
    }

    /// Keep configuration and connection-event comparisons bounded. Eight is
    /// already more physical microphones than a typical Mac setup exposes.
    static let maximumPriorityCount = 8

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
        find(query, in: inputs())
    }

    static func find(_ query: String, in devices: [AudioInputDevice]) -> AudioInputDevice? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        if let exact = devices.first(where: { $0.uid.lowercased() == q }) { return exact }
        if let exact = devices.first(where: { $0.name.lowercased() == q }) { return exact }
        return devices.first { $0.name.lowercased().contains(q) }
    }

    /// De-duplicate user-edited config without changing its explicit order.
    static func normalizedPriorityUIDs(_ rawUIDs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(min(rawUIDs.count, maximumPriorityCount))
        for rawUID in rawUIDs {
            let uid = rawUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uid.isEmpty, seen.insert(uid).inserted else { continue }
            result.append(uid)
            if result.count == maximumPriorityCount { break }
        }
        return result
    }

    /// Select the first currently connected device in the user's saved order.
    static func highestPriority(
        from devices: [AudioInputDevice],
        priorityUIDs: [String]
    ) -> AudioInputDevice? {
        for uid in normalizedPriorityUIDs(priorityUIDs) {
            if let device = devices.first(where: { $0.uid == uid }) { return device }
        }
        return nil
    }

    /// A connection deserves promotion only when it outranks the active mic.
    /// An unranked active mic is a temporary fallback and loses to any ranked
    /// device; a lower-ranked connection never disrupts a better active mic.
    static func shouldPromote(
        connectedUID: String,
        over activeUID: String?,
        priorityUIDs: [String]
    ) -> Bool {
        guard let activeUID else { return false }
        // Capture stores a normalized list already. A slice retains the hard
        // bound for callers without allocating on a connection notification.
        let priorities = priorityUIDs.prefix(maximumPriorityCount)
        guard let connectedRank = priorities.firstIndex(of: connectedUID),
              connectedUID != activeUID
        else { return false }
        guard let activeRank = priorities.firstIndex(of: activeUID) else { return true }
        return connectedRank < activeRank
    }

    static func promotion(
        connectedUID: String,
        over activeUID: String?,
        priorityUIDs: [String],
        isCapturing: Bool
    ) -> Promotion {
        guard shouldPromote(
            connectedUID: connectedUID,
            over: activeUID,
            priorityUIDs: priorityUIDs
        ) else { return .none }
        return isCapturing ? .afterCapture : .immediately
    }

    /// The device parrot should record from — the system default, or the best
    /// wired alternative when the default is Bluetooth.
    static func preferred(allowBluetooth: Bool) -> AudioInputDevice? {
        guard let systemDefault = defaultInput() else { return nil }
        if allowBluetooth || !systemDefault.isBluetooth { return systemDefault }

        let candidates = inputs().filter { !$0.isBluetooth && !$0.isVirtual }
        return candidates.first(where: \.isBuiltIn) ?? candidates.first ?? systemDefault
    }

    /// Safe temporary input after the active device disappears. Recovery must
    /// not silently choose Bluetooth (which degrades playback) or a virtual
    /// device (which may carry no microphone audio at all).
    static func recoveryFallback(excluding excludedUID: String) -> AudioInputDevice? {
        recoveryFallback(
            from: inputs(),
            defaultDeviceID: defaultInput()?.id,
            excluding: [excludedUID]
        )
    }

    static func recoveryFallback(
        from devices: [AudioInputDevice],
        defaultDeviceID: AudioDeviceID?,
        excluding excludedUID: String
    ) -> AudioInputDevice? {
        recoveryFallback(
            from: devices,
            defaultDeviceID: defaultDeviceID,
            excluding: [excludedUID]
        )
    }

    static func recoveryFallback(
        from devices: [AudioInputDevice],
        defaultDeviceID: AudioDeviceID?,
        excluding excludedUIDs: Set<String>
    ) -> AudioInputDevice? {
        let safe = devices.filter {
            !excludedUIDs.contains($0.uid) && !$0.isBluetooth && !$0.isVirtual
        }
        if let defaultDeviceID,
           let systemDefault = safe.first(where: { $0.id == defaultDeviceID })
        {
            return systemDefault
        }
        return safe.first(where: \.isBuiltIn) ?? safe.first
    }

    /// Warn when the mic parrot will actually record from is Bluetooth.
    ///
    /// Note this keys off the *selected* device, not the system default. That
    /// used to be the other way round: `AVAudioEngine` opened the default input
    /// the instant `engine.inputNode` was touched, so a Bluetooth default got
    /// degraded no matter which mic you picked. `AudioCapture` is built on
    /// `AVCaptureSession` now, which opens only the device it's handed — so a
    /// Bluetooth device sitting there as the system default is harmless, and
    /// warning about it would just be noise.
    static func bluetoothWarning(for device: AudioInputDevice?) -> String? {
        guard let device, device.isBluetooth else { return nil }

        let alternatives = inputs().filter { !$0.isBluetooth && !$0.isVirtual }
        let suggestion = alternatives.first(where: \.isBuiltIn) ?? alternatives.first

        var lines = [
            "warning: recording from \(device.name), a Bluetooth mic.",
            "  macOS can't run high-quality playback and mic capture on the same Bluetooth",
            "  headset, so its playback drops to call quality while parrot records.",
        ]
        if let suggestion {
            lines.append("  pick \(suggestion.name) instead to keep your audio intact.")
        }
        return lines.joined(separator: "\n")
    }

    /// True when there's a terminal to prompt at. Under `launchd` there isn't,
    /// and blocking a background daemon on `readLine()` would hang it forever.
    static var isInteractive: Bool { isatty(STDIN_FILENO) == 1 }

    /// Interactive microphone picker.
    ///
    /// - Parameter preselect: UID of the device to start the cursor on, so a
    ///   returning user's last choice is one Enter away.
    static func prompt(suggested: AudioInputDevice?, preselect: String? = nil) -> AudioInputDevice? {
        let devices = inputs()
        guard !devices.isEmpty else { return nil }
        guard devices.count > 1 else { return devices.first }

        // Start on the remembered device, else the recommended one.
        var initial = 0
        if let preselect, let i = devices.firstIndex(where: { $0.uid == preselect }) {
            initial = i
        } else if let suggested, let i = devices.firstIndex(where: { $0.id == suggested.id }) {
            initial = i
        }

        let options = devices.map { d -> TerminalSelect.Option in
            var warning: String?
            if d.isBluetooth { warning = "⚠ playback drops to call quality" }
            if d.isVirtual { warning = "⚠ virtual — may be silent" }
            var detail = d.transportName
            if d.id == suggested?.id { detail += " · recommended" }
            return TerminalSelect.Option(label: d.name, detail: detail, warning: warning)
        }

        if let picked = TerminalSelect.choose(
            title: "microphone",
            options: options,
            initial: initial,
            footer: "↑↓ to move · enter to choose"
        ) {
            return devices[picked]
        }

        // No usable terminal (or the user bailed) — fall back to typed input.
        return typedPrompt(devices: devices, suggested: suggested)
    }

    private static func typedPrompt(
        devices: [AudioInputDevice], suggested: AudioInputDevice?
    ) -> AudioInputDevice? {
        guard isInteractive else { return suggested }
        for attempt in 0..<3 {
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

            guard let line = readLine(strippingNewline: true) else { return suggested }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return suggested }
            if let n = Int(trimmed), n >= 1, n <= devices.count { return devices[n - 1] }
            if let byName = find(trimmed) { return byName }
            if attempt < 2 {
                FileHandle.standardError.write(Data("  no match for '\(trimmed)'\n".utf8))
            }
        }
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

import AppKit
import ArgumentParser
import Foundation
import WhisperKit

@main
struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Minimal macOS dictation daemon. Hold to talk or double-tap for hands-free.",
        version: AppVersion.current,
        subcommands: [
            Run.self, Setup.self, Doctor.self, Models.self,
            Hotkeys.self, Devices.self, Install.self, Update.self,
        ],
        defaultSubcommand: Run.self
    )
}

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List microphones you can pass to --input-device."
    )

    func run() throws {
        let devices = AudioDevices.inputs()
        guard !devices.isEmpty else {
            print("no input devices found")
            return
        }

        let systemDefault = AudioDevices.defaultInput()
        let preferred = AudioDevices.preferred(allowBluetooth: false)

        for d in devices {
            var marks: [String] = []
            if d.id == preferred?.id { marks.append("★ parrot") }
            if d.id == systemDefault?.id { marks.append("system default") }
            let suffix = marks.isEmpty ? "" : "  (\(marks.joined(separator: ", ")))"
            let name = d.name.padding(toLength: 30, withPad: " ", startingAt: 0)
            let transport = d.transportName.padding(toLength: 13, withPad: " ", startingAt: 0)
            print("  \(name) \(transport) \(d.inputChannels)ch\(suffix)")
        }

        if let warning = AudioDevices.bluetoothWarning(for: preferred) {
            print()
            print(warning)
        }
    }
}

struct Hotkeys: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the push-to-talk keys you can pass to --hotkey."
    )

    func run() throws {
        print("modifiers — inert on their own, so the keypress is left alone:")
        for h in Hotkey.all {
            guard case .modifier = h else { continue }
            let star = h.name == Hotkey.default.name ? "★" : " "
            print("  \(star) \(h.name)")
        }
        print()
        print("plain keys — parrot swallows these while it's running, so they")
        print("won't reach the app you're dictating into:")
        let keys = Hotkey.all.compactMap { if case .key(let n, _) = $0 { return n } else { return nil } }
        for row in stride(from: 0, to: keys.count, by: 6) {
            print("    \(keys[row..<min(row + 6, keys.count)].joined(separator: "  "))")
        }
        print()
        print("anything else — find its number with `parrot run --debug-hotkey`,")
        print("then pass it as `--hotkey keycode:<n>`. It'll be swallowed too.")
        print()
        print("★ = default")
        print()
        print("note: a third-party keyboard's Fn key is handled by the board's own")
        print("      firmware and never reaches macOS — only Apple keyboards send a")
        print("      real fn. Pick something else if you dictate from a mechanical.")
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print every keyboard event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to /tmp/parrot-last.wav for inspection.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.")
    var model: String?

    @Option(
        name: .long,
        help: "Push-to-talk key. Default: fn. Run `parrot hotkeys` for the list."
    )
    var hotkey: String?

    @Option(
        name: .long,
        help: "Microphone to record from (name or UID). Run `parrot devices` for the list."
    )
    var inputDevice: String?

    @Flag(
        name: .long,
        help: "Allow recording from a Bluetooth mic, which degrades headset playback quality."
    )
    var allowBluetoothInput: Bool = false

    @Flag(name: .long, help: "Skip the microphone prompt and use the default.")
    var noPickMic: Bool = false

    @Flag(
        name: .long,
        help: "Only open the mic while the hotkey is held. Clips the start of each utterance."
    )
    var coldMic: Bool = false

    @Flag(name: .long, help: "Lowercase all transcribed text.")
    var lowercase: Bool = false

    @Flag(name: .long, help: "Don't lowercase transcribed text.")
    var noLowercase: Bool = false

    @Flag(name: .long, help: "Don't save successful transcripts to local Markdown history.")
    var noHistory: Bool = false

    @Flag(name: .long, help: "Re-run first-time setup and overwrite saved preferences.")
    var reconfigure: Bool = false

    @Option(name: .customLong("wait-for-pid"), help: .hidden)
    var waitForPID: Int32?

    func run() throws {
        if let waitForPID {
            // Used by the updater: don't initialize a second daemon until the
            // old executable has restored its Fn preference and fully exited.
            for _ in 0..<100 where kill(waitForPID, 0) == 0 {
                usleep(100_000)
            }
        }
        StartupTUI.showLogo()

        let chosenHotkey: Hotkey
        if let raw = hotkey {
            guard let parsed = Hotkey.parse(raw) else {
                FileHandle.standardError.write(Data("unknown hotkey: \(raw)\n".utf8))
                FileHandle.standardError.write(Data("run `parrot hotkeys` to see the options.\n".utf8))
                throw ExitCode(1)
            }
            chosenHotkey = parsed
        } else {
            chosenHotkey = .default
        }

        let fnSystemAction: FnSystemActionOverride?
        if chosenHotkey.needsSystemActionDisabled {
            do {
                fnSystemAction = try FnSystemActionOverride()
            } catch {
                FileHandle.standardError.write(Data(
                    "couldn't disable macOS's Fn/Globe action: \(error.localizedDescription)\n".utf8
                ))
                FileHandle.standardError.write(Data(
                    "set System Settings → Keyboard → Press 🌐 key to → Do Nothing\n".utf8
                ))
                throw ExitCode(1)
            }
        } else {
            fnSystemAction = nil
        }
        let restoreFnSystemAction = {
            do {
                try fnSystemAction?.restore()
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: couldn't restore your macOS Fn/Globe action: \(error.localizedDescription)\n".utf8
                ))
            }
        }
        defer { restoreFnSystemAction() }

        if !skipDoctor {
            let checks = DoctorReport.run(includeFnKeyMapping: chosenHotkey.needsSystemActionDisabled)
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
                DoctorReport.print(checks)
                FileHandle.standardError.write(Data("\nfix the above or pass --skip-doctor\n".utf8))
                throw ExitCode(1)
            }
        }

        let chosenModel: TranscriptionModel
        if let id = model {
            guard let m = ModelRegistry.find(id) else {
                FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
                FileHandle.standardError.write(Data("run `parrot models list` to see options.\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        } else {
            guard let m = ModelRegistry.recommended() else {
                FileHandle.standardError.write(Data("no models registered\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        }

        var config = Config.load()
        if reconfigure {
            config = Config()
        }
        var configDirty = reconfigure

        // Pick the mic before anything slow happens, so a bad --input-device
        // fails immediately rather than after a model download.
        let chosenDevice: AudioInputDevice?
        if let query = inputDevice {
            guard let found = AudioDevices.find(query) else {
                FileHandle.standardError.write(Data("unknown input device: \(query)\n".utf8))
                FileHandle.standardError.write(Data("run `parrot devices` to see the options.\n".utf8))
                throw ExitCode(1)
            }
            chosenDevice = found
        } else {
            let suggested = AudioDevices.preferred(allowBluetooth: allowBluetoothInput)
            // Prompt only when there's a terminal to prompt at — under launchd
            // there isn't, and blocking a daemon on readLine() hangs it forever.
            if !noPickMic, AudioDevices.isInteractive {
                chosenDevice = AudioDevices.prompt(
                    suggested: suggested, preselect: config.inputDeviceUID
                )
            } else if let saved = config.inputDeviceUID, let remembered = AudioDevices.find(saved) {
                chosenDevice = remembered
            } else {
                chosenDevice = suggested
            }
        }
        if let uid = chosenDevice?.uid, uid != config.inputDeviceUID {
            config.inputDeviceUID = uid
            configDirty = true
        }

        // Lowercase: explicit flag wins, then a saved preference, then ask once.
        let lowercaseMode: Bool
        if lowercase || noLowercase {
            guard !(lowercase && noLowercase) else {
                FileHandle.standardError.write(Data(
                    "pass at most one of --lowercase or --no-lowercase\n".utf8
                ))
                throw ExitCode(64)
            }
            lowercaseMode = lowercase
        } else if let saved = config.lowercase {
            lowercaseMode = saved
        } else if TerminalSelect.isAvailable {
            // "Keep capitalization" is both first and preselected — the default
            // shouldn't be the second thing you read.
            let picked = TerminalSelect.choose(
                title: "lowercase mode",
                options: [
                    TerminalSelect.Option(
                        label: "keep capitalization",
                        detail: "\"Hey there.\"  (default)"
                    ),
                    TerminalSelect.Option(
                        label: "lowercase everything",
                        detail: "\"hey there.\""
                    ),
                ],
                initial: 0,
                footer: "↑↓ to move · enter to choose"
            )
            lowercaseMode = picked == 1
            config.lowercase = lowercaseMode
            configDirty = true
        } else {
            lowercaseMode = false
        }

        if configDirty {
            config.setupCompleted = true
            config.save()
        }

        if !allowBluetoothInput, let warning = AudioDevices.bluetoothWarning(for: chosenDevice) {
            FileHandle.standardError.write(Data("\(warning)\n".utf8))
        }

        let transcriber = WhisperKitTranscriber(model: chosenModel)
        let warmupSemaphore = DispatchSemaphore(value: 0)
        var warmupError: Error?
        Task.detached {
            do {
                try await transcriber.warmUp()
            } catch {
                warmupError = error
            }
            warmupSemaphore.signal()
        }
        warmupSemaphore.wait()
        if let warmupError {
            FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // `NSApp.terminate` ends the process from inside AppKit and does not
        // unwind this command's stack, so `defer` alone cannot restore the
        // preference on a normal quit. Keep the defer for startup failures and
        // also restore from AppKit's guaranteed clean-termination hook.
        let terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: app,
            queue: .main
        ) { _ in
            restoreFnSystemAction()
        }
        defer { NotificationCenter.default.removeObserver(terminationObserver) }

        let monitor = HotkeyMonitor(hotkey: chosenHotkey, debug: debugHotkey)
        let capture = AudioCapture(device: chosenDevice, usePreRoll: !coldMic)
        do {
            try capture.startSession()
        } catch {
            FileHandle.standardError.write(Data("failed to open microphone: \(error)\n".utf8))
            throw ExitCode(1)
        }
        let dumpWav = self.dumpWav
        let overlay: RecordingOverlay? = noOverlay ? nil : MainActor.assumeIsolated { RecordingOverlay() }
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        let menuBar = MainActor.assumeIsolated {
            MenuBarController(modelID: chosenModel.id, hotkeyName: chosenHotkey.name)
        }
        let history = noHistory ? nil : TranscriptHistory()

        let startRecording = {
            do {
                try capture.start()
                FileHandle.standardError.write(Data("● recording\n".utf8))
                MainActor.assumeIsolated {
                    overlay?.show(.recording)
                    menuBar.setRecording(true)
                }
            } catch {
                FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
            }
        }

        let stopRecording = {
            let samples = capture.stop()
            MainActor.assumeIsolated {
                overlay?.show(.transcribing)
                menuBar.setTranscribing()
            }
            let seconds = Double(samples.count) / AudioCapture.targetSampleRate
            let rms = computeRMS(samples)
            FileHandle.standardError.write(Data(
                String(format: "○ captured %.2fs · rms %.3f\n", seconds, rms).utf8
            ))
            if dumpWav, !samples.isEmpty {
                let path = "/tmp/parrot-last.wav"
                do {
                    try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                    FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
                }
            }
            guard !samples.isEmpty else {
                MainActor.assumeIsolated {
                    overlay?.hide()
                    menuBar.setRecording(false)
                }
                return
            }
            Task {
                let started = Date()
                do {
                    let raw = try await transcriber.transcribe(samples)
                    let text = lowercaseMode ? raw.lowercased() : raw
                    let elapsed = Date().timeIntervalSince(started)
                    FileHandle.standardError.write(Data(
                        String(format: "→ %.2fs · %@\n", elapsed, text).utf8
                    ))
                    if let history {
                        do {
                            _ = try await history.append(text)
                        } catch {
                            FileHandle.standardError.write(Data(
                                "history write failed: \(error)\n".utf8
                            ))
                        }
                    }
                    await MainActor.run {
                        TextInjector.inject(text)
                        overlay?.hide()
                        menuBar.setRecording(false)
                    }
                } catch {
                    FileHandle.standardError.write(Data("transcription failed: \(error)\n".utf8))
                    await MainActor.run {
                        overlay?.hide()
                        menuBar.setRecording(false)
                    }
                }
            }
        }

        let gesture = HotkeyGestureController { effect in
            switch effect {
            case .startRecording:
                startRecording()
            case .stopRecording:
                stopRecording()
            case .setLatched(true):
                if monitor.startExitKeyMonitoring() {
                    FileHandle.standardError.write(Data("↔ recording locked · press any key to stop\n".utf8))
                }
            case .setLatched(false):
                monitor.stopExitKeyMonitoring()
            case .scheduleTimeout, .cancelTimeout:
                break
            }
        }

        do {
            try monitor.start { event in
                switch event {
                case .pressed:
                    gesture.handle(.hotkeyPressed)
                case .released:
                    gesture.handle(.hotkeyReleased)
                case .exitKeyPressed:
                    gesture.handle(.otherKeyPressed)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("failed to register hotkey tap: \(error)\n".utf8))
            FileHandle.standardError.write(Data("run `parrot setup` to configure permissions.\n".utf8))
            throw ExitCode(1)
        }

        let shutDown = {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            monitor.stop()
            NSApp.terminate(nil)
        }
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler(handler: shutDown)
        sigint.resume()
        signal(SIGINT, SIG_IGN)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler(handler: shutDown)
        sigterm.resume()
        signal(SIGTERM, SIG_IGN)

        let micName = chosenDevice?.name ?? "system default"
        let historyPath = noHistory
            ? nil
            : StartupTUI.displayPath(TranscriptHistory.fileURL())
        let systemHotkeyAction: String?
        switch fnSystemAction?.state {
        case .disabledForParrot:
            systemHotkeyAction = "Fn/Globe action disabled while Parrot runs"
        case .alreadyDisabled:
            systemHotkeyAction = "Fn/Globe action already set to Do Nothing"
        case nil:
            systemHotkeyAction = nil
        }
        StartupTUI.show(.init(
            version: AppVersion.current,
            hotkey: chosenHotkey.name,
            model: chosenModel.id,
            microphone: micName,
            historyPath: historyPath,
            systemHotkeyAction: systemHotkeyAction
        ))
        var updateInProgress = false
        let beginUpdate: (AvailableUpdate) -> Void = { update in
            guard !updateInProgress else { return }
            updateInProgress = true
            MainActor.assumeIsolated {
                menuBar.setUpdating(update.version)
            }
            FileHandle.standardError.write(Data("updating Parrot to \(update.version)…\n".utf8))

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try UpdateInstaller.installLatest()
                    try UpdateInstaller.relaunchCurrentDaemonAfterExit()
                    FileHandle.standardError.write(Data(
                        "✓ update installed — restarting Parrot\n".utf8
                    ))
                    DispatchQueue.main.async {
                        NSApp.terminate(nil)
                    }
                } catch {
                    FileHandle.standardError.write(Data(
                        "update failed: \(error.localizedDescription)\n".utf8
                    ))
                    DispatchQueue.main.async {
                        updateInProgress = false
                        menuBar.setUpdateFailed(update.version)
                    }
                }
            }
        }
        UpdateChecker.check { result in
            switch result {
            case .updateAvailable(let update):
                FileHandle.standardError.write(Data("""
                update available: \(AppVersion.current) → \(update.version)
                release: \(update.releaseURL.absoluteString)
                run `parrot update`, choose Update below, or use the menu-bar item.

                """.utf8))
                if TerminalSelect.isAvailable {
                    let accepted = TerminalSelect.confirm(
                        title: "Parrot \(update.version) is available",
                        yes: .init(label: "Update and restart", detail: "recommended"),
                        no: .init(label: "Not now", detail: "ask again next launch"),
                        defaultYes: false
                    )
                    if accepted == true {
                        DispatchQueue.main.async {
                            beginUpdate(update)
                        }
                    } else {
                        DispatchQueue.main.async {
                            menuBar.setUpdateAvailable(update.version) {
                                beginUpdate(update)
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        menuBar.setUpdateAvailable(update.version) {
                            beginUpdate(update)
                        }
                    }
                }
            case .upToDate(let version):
                FileHandle.standardError.write(Data("✓ parrot \(version) is up to date\n".utf8))
            case .unavailable:
                FileHandle.standardError.write(Data(
                    "update check unavailable — will retry next launch\n".utf8
                ))
            case .developmentBuild:
                FileHandle.standardError.write(Data("update check skipped for development build\n".utf8))
            }
        }
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, and Fn key configuration."
    )

    func run() throws {
        let checks = DoctorReport.run()
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            for m in ModelRegistry.shared {
                let star = m.recommended ? "★" : " "
                let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                let langs = "[\(m.languages.joined(separator: ","))]"
                    .padding(toLength: 9, withPad: " ", startingAt: 0)
                let size = String(format: "%5d MB", m.sizeMB)
                print("\(star) \(id) \(size)  \(langs)  \(m.displayName)")
            }
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            guard let m = ModelRegistry.find(id) else {
                print("unknown model: \(id)")
                throw ExitCode(1)
            }
            let t = WhisperKitTranscriber(model: m)

            let sem = DispatchSemaphore(value: 0)
            var capturedError: Error?
            Task.detached {
                do { try await t.warmUp() } catch { capturedError = error }
                sem.signal()
            }
            sem.wait()
            if let e = capturedError { throw e }
        }
    }
}

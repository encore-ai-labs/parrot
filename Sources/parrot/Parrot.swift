import AppKit
import ArgumentParser
import Foundation
import WhisperKit

@main
struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Minimal macOS dictation daemon. Hold Fn, speak, release.",
        subcommands: [
            Run.self, Setup.self, Doctor.self, Models.self,
            Hotkeys.self, Devices.self, Install.self,
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

    func run() throws {
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

        if !skipDoctor {
            let checks = DoctorReport.run()
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
                chosenDevice = AudioDevices.prompt(suggested: suggested)
            } else {
                chosenDevice = suggested
            }
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

        do {
            try monitor.start { event in
                switch event {
                case .pressed:
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
                case .released:
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
                            let text = try await transcriber.transcribe(samples)
                            let elapsed = Date().timeIntervalSince(started)
                            FileHandle.standardError.write(Data(
                                String(format: "→ %.2fs · %@\n", elapsed, text).utf8
                            ))
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
            }
        } catch {
            FileHandle.standardError.write(Data("failed to register hotkey tap: \(error)\n".utf8))
            FileHandle.standardError.write(Data("run `parrot setup` to configure permissions.\n".utf8))
            throw ExitCode(1)
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        let micName = chosenDevice?.name ?? "system default"
        FileHandle.standardError.write(Data(
            "listening on \(chosenHotkey.name) hold · model: \(chosenModel.id) · mic: \(micName) · ^C to quit\n"
                .utf8
        ))
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

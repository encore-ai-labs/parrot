import AppKit
import ArgumentParser
import AVFoundation
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
            Hotkeys.self, Devices.self, Apps.self, Vocabulary.self, Snippets.self, Fillers.self,
            Templates.self, History.self, Stats.self, Transcribe.self, Settings.self, Languages.self,
            Install.self, Daemon.self, Update.self,
        ],
        defaultSubcommand: Run.self
    )
}

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, test, and prioritize microphones.",
        subcommands: [List.self, Test.self, Prioritize.self, Automatic.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List connected microphones and saved priorities."
        )

        func run() throws {
            let devices = AudioDevices.inputs()
            guard !devices.isEmpty else {
                print("no input devices found")
                return
            }

            let systemDefault = AudioDevices.defaultInput()
            let automatic = AudioDevices.preferred(allowBluetooth: false)
            let priorities = Config.load().savedInputDeviceUIDs
            let selected = AudioDevices.highestPriority(
                from: devices,
                priorityUIDs: priorities
            ) ?? automatic

            for device in devices {
                var marks: [String] = []
                if let rank = priorities.firstIndex(of: device.uid) {
                    marks.append("priority \(rank + 1)")
                } else if priorities.isEmpty, device.id == automatic?.id {
                    marks.append("★ parrot")
                } else if !priorities.isEmpty, device.id == selected?.id {
                    marks.append("temporary fallback")
                }
                if device.id == systemDefault?.id { marks.append("system default") }
                let suffix = marks.isEmpty ? "" : "  (\(marks.joined(separator: ", ")))"
                let name = device.name.padding(toLength: 30, withPad: " ", startingAt: 0)
                let transport = device.transportName.padding(
                    toLength: 13,
                    withPad: " ",
                    startingAt: 0
                )
                print("  \(name) \(transport) \(device.inputChannels)ch\(suffix)")
            }

            if !priorities.isEmpty {
                let connected = Set(devices.map(\.uid))
                let missing = priorities.filter { !connected.contains($0) }
                if !missing.isEmpty {
                    print("\n  saved but disconnected: \(missing.joined(separator: ", "))")
                }
            }

            if let warning = AudioDevices.bluetoothWarning(for: selected) {
                print()
                print(warning)
            }
        }
    }

    struct Test: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Measure a microphone's signal locally without transcribing or saving audio."
        )

        @Option(
            name: .customLong("input-device"),
            help: "Microphone name or UID. Defaults to Parrot's current preferred input."
        )
        var inputDevice: String?

        @Option(
            name: .customLong("seconds"),
            help: "Test duration from 2 through 15 seconds."
        )
        var seconds: Double = 5

        @Flag(name: .long, help: "Print the result as JSON on stdout.")
        var json = false

        func validate() throws {
            guard seconds.isFinite, (2...15).contains(seconds) else {
                throw ValidationError("--seconds must be between 2 and 15")
            }
        }

        func run() throws {
            try ensureMicrophonePermission()

            let connected = AudioDevices.inputs()
            guard !connected.isEmpty else {
                throw ValidationError("no input devices found")
            }

            let selected: AudioInputDevice
            if let inputDevice {
                guard let match = AudioDevices.find(inputDevice, in: connected) else {
                    throw ValidationError(
                        "unknown connected microphone '\(inputDevice)'; run `parrot devices`"
                    )
                }
                selected = match
            } else if let preferred = AudioDevices.highestPriority(
                from: connected,
                priorityUIDs: Config.load().savedInputDeviceUIDs
            ) ?? AudioDevices.preferred(allowBluetooth: false) {
                selected = preferred
            } else {
                throw ValidationError("couldn't choose an input device; pass --input-device")
            }

            writeStatus(String(
                format: "testing %@ · speak normally for %.1f seconds…\n",
                selected.name,
                seconds
            ))
            if let warning = AudioDevices.bluetoothWarning(for: selected) {
                writeStatus("\(warning)\n")
            }

            let capture = AudioCapture(
                device: selected,
                preferredDeviceUIDs: [selected.uid],
                usePreRoll: true,
                liveRecordingURL: nil
            )
            capture.onStatus = { writeStatus("\($0)\n") }
            try capture.startSession()
            defer { capture.stopSession() }

            // Fill the normal 300 ms pre-roll, then discard it from the
            // analysis so the requested duration describes only the test.
            Thread.sleep(forTimeInterval: AudioCapture.preRollSeconds + 0.05)
            try capture.start()
            var isCapturing = true
            defer {
                if isCapturing { capture.cancel() }
            }
            writeStatus("● recording\n")
            Thread.sleep(forTimeInterval: seconds)
            let recorded = try capture.stop()
            isCapturing = false

            guard let samples = recorded.samples else {
                throw ValidationError("microphone test unexpectedly used file-backed capture")
            }
            let requestedSamples = min(
                samples.count,
                Int(seconds * Double(recorded.sampleRate))
            )
            let analysis = MicrophoneSignalAnalysis.analyze(
                samples.suffix(requestedSamples),
                sampleRate: recorded.sampleRate
            )
            let result = MicrophoneTestResult(
                deviceName: selected.name,
                deviceUID: selected.uid,
                transport: selected.transportName,
                analysis: analysis
            )

            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                var data = try encoder.encode(result)
                data.append(0x0A)
                FileHandle.standardOutput.write(data)
            } else {
                print(result.textReport())
            }

            guard analysis.rating == .healthy else { throw ExitCode(2) }
        }

        private func ensureMicrophonePermission() throws {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return
            case .notDetermined:
                writeStatus("requesting microphone access…\n")
                let semaphore = DispatchSemaphore(value: 0)
                var granted = false
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    granted = allowed
                    semaphore.signal()
                }
                semaphore.wait()
                guard granted else {
                    throw ValidationError(
                        "microphone access was denied; enable your terminal in "
                            + "System Settings → Privacy & Security → Microphone"
                    )
                }
            case .denied, .restricted:
                throw ValidationError(
                    "microphone access is denied; enable your terminal in "
                        + "System Settings → Privacy & Security → Microphone"
                )
            @unknown default:
                throw ValidationError("microphone permission is in an unknown state")
            }
        }

        private func writeStatus(_ message: String) {
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    struct Prioritize: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save connected microphones in highest-first fallback order."
        )

        @Argument(help: "Microphone names or UIDs, highest priority first.")
        var devices: [String]

        func validate() throws {
            guard !devices.isEmpty else {
                throw ValidationError("provide at least one connected microphone name or UID")
            }
            guard devices.count <= AudioDevices.maximumPriorityCount else {
                throw ValidationError(
                    "microphone priority supports at most \(AudioDevices.maximumPriorityCount) devices"
                )
            }
        }

        func run() throws {
            let connected = AudioDevices.inputs()
            var selected: [AudioInputDevice] = []
            var seen = Set<String>()
            for query in devices {
                guard let device = AudioDevices.find(query, in: connected) else {
                    throw ValidationError(
                        "unknown connected microphone '\(query)'; run `parrot devices`"
                    )
                }
                guard seen.insert(device.uid).inserted else {
                    throw ValidationError("microphone '\(device.name)' appears more than once")
                }
                selected.append(device)
            }

            var config = Config.load()
            config.inputDeviceUIDs = selected.map(\.uid)
            // Preserve a sensible preference when an older Parrot reads this config.
            config.inputDeviceUID = selected.first?.uid
            try config.write()
            print("✓ saved microphone priority")
            for (index, device) in selected.enumerated() {
                print("  \(index + 1). \(device.name) · \(device.transportName)")
            }
            print("restart a running Parrot daemon to apply the change")
        }
    }

    struct Automatic: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Clear saved priorities and return to safe automatic selection."
        )

        func run() throws {
            var config = Config.load()
            config.inputDeviceUIDs = nil
            config.inputDeviceUID = nil
            try config.write()
            print("✓ microphone selection restored to automatic")
            print("restart a running Parrot daemon to apply the change")
        }
    }
}

struct Hotkeys: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List keys you can pass to --hotkey or --note-hotkey."
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
        print("then pass it as `--hotkey keycode:<n>` or `--note-hotkey keycode:<n>`.")
        print("It'll be swallowed too.")
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

    @Flag(name: .long, help: "Transcribe very short or near-silent captures (debug).")
    var noAudioGate: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Option(name: .long, help: "Model id for this run. Overrides the saved default.")
    var model: String?

    @Option(name: .long, help: "Language code/name for this run, or auto.")
    var language: String?

    @Option(
        name: .long,
        help: "Push-to-talk key for this run. Overrides the saved default."
    )
    var hotkey: String?

    @Option(
        name: .customLong("note-hotkey"),
        help: "Second key that always records in note mode for this run."
    )
    var noteHotkey: String?

    @Flag(
        name: .customLong("no-note-hotkey"),
        help: "Disable a saved note-mode shortcut for this run."
    )
    var noNoteHotkey: Bool = false

    @Option(
        name: .customLong("note-journal"),
        help: "Append note-key captures to this Markdown file for this run."
    )
    var noteJournal: String?

    @Flag(
        name: .customLong("no-note-journal"),
        help: "Disable a saved note-key journal for this run."
    )
    var noNoteJournal: Bool = false

    @Option(
        name: .customLong("context"),
        help: "Local Whisper hint: off, selected-text, clipboard, or both."
    )
    var recognitionContext: String?

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

    @Flag(
        name: .long,
        help: "Keep the mic warm for a 300 ms pre-roll, overriding a saved cold-mic setting."
    )
    var warmMic: Bool = false

    @Flag(name: .long, help: "Lowercase all transcribed text.")
    var lowercase: Bool = false

    @Flag(name: .long, help: "Don't lowercase transcribed text.")
    var noLowercase: Bool = false

    @Flag(name: .long, help: "Remove conservative speech fillers and false starts locally.")
    var cleanup: Bool = false

    @Flag(name: .customLong("no-cleanup"), help: "Preserve disfluencies even if cleanup is saved.")
    var noCleanup: Bool = false

    @Flag(
        name: .customLong("auto-paragraphs"),
        help: "Insert paragraphs at deliberate pauses while using note mode."
    )
    var automaticParagraphs: Bool = false

    @Flag(
        name: .customLong("no-auto-paragraphs"),
        help: "Keep note-mode output continuous even if automatic paragraphs are saved."
    )
    var noAutomaticParagraphs: Bool = false

    @Flag(
        name: .customLong("compact-pauses"),
        help: "Shorten long quiet pauses locally in locked recordings before inference."
    )
    var compactPauses: Bool = false

    @Flag(
        name: .customLong("no-compact-pauses"),
        help: "Keep the full locked-recording timeline for this run."
    )
    var noCompactPauses: Bool = false

    @Flag(name: .long, help: "Don't save successful transcripts to local Markdown history.")
    var noHistory: Bool = false

    @Flag(
        name: .long,
        help: "Print transcript text to stderr. This may expose private dictation in logs."
    )
    var logTranscripts: Bool = false

    @Flag(
        name: [.customLong("notes"), .customLong("note-mode")],
        help: "Use local Markdown note mode for this run, overriding the saved mode."
    )
    var noteMode: Bool = false

    @Flag(
        name: .customLong("dictation"),
        help: "Use plain dictation for this run, overriding a saved notes mode."
    )
    var dictationMode: Bool = false

    @Option(name: .customLong("template"), help: "Apply a named local Markdown template and use note mode.")
    var noteTemplate: String?

    @Flag(name: .customLong("no-template"), help: "Ignore the saved note template for this run.")
    var noNoteTemplate: Bool = false

    @Option(
        name: .long,
        help: "Append dictations to this Markdown file instead of typing at the cursor."
    )
    var journal: String?

    @Option(
        name: .long,
        help: "Run a local zsh command with final text on stdin instead of typing at the cursor."
    )
    var command: String?

    @Flag(name: .long, help: "Type at the cursor even when another delivery default is saved.")
    var paste: Bool = false

    @Flag(
        name: .customLong("space-after-paste"),
        help: "Add a boundary space after cursor-injected text."
    )
    var spaceAfterPaste: Bool = false

    @Flag(
        name: .customLong("no-space-after-paste"),
        help: "Inject exact text without the saved trailing boundary space."
    )
    var noSpaceAfterPaste: Bool = false

    @Flag(
        name: .customLong("clipboard-paste"),
        help: "Paste through the clipboard for apps that drop simulated text."
    )
    var clipboardPaste: Bool = false

    @Flag(
        name: .customLong("keystroke-paste"),
        help: "Insert with Unicode keystrokes without touching the clipboard."
    )
    var keystrokePaste: Bool = false

    @Option(
        name: .customLong("clipboard-restore-delay-ms"),
        help: "Restore prior clipboard content after 100...5000 milliseconds."
    )
    var clipboardRestoreDelayMilliseconds: Int?

    @Flag(name: .long, help: "Re-run first-time setup and overwrite saved preferences.")
    var reconfigure: Bool = false

    @Option(name: .customLong("wait-for-pid"), help: .hidden)
    var waitForPID: Int32?

    func validate() throws {
        guard [journal != nil, command != nil, paste].filter({ $0 }).count <= 1 else {
            throw ValidationError("pass at most one of --journal, --command, or --paste")
        }
        guard !(noteTemplate != nil && noNoteTemplate) else {
            throw ValidationError("pass at most one of --template or --no-template")
        }
        guard !(dictationMode && noteTemplate != nil) else {
            throw ValidationError("--template selects note mode and cannot use --dictation")
        }
        guard !(cleanup && noCleanup) else {
            throw ValidationError("pass at most one of --cleanup or --no-cleanup")
        }
        guard !(automaticParagraphs && noAutomaticParagraphs) else {
            throw ValidationError(
                "pass at most one of --auto-paragraphs or --no-auto-paragraphs"
            )
        }
        guard !(compactPauses && noCompactPauses) else {
            throw ValidationError(
                "pass at most one of --compact-pauses or --no-compact-pauses"
            )
        }
        guard !(spaceAfterPaste && noSpaceAfterPaste) else {
            throw ValidationError(
                "pass at most one of --space-after-paste or --no-space-after-paste"
            )
        }
        guard !(clipboardPaste && keystrokePaste) else {
            throw ValidationError(
                "pass at most one of --clipboard-paste or --keystroke-paste"
            )
        }
        if let delay = clipboardRestoreDelayMilliseconds,
           !TextInjector.validClipboardRestoreDelayMilliseconds.contains(delay) {
            throw ValidationError("--clipboard-restore-delay-ms must be between 100 and 5000")
        }
        guard !(warmMic && coldMic) else {
            throw ValidationError("pass at most one of --warm-mic or --cold-mic")
        }
        guard !(noteHotkey != nil && noNoteHotkey) else {
            throw ValidationError("pass at most one of --note-hotkey or --no-note-hotkey")
        }
        guard !(noteJournal != nil && noNoteJournal) else {
            throw ValidationError("pass at most one of --note-journal or --no-note-journal")
        }
        if let journal {
            _ = try MarkdownJournal.resolveURL(journal)
        }
        if let noteJournal {
            _ = try MarkdownJournal.resolveURL(noteJournal)
        }
        if let recognitionContext,
           RecognitionContextSource.parse(recognitionContext) == nil {
            throw ValidationError(
                "unknown context '\(recognitionContext)'; use off, selected-text, clipboard, or both"
            )
        }
        if let command {
            _ = try LocalCommandDelivery(command: command)
        }
    }

    func run() throws {
        LaunchAgentManager.trimInheritedLogsIfNeeded()
        if let waitForPID {
            // Used by the updater: don't initialize a second daemon until the
            // old executable has restored its Fn preference and fully exited.
            for _ in 0..<100 where kill(waitForPID, 0) == 0 {
                usleep(100_000)
            }
        }

        let daemonLock: DaemonLock
        do {
            daemonLock = try DaemonLock.acquire()
        } catch DaemonLock.LockError.alreadyRunning(let pid) {
            let owner = pid.map { " (pid \($0))" } ?? ""
            FileHandle.standardError.write(Data(
                "✓ Parrot is ready\(owner) and listening for its hotkey.\n"
                    .appending("  Run `parrot daemon status`; quit from the menu bar or use ")
                    .appending("`parrot daemon stop`.\n").utf8
            ))
            return
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            throw ExitCode(1)
        }
        StartupTUI.showLogo()

        var config = Config.load()
        if reconfigure {
            config = Config()
        }
        var configDirty = reconfigure
        guard let recommendedModel = ModelRegistry.recommended()?.id else {
            FileHandle.standardError.write(Data("no models registered\n".utf8))
            throw ExitCode(1)
        }
        let defaults: RuntimeDefaults
        do {
            defaults = try RuntimeDefaults.resolve(
                config: config,
                hotkeyOverride: hotkey,
                noteHotkeyOverride: noteHotkey,
                disableNoteHotkey: noNoteHotkey,
                noteJournalOverride: noteJournal,
                disableNoteJournal: noNoteJournal,
                noteTemplateOverride: noteTemplate,
                disableNoteTemplate: noNoteTemplate,
                recognitionContextOverride: recognitionContext,
                modelOverride: model,
                languageOverride: language,
                notes: noteMode,
                dictation: dictationMode,
                journalOverride: journal,
                commandOverride: command,
                paste: paste,
                cleanupOverride: cleanup || noCleanup ? cleanup : nil,
                automaticParagraphsOverride: automaticParagraphs || noAutomaticParagraphs
                    ? automaticParagraphs
                    : nil,
                compactLockedPausesOverride: compactPauses || noCompactPauses
                    ? compactPauses
                    : nil,
                spaceAfterPasteOverride: spaceAfterPaste || noSpaceAfterPaste
                    ? spaceAfterPaste
                    : nil,
                insertionMethodOverride: clipboardPaste || keystrokePaste
                    ? (clipboardPaste ? .clipboard : .keystrokes)
                    : nil,
                clipboardRestoreDelayMillisecondsOverride: clipboardRestoreDelayMilliseconds,
                warmMicrophoneOverride: warmMic || coldMic ? warmMic : nil,
                recommendedModel: recommendedModel
            )
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            throw ExitCode(64)
        }
        let chosenHotkey: Hotkey
        guard let parsedHotkey = Hotkey.parse(defaults.hotkey) else {
            let kind = hotkey == nil ? "saved hotkey" : "hotkey"
            FileHandle.standardError.write(Data("unknown \(kind): \(defaults.hotkey)\n".utf8))
            FileHandle.standardError.write(Data(
                "run `parrot settings set --hotkey fn` to repair it.\n".utf8
            ))
            throw ExitCode(1)
        }
        chosenHotkey = parsedHotkey
        let chosenNoteHotkey: Hotkey?
        if let rawNoteHotkey = defaults.noteHotkey {
            guard let parsed = Hotkey.parse(rawNoteHotkey) else {
                let kind = noteHotkey == nil ? "saved note hotkey" : "note hotkey"
                FileHandle.standardError.write(Data("unknown \(kind): \(rawNoteHotkey)\n".utf8))
                FileHandle.standardError.write(Data(
                    "run `parrot settings set --no-note-hotkey` to repair it.\n".utf8
                ))
                throw ExitCode(1)
            }
            chosenNoteHotkey = parsed
        } else {
            chosenNoteHotkey = nil
        }
        let configuredHotkeys = [chosenHotkey] + (chosenNoteHotkey.map { [$0] } ?? [])
        let usesFnHotkey = configuredHotkeys.contains(where: \.needsSystemActionDisabled)

        // Validate pure configuration before changing a system preference or
        // asking macOS for hardware permissions.
        guard let chosenModel = ModelRegistry.find(defaults.model) else {
            let kind = model == nil ? "saved model" : "model"
            FileHandle.standardError.write(Data("unknown \(kind): \(defaults.model)\n".utf8))
            FileHandle.standardError.write(Data(
                "run `parrot settings set --model \(recommendedModel)` to repair it.\n".utf8
            ))
            throw ExitCode(1)
        }
        guard RecognitionLanguage.isSupported(defaults.language, by: chosenModel) else {
            FileHandle.standardError.write(Data(
                "\(chosenModel.id) cannot transcribe \(defaults.language); "
                    .appending("choose whisper-base/whisper-small or use --language en\n").utf8
            ))
            throw ExitCode(64)
        }
        let templates: NoteTemplateLibrary
        do {
            templates = try NoteTemplateLibrary.load()
        } catch {
            FileHandle.standardError.write(Data(
                "note templates unavailable: \(error.localizedDescription)\n".utf8
            ))
            throw ExitCode(1)
        }
        let configuredNoteTemplate: String?
        if let requested = defaults.noteTemplate {
            guard let canonical = templates.canonicalName(matching: requested) else {
                FileHandle.standardError.write(Data(
                    "unknown note template: \(requested)\n".utf8
                ))
                FileHandle.standardError.write(Data(
                    "run `parrot templates` or `parrot templates off` to repair it.\n".utf8
                ))
                throw ExitCode(1)
            }
            configuredNoteTemplate = canonical
        } else {
            configuredNoteTemplate = nil
        }
        let effectiveRecognitionContext: RecognitionContextSource
        if chosenModel.engine == .whisperKit {
            effectiveRecognitionContext = defaults.recognitionContext
        } else {
            effectiveRecognitionContext = .off
            if defaults.recognitionContext != .off {
                FileHandle.standardError.write(Data(
                    "recognition context skipped: \(chosenModel.id) does not support prompt hints\n".utf8
                ))
            }
        }
        let commandDelivery: LocalCommandDelivery?
        if let deliveryCommand = defaults.deliveryCommand {
            do {
                commandDelivery = try LocalCommandDelivery(command: deliveryCommand)
            } catch {
                FileHandle.standardError.write(Data(
                    "local command unavailable: \(error.localizedDescription)\n".utf8
                ))
                throw ExitCode(1)
            }
        } else {
            commandDelivery = nil
        }

        let fnSystemAction: FnSystemActionOverride?
        if usesFnHotkey {
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
            let checks = DoctorReport.run(includeFnKeyMapping: usesFnHotkey)
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
                DoctorReport.print(checks)
                FileHandle.standardError.write(Data("\nfix the above or pass --skip-doctor\n".utf8))
                throw ExitCode(1)
            }
        }

        // Pick the mic before anything slow happens, so a bad --input-device
        // fails immediately rather than after a model download.
        let chosenDevice: AudioInputDevice?
        let capturePriorityUIDs: [String]
        var shouldRememberChosenDevice = false
        if let query = inputDevice {
            guard let found = AudioDevices.find(query) else {
                FileHandle.standardError.write(Data("unknown input device: \(query)\n".utf8))
                FileHandle.standardError.write(Data("run `parrot devices` to see the options.\n".utf8))
                throw ExitCode(1)
            }
            chosenDevice = found
            capturePriorityUIDs = [found.uid]
        } else {
            let suggested = AudioDevices.preferred(allowBluetooth: allowBluetoothInput)
            let savedPriorities = config.savedInputDeviceUIDs
            let hasRankedPriorities = !AudioDevices.normalizedPriorityUIDs(
                config.inputDeviceUIDs ?? []
            ).isEmpty
            // Prompt only when there's a terminal to prompt at — under launchd
            // there isn't, and blocking a daemon on readLine() hangs it forever.
            if hasRankedPriorities {
                chosenDevice = AudioDevices.highestPriority(
                    from: AudioDevices.inputs(),
                    priorityUIDs: savedPriorities
                ) ?? suggested
                capturePriorityUIDs = savedPriorities
            } else if !noPickMic, AudioDevices.isInteractive {
                chosenDevice = AudioDevices.prompt(
                    suggested: suggested, preselect: config.inputDeviceUID
                )
                capturePriorityUIDs = chosenDevice.map { [$0.uid] } ?? []
                shouldRememberChosenDevice = true
            } else if let remembered = AudioDevices.highestPriority(
                from: AudioDevices.inputs(),
                priorityUIDs: savedPriorities
            ) {
                chosenDevice = remembered
                capturePriorityUIDs = savedPriorities
            } else {
                chosenDevice = suggested
                // Preserve an unavailable legacy preference so a reconnect can
                // promote it instead of overwriting it with a temporary fallback.
                capturePriorityUIDs = savedPriorities.isEmpty
                    ? (suggested.map { [$0.uid] } ?? [])
                    : savedPriorities
            }
        }
        if shouldRememberChosenDevice,
           let uid = chosenDevice?.uid,
           uid != config.inputDeviceUID {
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

        let vocabulary: PersonalVocabulary
        do {
            vocabulary = try PersonalVocabulary.load()
        } catch {
            FileHandle.standardError.write(Data(
                "warning: couldn't load vocabulary: \(error.localizedDescription)\n".utf8
            ))
            vocabulary = PersonalVocabulary()
        }
        let snippets: SnippetLibrary
        do {
            snippets = try SnippetLibrary.load()
        } catch {
            FileHandle.standardError.write(Data(
                "warning: couldn't load snippets: \(error.localizedDescription)\n".utf8
            ))
            snippets = SnippetLibrary()
        }
        let fillers: PersonalFillerLibrary
        do {
            fillers = try PersonalFillerLibrary.load()
        } catch {
            FileHandle.standardError.write(Data(
                "warning: couldn't load personal fillers: \(error.localizedDescription)\n".utf8
            ))
            fillers = PersonalFillerLibrary()
        }
        let personalizationController = PersonalizationController(
            vocabulary: vocabulary,
            snippets: snippets,
            fillers: fillers,
            templates: templates
        )
        let journalWriter: MarkdownJournal?
        if let journalPath = defaults.journalPath {
            do {
                let url = try MarkdownJournal.resolveURL(journalPath)
                let writer = MarkdownJournal(url: url)
                try writer.prepare()
                journalWriter = writer
            } catch {
                FileHandle.standardError.write(Data(
                    "journal unavailable: \(error.localizedDescription)\n".utf8
                ))
                throw ExitCode(1)
            }
        } else {
            journalWriter = nil
        }
        let noteJournalWriter: MarkdownJournal?
        if chosenNoteHotkey != nil, let noteJournalPath = defaults.noteJournalPath {
            do {
                let url = try MarkdownJournal.resolveURL(noteJournalPath)
                let writer = MarkdownJournal(url: url)
                try writer.prepare()
                noteJournalWriter = writer
            } catch {
                FileHandle.standardError.write(Data(
                    "note journal unavailable: \(error.localizedDescription)\n".utf8
                ))
                throw ExitCode(1)
            }
        } else {
            noteJournalWriter = nil
        }
        let transcriber = TranscriberFactory.make(
            model: chosenModel,
            language: defaults.language,
            automaticParagraphs: defaults.automaticParagraphs,
            vocabulary: vocabulary,
            additionalPromptTerms: templates.promptTerms + snippets.promptTerms,
            notePromptTerms: NoteFormatter.promptTerms
        )
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
            MainActor.assumeIsolated {
                TextInjector.restoreClipboardIfNeeded()
            }
        }
        defer { NotificationCenter.default.removeObserver(terminationObserver) }

        let monitor = HotkeyMonitor(hotkeys: configuredHotkeys, debug: debugHotkey)
        let recordingRecovery = LastRecordingRecovery()
        let capture = AudioCapture(
            device: chosenDevice,
            preferredDeviceUIDs: capturePriorityUIDs,
            usePreRoll: defaults.warmMicrophone,
            liveRecordingURL: recordingRecovery.fileURL
        )
        let realtimeTranscriber = (transcriber as? any RealtimeTranscriber).flatMap {
            $0.supportsRealtime ? $0 : nil
        }
        let realtimeRouter = RealtimeCaptureRouter()
        if realtimeTranscriber != nil {
            capture.onCaptureStarted = { realtimeRouter.submit($0) }
            capture.onCapturedSamples = { realtimeRouter.submit($0) }
        }
        capture.onStatus = { message in
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        }
        let dumpWav = self.dumpWav
        let overlay: RecordingOverlay? = noOverlay ? nil : MainActor.assumeIsolated { RecordingOverlay() }
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        let modeController = DictationModeController(
            fallbackMode: defaults.mode,
            rules: config.savedAppRules,
            automaticRulesEnabled: !(noteMode || dictationMode),
            reloadRulesFrom: Config.url
        )
        let lastTranscriptStore = MainActor.assumeIsolated { LastTranscriptStore() }
        let menuBar = MainActor.assumeIsolated {
            MenuBarController(
                modelID: chosenModel.id,
                language: RecognitionLanguage.displaySelection(
                    defaults.language,
                    model: chosenModel
                ),
                hotkeyName: chosenHotkey.name,
                noteHotkeyName: chosenNoteHotkey?.name,
                mode: defaults.mode
            ) { mode in
                modeController.setFallbackMode(mode)
            }
        }
        MainActor.assumeIsolated {
            menuBar.setLastTranscript(available: false) {
                guard let text = lastTranscriptStore.text else { return }
                // Let the status menu close and return focus to the user's app
                // before delivering the recovery insertion.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    TextInjector.inject(
                        text,
                        appendSpace: defaults.spaceAfterPaste,
                        method: defaults.insertionMethod,
                        clipboardRestoreDelayMilliseconds:
                            defaults.clipboardRestoreDelayMilliseconds
                    )
                }
            }
        }
        let initiallyAvailableMicrophones = AudioDevices.inputs()
        MainActor.assumeIsolated {
            menuBar.setMicrophones(
                initiallyAvailableMicrophones,
                activeUID: chosenDevice?.uid,
                activeName: chosenDevice?.name,
                isTemporaryFallback: capturePriorityUIDs.first.map {
                    $0 != chosenDevice?.uid
                } ?? false
            ) { [weak capture, weak menuBar] device in
                guard let capture, let menuBar else { return }
                let latestConfig = Config.load()
                let existingPriorities = latestConfig.savedInputDeviceUIDs.isEmpty
                    ? capturePriorityUIDs
                    : latestConfig.savedInputDeviceUIDs
                let selectedPriorities = AudioDevices.priorities(
                    selecting: device.uid,
                    existing: existingPriorities
                )
                capture.switchInput(
                    toUID: device.uid,
                    name: device.name,
                    priorityUIDs: selectedPriorities
                ) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .switched(let status):
                            var latest = Config.load()
                            latest.inputDeviceUID = device.uid
                            latest.inputDeviceUIDs = selectedPriorities
                            latest.save()
                            menuBar.setActiveMicrophone(status)
                            FileHandle.standardError.write(Data(
                                "✓ microphone switched · \(status.name)\n".utf8
                            ))
                            if let warning = AudioDevices.bluetoothWarning(for: device) {
                                FileHandle.standardError.write(Data("\(warning)\n".utf8))
                            }
                        case .busy:
                            menuBar.setMicrophoneSwitchFailed(
                                "Finish or cancel the current dictation before switching microphones."
                            )
                        case .unavailable(let name):
                            menuBar.setMicrophones(AudioDevices.inputs())
                            menuBar.setMicrophoneSwitchFailed(
                                "\(name) disconnected before Parrot could switch to it."
                            )
                        case .failed(let reason):
                            menuBar.setMicrophoneSwitchFailed(
                                "Couldn't switch microphones: \(reason)"
                            )
                        }
                    }
                }
            }
        }
        capture.onDeviceChanged = { [weak menuBar] status in
            DispatchQueue.main.async {
                menuBar?.setActiveMicrophone(status)
            }
        }
        capture.onAvailableDevicesChanged = { [weak menuBar] in
            DispatchQueue.global(qos: .utility).async {
                let devices = AudioDevices.inputs()
                DispatchQueue.main.async {
                    menuBar?.setMicrophones(devices)
                }
            }
        }
        let history = noHistory
            ? nil
            : TranscriptHistory(retentionDays: defaults.historyRetentionDays)
        if history != nil {
            let latestHistoryText = Task.detached(priority: .utility) {
                try? TranscriptHistoryReader().recent(limit: 1).first?.text
            }
            Task {
                guard let recovered = await latestHistoryText.value else { return }
                await MainActor.run {
                    guard lastTranscriptStore.text == nil else { return }
                    lastTranscriptStore.update(recovered)
                    menuBar.setLastTranscript(available: true)
                }
            }
        }
        let audioHistoryRetentionDays: Int? = noHistory
            ? nil
            : defaults.audioHistoryRetentionDays.map { configuredDays in
                min(configuredDays, defaults.historyRetentionDays ?? configuredDays)
            }
        let audioArchive = HistoryAudioArchive()
        let audioMaintenance = audioHistoryRetentionDays.map {
            HistoryAudioMaintenance(archive: audioArchive, retentionDays: $0)
        }
        let pruneHistoryIfNeeded: @Sendable (Bool) -> Void = { force in
            guard let history else { return }
            Task(priority: .utility) {
                do {
                    if let plan = try await history.pruneExpiredIfDue(force: force),
                       plan.entriesRemoved > 0 {
                        let entryNoun = plan.entriesRemoved == 1 ? "entry" : "entries"
                        let fileNoun = plan.filesAffected == 1 ? "file" : "files"
                        FileHandle.standardError.write(Data(
                            "history retention removed \(plan.entriesRemoved) \(entryNoun) "
                                .appending("from \(plan.filesAffected) \(fileNoun)\n").utf8
                        ))
                    }
                    if let audioMaintenance {
                        let validIDs = Set(try TranscriptHistoryReader().all().map(\.id))
                        if let result = try await audioMaintenance.pruneIfDue(
                            validTranscriptIDs: validIDs,
                            force: force
                        ), result.recordingsRemoved > 0 {
                            let noun = result.recordingsRemoved == 1 ? "recording" : "recordings"
                            FileHandle.standardError.write(Data(
                                "audio retention removed \(result.recordingsRemoved) \(noun)\n".utf8
                            ))
                        }
                    }
                } catch {
                    FileHandle.standardError.write(Data(
                        "history maintenance failed: \(error.localizedDescription)\n".utf8
                    ))
                }
            }
        }
        pruneHistoryIfNeeded(true)
        let lifecycle = DictationLifecycle()
        let restoredRecording: Bool
        do {
            restoredRecording = try recordingRecovery.restorePending()
            if restoredRecording {
                FileHandle.standardError.write(Data(
                    "↻ recovered an interrupted recording · use the menu bar to retry or forget it\n".utf8
                ))
            }
        } catch {
            restoredRecording = false
            FileHandle.standardError.write(Data(
                "recovery recording unavailable: \(error.localizedDescription)\n".utf8
            ))
        }
        var recordingMode = defaults.mode
        var recordingDeliveryRoute = HotkeyModeRouter.DeliveryRoute.primary
        var retryMode = defaults.mode
        var retryDeliveryRoute = HotkeyModeRouter.DeliveryRoute.primary
        var recordingPersonalizationUpdate: Task<PersonalizationRefresh, Never>?
        var recordingContext: Task<String?, Never>?
        var retryContext: Task<String?, Never>?
        var recordingWasLatched = false
        var retryCompactPauses = false
        var realtimeTeardown: Task<Void, Never>?

        func preparePersonalization() -> Task<PersonalizationRefresh, Never> {
            Task {
                let refresh = await personalizationController.refreshIfNeeded()
                // Always offer the current revision. This also applies a
                // refresh completed for a capture the user later cancelled.
                await transcriber.updatePersonalization(refresh.snapshot.transcriber)
                for warning in refresh.warnings {
                    FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
                }
                if refresh.didReload {
                    let vocabularyNoun = refresh.snapshot.vocabularyCount == 1
                        ? "term"
                        : "terms"
                    let snippetNoun = refresh.snapshot.snippetCount == 1
                        ? "snippet"
                        : "snippets"
                    let fillerNoun = refresh.snapshot.fillerCount == 1
                        ? "filler"
                        : "fillers"
                    let templateNoun = refresh.snapshot.templateCount == 1
                        ? "template"
                        : "templates"
                    FileHandle.standardError.write(Data(
                        "↻ personalization reloaded · \(refresh.snapshot.vocabularyCount) "
                            .appending("\(vocabularyNoun) · ")
                            .appending("\(refresh.snapshot.snippetCount) \(snippetNoun) · ")
                            .appending("\(refresh.snapshot.fillerCount) \(fillerNoun) · ")
                            .appending("\(refresh.snapshot.templateCount) \(templateNoun)\n").utf8
                    ))
                }
                return refresh
            }
        }

        func transcribeAndDeliver(
            _ recording: LastRecordingRecovery.Recording,
            mode modeForCapture: DictationMode,
            deliveryRoute: HotkeyModeRouter.DeliveryRoute,
            recognitionContext: Task<String?, Never>?,
            sessionID: Int,
            audioDuration seconds: TimeInterval,
            compactLongPauses: Bool,
            personalizationUpdate: Task<PersonalizationRefresh, Never>,
            realtimeCompletion: Task<RealtimeTranscriptionSession.Completion, Never>? = nil,
            transcriberReadyAfter: Task<Void, Never>? = nil
        ) {
            Task {
                [modeForCapture, deliveryRoute, recognitionContext, recording,
                 compactLongPauses, realtimeCompletion, transcriberReadyAfter] in
                let started = Date()
                let inferenceRecording: PreparedInferenceRecording
                if compactLongPauses {
                    let compactionStarted = Date()
                    do {
                        inferenceRecording = try LockedPauseCompactor.prepare(recording)
                        if inferenceRecording.didCompact {
                            let inferenceSeconds = TimeInterval(
                                inferenceRecording.inferenceSampleCount
                            ) / TimeInterval(inferenceRecording.sampleRate)
                            FileHandle.standardError.write(Data(String(
                                format: "↯ inference audio %.2fs → %.2fs · %.2fs quiet pause skipped · %.3fs prep\n",
                                seconds,
                                inferenceSeconds,
                                inferenceRecording.removedDuration,
                                Date().timeIntervalSince(compactionStarted)
                            ).utf8))
                        }
                    } catch {
                        inferenceRecording = .unchanged(recording)
                        FileHandle.standardError.write(Data(
                            "pause compaction unavailable: \(error.localizedDescription)"
                                .appending(" · using original audio\n").utf8
                        ))
                    }
                } else {
                    inferenceRecording = .unchanged(recording)
                }
                defer { inferenceRecording.removeTemporaryFile() }
                do {
                    // File I/O and prompt rebuilding normally finish while
                    // the user is speaking. Awaiting here guarantees that the
                    // decoder and post-processing use one coherent revision.
                    let personalization = await personalizationUpdate.value.snapshot
                    let context = await recognitionContext?.value
                    if let transcriberReadyAfter { await transcriberReadyAfter.value }
                    let transcription: LiveTranscription
                    let realtimeResult = await realtimeCompletion?.value
                    if let fallbackReason = realtimeResult?.fallbackReason {
                        FileHandle.standardError.write(Data(
                            "\(fallbackReason)\n".utf8
                        ))
                    }
                    if let completed = realtimeResult?.transcription,
                       !inferenceRecording.didCompact {
                        transcription = completed
                    } else {
                        switch inferenceRecording.recording {
                        case .memory(let samples, _, _):
                            transcription = try await transcriber.transcribe(
                                samples,
                                mode: modeForCapture,
                                recognitionContext: context
                            )
                        case .file(let url, _, _):
                            let timed = try await transcriber.transcribeFile(
                                at: url,
                                mode: modeForCapture,
                                recognitionContext: context
                            )
                            transcription = LiveTranscription(
                                text: timed.text,
                                language: timed.language,
                                segments: timed.segments,
                                originalText: timed.originalText
                            )
                        }
                    }
                    let applyCleanup = defaults.cleanup
                        && RecognitionLanguage.supportsEnglishCleanup(transcription.language)
                    if defaults.cleanup && !applyCleanup {
                        FileHandle.standardError.write(Data(
                            "cleanup skipped for detected language \(transcription.language)\n".utf8
                        ))
                    }
                    let spokenTemplateSelection = personalization.templates.resolve(
                        transcription.text
                    )
                    let spokenSelection = SpokenModeTrigger.resolve(
                        spokenTemplateSelection.text,
                        fallbackMode: spokenTemplateSelection.wasTriggered
                            ? .notes
                            : modeForCapture
                    )
                    let processingSegments: [TimedTranscriptSegment]
                    if defaults.automaticParagraphs,
                       (spokenTemplateSelection.wasTriggered || spokenSelection.mode == .notes),
                       modeForCapture != .notes {
                        switch inferenceRecording.recording {
                        case .memory(let samples, let sampleRate, _):
                            processingSegments = AudioPauseDetector.refining(
                                transcription.segments,
                                samples: samples,
                                sampleRate: Double(sampleRate)
                            )
                        case .file(let url, _, _):
                            processingSegments = (
                                try? AudioPauseDetector.refining(
                                    transcription.segments,
                                    audioAt: url
                                )
                            ) ?? transcription.segments
                        }
                    } else {
                        processingSegments = transcription.segments
                    }
                    let processed = TranscriptProcessing.processWithSpokenModeTrigger(
                        transcription.text,
                        fallbackMode: modeForCapture,
                        lowercase: lowercaseMode,
                        cleanup: applyCleanup,
                        fillers: personalization.fillers,
                        automaticParagraphs: defaults.automaticParagraphs,
                        segments: processingSegments,
                        snippets: personalization.snippets,
                        templates: personalization.templates,
                        configuredNoteTemplate: configuredNoteTemplate
                    )
                    let text = processed.text
                    if processed.usedSpokenModeTrigger {
                        FileHandle.standardError.write(Data(
                            "↪ spoken mode · \(processed.mode.rawValue)\n".utf8
                        ))
                    }
                    if processed.usedSpokenTemplateTrigger, let template = processed.templateName {
                        FileHandle.standardError.write(Data(
                            "↪ spoken template · \(template)\n".utf8
                        ))
                    }
                    let elapsed = Date().timeIntervalSince(started)
                    let completionLog = logTranscripts
                        ? String(format: "→ %.2fs · %@\n", elapsed, text)
                        : String(format: "→ %.2fs · ", elapsed) + "\(text.count) chars\n"
                    FileHandle.standardError.write(Data(completionLog.utf8))
                    let journalForCapture = deliveryRoute == .noteJournal
                        ? noteJournalWriter
                        : journalWriter
                    let commandForCapture = deliveryRoute == .noteJournal
                        ? nil
                        : commandDelivery
                    var deliveredToJournal = false
                    if let journalForCapture {
                        do {
                            if let url = try journalForCapture.append(text) {
                                deliveredToJournal = true
                                FileHandle.standardError.write(Data(
                                    "✓ appended to \(StartupTUI.displayPath(url))\n".utf8
                                ))
                            }
                        } catch {
                            FileHandle.standardError.write(Data(
                                "journal write failed: \(error.localizedDescription)\n".utf8
                            ))
                        }
                    }
                    var commandDeliverySucceeded = commandForCapture == nil
                    if let commandForCapture {
                        do {
                            try commandForCapture.deliver(text)
                            commandDeliverySucceeded = true
                            FileHandle.standardError.write(Data(
                                "✓ delivered to local command\n".utf8
                            ))
                        } catch {
                            FileHandle.standardError.write(Data(
                                "command delivery failed: \(error.localizedDescription)"
                                    .appending(" · retry is available in the menu bar\n").utf8
                            ))
                        }
                    }
                    let deliveryDecision = TranscriptDeliveryDecision.resolve(
                        deliveredToJournal: deliveredToJournal,
                        commandConfigured: commandForCapture != nil,
                        commandSucceeded: commandDeliverySucceeded
                    )
                    var historyWrite: TranscriptHistoryWrite?
                    if deliveryDecision.deliveryCompleted, let history {
                        do {
                            historyWrite = try await history.appendEntry(
                                text,
                                audioDuration: seconds,
                                processingDuration: elapsed,
                                language: transcription.language,
                                modelID: transcriber.modelID,
                                mode: processed.mode,
                                originalText: transcription.originalText
                            )
                        } catch {
                            FileHandle.standardError.write(Data(
                                "history write failed: \(error)\n".utf8
                            ))
                        }
                    }
                    if let historyWrite, audioHistoryRetentionDays != nil {
                        do {
                            _ = try audioArchive.archive(
                                sourceWAV: recordingRecovery.fileURL,
                                entryID: historyWrite.id
                            )
                        } catch {
                            FileHandle.standardError.write(Data(
                                "audio history save failed: \(error.localizedDescription)\n".utf8
                            ))
                        }
                    }
                    let didFinish = await MainActor.run { () -> Bool in
                        guard lifecycle.finish(sessionID) else { return false }
                        if deliveryDecision.deliveryCompleted {
                            lastTranscriptStore.update(text)
                            menuBar.setLastTranscript(available: true)
                        }
                        if deliveryDecision.injectAtCursor {
                            TextInjector.inject(
                                text,
                                appendSpace: defaults.spaceAfterPaste,
                                method: defaults.insertionMethod,
                                clipboardRestoreDelayMilliseconds:
                                    defaults.clipboardRestoreDelayMilliseconds
                            )
                        }
                        overlay?.hide()
                        menuBar.setRecording(false)
                        menuBar.setRecordingRecovery(available: true)
                        menuBar.setRecordingRecoveryBusy(false)
                        return true
                    }
                    if didFinish && deliveryDecision.deliveryCompleted {
                        do {
                            try recordingRecovery.markDelivered()
                        } catch {
                            FileHandle.standardError.write(Data(
                                "recovery cleanup failed: \(error.localizedDescription)\n".utf8
                            ))
                        }
                        await MainActor.run {
                            menuBar.setRecordingRecovery(available: recordingRecovery.hasRecording)
                        }
                        pruneHistoryIfNeeded(false)
                    }
                } catch {
                    FileHandle.standardError.write(Data(
                        "transcription failed: \(error) · retry is available in the menu bar\n".utf8
                    ))
                    await MainActor.run {
                        guard lifecycle.finish(sessionID) else { return }
                        overlay?.hide()
                        menuBar.setRecording(false)
                        menuBar.setRecordingRecovery(available: recordingRecovery.hasRecording)
                        menuBar.setRecordingRecoveryBusy(false)
                    }
                }
            }
        }

        let startRecording = { (source: String) in
            guard let sessionID = lifecycle.start() else { return }
            recordingWasLatched = false
            recordingPersonalizationUpdate = preparePersonalization()
            let realtimePreviewID = realtimeTranscriber.map { _ in UUID() }
            if let realtimeTranscriber,
               let personalizationUpdate = recordingPersonalizationUpdate,
               let realtimePreviewID {
                let session = RealtimeTranscriptionSession(
                    transcriber: realtimeTranscriber,
                    after: realtimeTeardown,
                    prepare: { _ = await personalizationUpdate.value },
                    partial: { text in
                        overlay?.pushPartial(text, sessionID: realtimePreviewID)
                    }
                )
                realtimeTeardown = nil
                realtimeRouter.activate(session)
            }
            recordingContext = MainActor.assumeIsolated {
                RecognitionContextCapture.start(source: effectiveRecognitionContext)
            }
            let usedNoteHotkey = source == chosenNoteHotkey?.name
            let selection = HotkeyModeRouter.selection(
                source: source,
                noteHotkeyName: chosenNoteHotkey?.name
            ) {
                modeController.selection(
                    frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                )
            }
            recordingMode = selection.mode
            recordingDeliveryRoute = HotkeyModeRouter.deliveryRoute(
                source: source,
                noteHotkeyName: chosenNoteHotkey?.name,
                hasNoteJournal: noteJournalWriter != nil
            )
            do {
                try recordingRecovery.beginLiveCapture()
                try capture.start()
                _ = monitor.startExitKeyMonitoring()
                let selectionSource = selection.isAutomatic
                    ? " · automatic"
                    : (usedNoteHotkey ? " · note hotkey" : "")
                let deliverySource = recordingDeliveryRoute == .noteJournal
                    ? " · note inbox"
                    : ""
                let templateSource = selection.mode == .notes
                    ? configuredNoteTemplate.map { " · template \($0)" } ?? ""
                    : ""
                FileHandle.standardError.write(Data(
                    "● recording · \(selection.mode.rawValue)\(selectionSource)"
                        .appending("\(deliverySource)\(templateSource)\n").utf8
                ))
                MainActor.assumeIsolated {
                    menuBar.setMode(
                        selection.mode,
                        automaticApplicationName: selection.automaticApplicationName
                    )
                    overlay?.show(.recording, previewSessionID: realtimePreviewID)
                    menuBar.setRecording(true)
                    menuBar.setRecordingRecoveryBusy(true)
                }
            } catch {
                if let realtime = realtimeRouter.deactivate() {
                    realtimeTeardown = realtime.cancel()
                }
                recordingContext?.cancel()
                recordingContext = nil
                lifecycle.failStart(sessionID)
                FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
                MainActor.assumeIsolated {
                    menuBar.setRecordingRecovery(available: recordingRecovery.hasRecording)
                    menuBar.setRecordingRecoveryBusy(false)
                }
            }
        }

        let stopRecording = {
            guard let sessionID = lifecycle.beginTranscription() else { return }
            let compactPausesForCapture = LockedPausePolicy.shouldCompact(
                wasLatched: recordingWasLatched,
                settingEnabled: defaults.compactLockedPauses
            )
            recordingWasLatched = false
            let modeForCapture = recordingMode
            let deliveryRouteForCapture = recordingDeliveryRoute
            let contextForCapture = recordingContext
            recordingContext = nil
            let personalizationUpdateForCapture = recordingPersonalizationUpdate
                ?? preparePersonalization()
            monitor.stopExitKeyMonitoring()
            let captured: CapturedAudio
            let recording: LastRecordingRecovery.Recording?
            var realtimeSession: RealtimeTranscriptionSession?
            do {
                captured = try capture.stop()
                realtimeSession = realtimeRouter.deactivate()
                recording = try recordingRecovery.adoptLiveCapture(captured)
            } catch {
                if let realtime = realtimeSession ?? realtimeRouter.deactivate() {
                    realtimeTeardown = realtime.cancel()
                }
                contextForCapture?.cancel()
                _ = lifecycle.finish(sessionID)
                FileHandle.standardError.write(Data(
                    "capture finalization failed: \(error.localizedDescription)\n".utf8
                ))
                MainActor.assumeIsolated {
                    overlay?.hide()
                    menuBar.setRecording(false)
                    menuBar.setRecordingRecovery(available: recordingRecovery.hasRecording)
                    menuBar.setRecordingRecoveryBusy(false)
                }
                return
            }
            MainActor.assumeIsolated {
                overlay?.show(.transcribing)
                menuBar.setTranscribing()
            }
            let seconds = captured.duration
            let rms = captured.rms
            FileHandle.standardError.write(Data(
                String(format: "○ captured %.2fs · rms %.4f\n", seconds, rms).utf8
            ))
            if dumpWav, !captured.isEmpty {
                let path = "/tmp/parrot-last.wav"
                do {
                    let destination = URL(fileURLWithPath: path)
                    try? FileManager.default.removeItem(at: destination)
                    if let source = captured.fileURL {
                        try FileManager.default.copyItem(at: source, to: destination)
                    } else if let samples = captured.samples {
                        try WAVWriter.write(
                            samples: samples,
                            sampleRate: captured.sampleRate,
                            to: path
                        )
                    }
                    FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
                }
            }
            guard let recording else {
                if let realtimeSession {
                    realtimeTeardown = realtimeSession.cancel()
                }
                contextForCapture?.cancel()
                try? recordingRecovery.forget()
                _ = lifecycle.finish(sessionID)
                MainActor.assumeIsolated {
                    overlay?.hide()
                    menuBar.setRecording(false)
                    menuBar.setRecordingRecoveryBusy(false)
                }
                return
            }
            if let rejection = CaptureQuality.rejection(
                duration: seconds,
                rms: rms,
                enabled: !noAudioGate
            ) {
                if let realtimeSession {
                    realtimeTeardown = realtimeSession.cancel()
                }
                contextForCapture?.cancel()
                try? recordingRecovery.forget()
                _ = lifecycle.finish(sessionID)
                FileHandle.standardError.write(Data("× \(rejection.message) — discarded\n".utf8))
                MainActor.assumeIsolated {
                    overlay?.hide()
                    menuBar.setRecording(false)
                    menuBar.setRecordingRecoveryBusy(false)
                }
                return
            }
            retryMode = modeForCapture
            retryDeliveryRoute = deliveryRouteForCapture
            retryContext = contextForCapture
            retryCompactPauses = compactPausesForCapture
            let realtimeCompletion: Task<RealtimeTranscriptionSession.Completion, Never>?
            var transcriberReadyAfter: Task<Void, Never>?
            if let realtimeSession, compactPausesForCapture {
                let teardown = realtimeSession.cancel()
                realtimeTeardown = teardown
                transcriberReadyAfter = teardown
                realtimeCompletion = nil
            } else if let realtimeSession {
                transcriberReadyAfter = nil
                realtimeCompletion = Task {
                    await realtimeSession.finish(
                        mode: modeForCapture,
                        sourceDuration: seconds
                    )
                }
            } else {
                realtimeCompletion = nil
                transcriberReadyAfter = nil
            }
            transcribeAndDeliver(
                recording,
                mode: modeForCapture,
                deliveryRoute: deliveryRouteForCapture,
                recognitionContext: contextForCapture,
                sessionID: sessionID,
                audioDuration: seconds,
                compactLongPauses: compactPausesForCapture,
                personalizationUpdate: personalizationUpdateForCapture,
                realtimeCompletion: realtimeCompletion,
                transcriberReadyAfter: transcriberReadyAfter
            )
        }

        let cancelRecording = {
            guard lifecycle.cancelRecording() else { return }
            recordingContext?.cancel()
            recordingContext = nil
            recordingWasLatched = false
            monitor.stopExitKeyMonitoring()
            capture.cancel()
            if let realtime = realtimeRouter.deactivate() {
                realtimeTeardown = realtime.cancel()
            }
            try? recordingRecovery.forget()
            FileHandle.standardError.write(Data("× recording cancelled\n".utf8))
            MainActor.assumeIsolated {
                overlay?.hide()
                menuBar.setRecording(false)
                menuBar.setRecordingRecoveryBusy(false)
            }
        }

        let retryLastRecording = {
            let preparedRecording: LastRecordingRecovery.Recording?
            do {
                preparedRecording = try recordingRecovery.prepareForRetry()
            } catch {
                FileHandle.standardError.write(Data(
                    "couldn't prepare recording retry: \(error.localizedDescription)\n".utf8
                ))
                return
            }
            guard let recording = preparedRecording,
                  let sessionID = lifecycle.beginRetry()
            else { return }
            let personalizationUpdate = preparePersonalization()
            let pendingRealtimeTeardown = realtimeTeardown
            let seconds = recording.duration
            FileHandle.standardError.write(Data(
                "↻ retrying last recording · \(retryMode.rawValue)\n".utf8
            ))
            MainActor.assumeIsolated {
                menuBar.setMode(
                    retryMode,
                    automaticApplicationName: nil
                )
                overlay?.show(.transcribing)
                menuBar.setTranscribing()
                menuBar.setRecordingRecoveryBusy(true)
            }
            transcribeAndDeliver(
                recording,
                mode: retryMode,
                deliveryRoute: retryDeliveryRoute,
                recognitionContext: retryContext,
                sessionID: sessionID,
                audioDuration: seconds,
                compactLongPauses: retryCompactPauses,
                personalizationUpdate: personalizationUpdate,
                transcriberReadyAfter: pendingRealtimeTeardown
            )
        }

        let forgetLastRecording = {
            do {
                try recordingRecovery.forget()
                FileHandle.standardError.write(Data("✓ forgot last recording\n".utf8))
                MainActor.assumeIsolated {
                    menuBar.setRecordingRecovery(available: false)
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "couldn't forget last recording: \(error.localizedDescription)\n".utf8
                ))
            }
        }

        MainActor.assumeIsolated {
            menuBar.setRecordingRecovery(
                available: recordingRecovery.hasRecording,
                restored: restoredRecording,
                retry: retryLastRecording,
                forget: forgetLastRecording
            )
        }

        let gesture = HotkeyGestureController { effect in
            switch effect {
            case .startRecording(let source):
                startRecording(source)
            case .stopRecording:
                stopRecording()
            case .cancelRecording:
                cancelRecording()
            case .setLatched(true, let source):
                recordingWasLatched = true
                if monitor.startExitKeyMonitoring() {
                    FileHandle.standardError.write(Data(
                        "↔ recording locked · tap \(source) to transcribe · esc cancels\n".utf8
                    ))
                }
            case .setLatched(false, _):
                monitor.stopExitKeyMonitoring()
            case .scheduleTimeout, .cancelTimeout:
                break
            }
        }

        capture.onCaptureInterrupted = { reason in
            DispatchQueue.main.async {
                FileHandle.standardError.write(Data(
                    "× \(reason) — partial recording discarded\n".utf8
                ))
                gesture.handle(.cancelKeyPressed)
            }
        }
        capture.onCaptureStorageFailed = { reason in
            DispatchQueue.main.async {
                FileHandle.standardError.write(Data(
                    "× live recovery failed: \(reason) — recording discarded\n".utf8
                ))
                gesture.handle(.cancelKeyPressed)
            }
        }

        // Configure only after all recovery callbacks are wired, so even an
        // interruption during startup cannot strand the dictation lifecycle.
        do {
            try capture.startSession()
        } catch {
            FileHandle.standardError.write(Data(
                "failed to open microphone: \(error.localizedDescription)\n".utf8
            ))
            throw ExitCode(1)
        }
        defer { capture.stopSession() }

        do {
            try monitor.start { event in
                switch event {
                case .pressed(let source):
                    guard !lifecycle.isTranscribing else {
                        FileHandle.standardError.write(Data(
                            "still transcribing — hotkey ignored\n".utf8
                        ))
                        return
                    }
                    gesture.handle(.hotkeyPressed(source: source))
                case .released(let source):
                    gesture.handle(.hotkeyReleased(source: source))
                case .cancelKeyPressed:
                    gesture.handle(.cancelKeyPressed)
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
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler(handler: shutDown)
        sigint.resume()
        signal(SIGTERM, SIG_IGN)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler(handler: shutDown)
        sigterm.resume()

        let micName = chosenDevice?.name ?? "system default"
        let historyPath = noHistory
            ? nil
            : StartupTUI.displayPath(TranscriptHistory.fileURL())
        let cursorInsertionDescription = defaults.insertionMethod == .clipboard
            ? "paste at cursor · clipboard · restore \(defaults.clipboardRestoreDelayMilliseconds)ms"
            : "paste at cursor · keystrokes · clipboard untouched"
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
            noteHotkey: chosenNoteHotkey?.name,
            noteJournal: chosenNoteHotkey == nil ? nil : defaults.noteJournalPath,
            recognitionContext: effectiveRecognitionContext.rawValue,
            model: chosenModel.id,
            language: RecognitionLanguage.displaySelection(defaults.language, model: chosenModel),
            microphone: micName,
            mode: defaults.mode.rawValue,
            noteTemplate: configuredNoteTemplate,
            vocabularyCount: vocabulary.entries.count,
            snippetCount: snippets.entries.count,
            fillerCount: fillers.entries.count,
            templateCount: templates.entries.count,
            historyPath: historyPath,
            historyRetentionDays: defaults.historyRetentionDays,
            audioHistoryRetentionDays: audioHistoryRetentionDays,
            delivery: journalWriter.map {
                "journal → \(StartupTUI.displayPath($0.url))"
            } ?? (commandDelivery == nil
                ? cursorInsertionDescription
                    + " · boundary space \(defaults.spaceAfterPaste ? "on" : "off")"
                : "local command ← transcript on stdin"),
            cleanup: defaults.cleanup,
            automaticParagraphs: defaults.automaticParagraphs,
            compactLockedPauses: defaults.compactLockedPauses,
            warmMicrophone: defaults.warmMicrophone,
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
        withExtendedLifetime(daemonLock) {
            app.run()
        }
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

struct Vocabulary: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Teach Parrot names, jargon, and exact written forms.",
        subcommands: [List.self, Add.self, Remove.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        func run() throws {
            let vocabulary = try PersonalVocabulary.load()
            guard !vocabulary.entries.isEmpty else {
                print("no vocabulary entries yet")
                print("add one with: parrot vocabulary add RustPond")
                print("or replace speech: parrot vocabulary add 'rust pond' --as RustPond")
                return
            }

            for entry in vocabulary.entries.sorted(by: {
                $0.spoken.localizedCaseInsensitiveCompare($1.spoken) == .orderedAscending
            }) {
                if entry.spoken == entry.written {
                    print("  \(entry.written)")
                } else {
                    print("  \(entry.spoken)  →  \(entry.written)")
                }
            }
            print("\nlocal file: \(PersonalVocabulary.url.path)")
        }
    }

    struct Add: ParsableCommand {
        @Argument(help: "The term as spoken, or its preferred spelling when --as is omitted.")
        var spoken: String

        @Option(name: .customLong("as"), help: "Exact text to write when the spoken form is heard.")
        var written: String?

        func run() throws {
            var vocabulary = try PersonalVocabulary.load()
            let output = written ?? spoken
            let updated = try vocabulary.set(spoken: spoken, written: output)
            try vocabulary.save()
            let verb = updated ? "updated" : "learned"
            if spoken == output {
                print("✓ \(verb) \(output)")
            } else {
                print("✓ \(verb) \(spoken) → \(output)")
            }
            print("active on the next recording — no daemon restart needed")
        }
    }

    struct Remove: ParsableCommand {
        @Argument(help: "The spoken form of the entry to remove.")
        var spoken: String

        func run() throws {
            var vocabulary = try PersonalVocabulary.load()
            guard vocabulary.remove(spoken: spoken) else {
                throw ValidationError("no vocabulary entry matches '\(spoken)'")
            }
            try vocabulary.save()
            print("✓ forgot \(spoken)")
            print("active on the next recording — no daemon restart needed")
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [
            List.self, Download.self, Remove.self, Path.self, Migrate.self, ModelBenchmark.self,
        ]
    )

    struct List: ParsableCommand {
        func run() throws {
            let storage = ModelStorage.default
            for m in ModelRegistry.shared {
                let star = m.recommended ? "★" : " "
                let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                let languageSummary = m.languages.contains("multi")
                    ? "100"
                    : m.languages.joined(separator: ",")
                let langs = "[\(languageSummary)]"
                    .padding(toLength: 9, withPad: " ", startingAt: 0)
                let size = String(format: "%5d MB", m.sizeMB)
                let stored: String
                switch m.engine {
                case .whisperKit:
                    if let variant = m.whisperKitID,
                       let existing = storage.existingModel(variant: variant) {
                        stored = existing.source == .managed ? "✓ local" : "↪ legacy"
                    } else {
                        stored = "not downloaded"
                    }
                case .parakeet:
                    stored = ParakeetTranscriber.isDownloaded(model: m, storage: storage)
                        ? "✓ local"
                        : "not downloaded"
                }
                print("\(star) \(id) \(size)  \(langs)  \(stored)  \(m.displayName)")
            }
            print("\nfree space with: parrot models remove <id>")
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            guard let m = ModelRegistry.find(id) else {
                print("unknown model: \(id)")
                throw ExitCode(1)
            }
            let t = TranscriberFactory.make(model: m)

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

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove one model from Parrot-managed storage."
        )

        @Argument(help: "Model id from `parrot models list`.")
        var id: String

        @Flag(
            name: .long,
            help: "Remove the selected default too; it will download again unless you change models."
        )
        var force = false

        func run() throws {
            guard let model = ModelRegistry.find(id) else {
                throw ValidationError("unknown model '\(id)'; run `parrot models list`")
            }

            let daemonLock: DaemonLock
            do {
                daemonLock = try DaemonLock.acquire()
            } catch let error as DaemonLock.LockError {
                switch error {
                case .alreadyRunning:
                    throw ValidationError(
                        "stop the running Parrot daemon before removing a model"
                    )
                default:
                    throw error
                }
            }
            defer { daemonLock.release() }

            let storage = ModelStorage.default
            guard try storage.hasManagedArtifacts(for: model) else {
                if model.engine == .whisperKit,
                   let variant = model.whisperKitID,
                   let existing = storage.existingModel(variant: variant),
                   existing.source == .legacyDocuments {
                    print("not removed — \(model.id) is in shared legacy storage")
                    print("path: \(existing.modelFolder.path)")
                    print("run `parrot models migrate`, then repeat this command")
                } else {
                    print("\(model.id) is not installed in Parrot-managed storage")
                }
                return
            }
            let selected = Config.load().model ?? ModelRegistry.recommended()?.id
            if selected == model.id, !force {
                throw ValidationError(
                    "\(model.id) is your selected model; choose another with "
                        + "`parrot settings set --model <id>`, or pass --force"
                )
            }

            guard let result = try storage.removeManagedModel(model) else { return }

            let reclaimed = ByteCountFormatter.string(
                fromByteCount: result.reclaimedBytes,
                countStyle: .file
            )
            print("✓ removed \(model.id) · reclaimed \(reclaimed)")
            for path in result.removedPaths {
                print("  \(path.path)")
            }
            if selected == model.id {
                print("  select another model before starting Parrot to avoid a redownload")
            }
        }
    }

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show managed and legacy model storage paths."
        )

        func run() {
            let storage = ModelStorage.default
            print("managed  \(storage.managedBase.path)")
            print("legacy   \(storage.legacyBase.path)")
            print("\nNew downloads use managed storage. `parrot models migrate` moves known legacy models.")
        }
    }

    struct Migrate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move known Parrot models out of Documents without redownloading."
        )

        func run() throws {
            let daemonLock: DaemonLock
            do {
                daemonLock = try DaemonLock.acquire()
            } catch let error as DaemonLock.LockError {
                switch error {
                case .alreadyRunning:
                    throw ValidationError(
                        "stop the running Parrot daemon before migrating models"
                    )
                default:
                    throw error
                }
            }
            defer { daemonLock.release() }
            let storage = ModelStorage.default
            let results = try storage.migrateKnownModels(ModelRegistry.shared)

            guard !results.isEmpty else {
                print("no legacy Parrot models found")
                print("managed: \(storage.managedBase.path)")
                return
            }
            for result in results {
                switch result.outcome {
                case .moved:
                    print("✓ moved \(result.modelID)")
                case .alreadyMigrated:
                    print("✓ already migrated \(result.modelID)")
                case .destinationExists:
                    print("! kept both copies of \(result.modelID); managed destination already exists")
                }
            }
            print("managed: \(storage.managedBase.path)")
            print("legacy compatibility links preserve access for other local tools")
        }
    }
}

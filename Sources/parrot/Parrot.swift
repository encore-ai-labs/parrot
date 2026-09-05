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
            Hotkeys.self, Devices.self, Apps.self, Vocabulary.self, Snippets.self,
            History.self, Stats.self, Transcribe.self, Settings.self,
            Install.self, Daemon.self, Update.self,
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

    @Flag(name: .long, help: "Transcribe very short or near-silent captures (debug).")
    var noAudioGate: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Option(name: .long, help: "Model id for this run. Overrides the saved default.")
    var model: String?

    @Option(
        name: .long,
        help: "Push-to-talk key for this run. Overrides the saved default."
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

    @Option(
        name: .long,
        help: "Append dictations to this Markdown file instead of typing at the cursor."
    )
    var journal: String?

    @Flag(name: .long, help: "Type at the cursor even when a journal default is saved.")
    var paste: Bool = false

    @Flag(name: .long, help: "Re-run first-time setup and overwrite saved preferences.")
    var reconfigure: Bool = false

    @Option(name: .customLong("wait-for-pid"), help: .hidden)
    var waitForPID: Int32?

    func validate() throws {
        guard !(journal != nil && paste) else {
            throw ValidationError("pass at most one of --journal or --paste")
        }
        if let journal {
            _ = try MarkdownJournal.resolveURL(journal)
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
                modelOverride: model,
                notes: noteMode,
                dictation: dictationMode,
                journalOverride: journal,
                paste: paste,
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

        guard let chosenModel = ModelRegistry.find(defaults.model) else {
            let kind = model == nil ? "saved model" : "model"
            FileHandle.standardError.write(Data("unknown \(kind): \(defaults.model)\n".utf8))
            FileHandle.standardError.write(Data(
                "run `parrot settings set --model \(recommendedModel)` to repair it.\n".utf8
            ))
            throw ExitCode(1)
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
        let snippetExpander = SnippetExpander(entries: snippets.entries)
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
        let transcriber = TranscriberFactory.make(
            model: chosenModel,
            vocabulary: vocabulary,
            additionalPromptTerms: snippets.promptTerms,
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
        }
        defer { NotificationCenter.default.removeObserver(terminationObserver) }

        let monitor = HotkeyMonitor(hotkey: chosenHotkey, debug: debugHotkey)
        let capture = AudioCapture(device: chosenDevice, usePreRoll: !coldMic)
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
        let menuBar = MainActor.assumeIsolated {
            MenuBarController(
                modelID: chosenModel.id,
                hotkeyName: chosenHotkey.name,
                mode: defaults.mode
            ) { mode in
                modeController.setFallbackMode(mode)
            }
        }
        let history = noHistory ? nil : TranscriptHistory()
        let lifecycle = DictationLifecycle()
        var recordingMode = defaults.mode

        let startRecording = {
            guard let sessionID = lifecycle.start() else { return }
            let selection = modeController.selection(
                frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            )
            recordingMode = selection.mode
            do {
                try capture.start()
                _ = monitor.startExitKeyMonitoring()
                let automatic = selection.isAutomatic ? " · automatic" : ""
                FileHandle.standardError.write(Data(
                    "● recording · \(selection.mode.rawValue)\(automatic)\n".utf8
                ))
                MainActor.assumeIsolated {
                    menuBar.setMode(
                        selection.mode,
                        automaticApplicationName: selection.automaticApplicationName
                    )
                    overlay?.show(.recording)
                    menuBar.setRecording(true)
                }
            } catch {
                lifecycle.failStart(sessionID)
                FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
            }
        }

        let stopRecording = {
            guard let sessionID = lifecycle.beginTranscription() else { return }
            let modeForCapture = recordingMode
            monitor.stopExitKeyMonitoring()
            let samples = capture.stop()
            MainActor.assumeIsolated {
                overlay?.show(.transcribing)
                menuBar.setTranscribing()
            }
            let seconds = Double(samples.count) / AudioCapture.targetSampleRate
            let rms = computeRMS(samples)
            FileHandle.standardError.write(Data(
                String(format: "○ captured %.2fs · rms %.4f\n", seconds, rms).utf8
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
                _ = lifecycle.finish(sessionID)
                MainActor.assumeIsolated {
                    overlay?.hide()
                    menuBar.setRecording(false)
                }
                return
            }
            if let rejection = CaptureQuality.rejection(
                duration: seconds,
                rms: rms,
                enabled: !noAudioGate
            ) {
                _ = lifecycle.finish(sessionID)
                FileHandle.standardError.write(Data("× \(rejection.message) — discarded\n".utf8))
                MainActor.assumeIsolated {
                    overlay?.hide()
                    menuBar.setRecording(false)
                }
                return
            }
            Task { [modeForCapture] in
                let started = Date()
                do {
                    let raw = try await transcriber.transcribe(samples, mode: modeForCapture)
                    let text = TranscriptProcessing.process(
                        raw,
                        mode: modeForCapture,
                        lowercase: lowercaseMode,
                        snippets: snippetExpander
                    )
                    let elapsed = Date().timeIntervalSince(started)
                    let completionLog = logTranscripts
                        ? String(format: "→ %.2fs · %@\n", elapsed, text)
                        : String(format: "→ %.2fs · ", elapsed) + "\(text.count) chars\n"
                    FileHandle.standardError.write(Data(completionLog.utf8))
                    if let history {
                        do {
                            _ = try await history.append(
                                text,
                                audioDuration: seconds,
                                processingDuration: elapsed
                            )
                        } catch {
                            FileHandle.standardError.write(Data(
                                "history write failed: \(error)\n".utf8
                            ))
                        }
                    }
                    var deliveredToJournal = false
                    if let journalWriter {
                        do {
                            if let url = try journalWriter.append(text) {
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
                    let shouldInjectAtCursor = !deliveredToJournal
                    await MainActor.run {
                        guard lifecycle.finish(sessionID) else { return }
                        if shouldInjectAtCursor {
                            TextInjector.inject(text)
                        }
                        overlay?.hide()
                        menuBar.setRecording(false)
                    }
                } catch {
                    FileHandle.standardError.write(Data("transcription failed: \(error)\n".utf8))
                    await MainActor.run {
                        guard lifecycle.finish(sessionID) else { return }
                        overlay?.hide()
                        menuBar.setRecording(false)
                    }
                }
            }
        }

        let cancelRecording = {
            guard lifecycle.cancelRecording() else { return }
            monitor.stopExitKeyMonitoring()
            _ = capture.stop()
            FileHandle.standardError.write(Data("× recording cancelled\n".utf8))
            MainActor.assumeIsolated {
                overlay?.hide()
                menuBar.setRecording(false)
            }
        }

        let gesture = HotkeyGestureController { effect in
            switch effect {
            case .startRecording:
                startRecording()
            case .stopRecording:
                stopRecording()
            case .cancelRecording:
                cancelRecording()
            case .setLatched(true):
                if monitor.startExitKeyMonitoring() {
                    FileHandle.standardError.write(Data(
                        "↔ recording locked · tap \(chosenHotkey.name) to transcribe · esc cancels\n".utf8
                    ))
                }
            case .setLatched(false):
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
                case .pressed:
                    guard !lifecycle.isTranscribing else {
                        FileHandle.standardError.write(Data(
                            "still transcribing — hotkey ignored\n".utf8
                        ))
                        return
                    }
                    gesture.handle(.hotkeyPressed)
                case .released:
                    gesture.handle(.hotkeyReleased)
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
            mode: defaults.mode.rawValue,
            vocabularyCount: vocabulary.entries.count,
            snippetCount: snippets.entries.count,
            historyPath: historyPath,
            delivery: journalWriter.map {
                "journal → \(StartupTUI.displayPath($0.url))"
            } ?? "paste at cursor",
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
            print("restart a running Parrot daemon to load the change")
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
            print("restart a running Parrot daemon to load the change")
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self, Path.self, Migrate.self, ModelBenchmark.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            let storage = ModelStorage.default
            for m in ModelRegistry.shared {
                let star = m.recommended ? "★" : " "
                let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
                let langs = "[\(m.languages.joined(separator: ","))]"
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

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
            Hotkeys.self, Devices.self, Apps.self, Vocabulary.self, Snippets.self, Fillers.self,
            History.self, Stats.self, Transcribe.self, Settings.self, Languages.self,
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

    @Option(name: .long, help: "Language code/name for this run, or auto.")
    var language: String?

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

    @Flag(name: .long, help: "Re-run first-time setup and overwrite saved preferences.")
    var reconfigure: Bool = false

    @Option(name: .customLong("wait-for-pid"), help: .hidden)
    var waitForPID: Int32?

    func validate() throws {
        guard [journal != nil, command != nil, paste].filter({ $0 }).count <= 1 else {
            throw ValidationError("pass at most one of --journal, --command, or --paste")
        }
        guard !(cleanup && noCleanup) else {
            throw ValidationError("pass at most one of --cleanup or --no-cleanup")
        }
        guard !(automaticParagraphs && noAutomaticParagraphs) else {
            throw ValidationError(
                "pass at most one of --auto-paragraphs or --no-auto-paragraphs"
            )
        }
        guard !(spaceAfterPaste && noSpaceAfterPaste) else {
            throw ValidationError(
                "pass at most one of --space-after-paste or --no-space-after-paste"
            )
        }
        guard !(warmMic && coldMic) else {
            throw ValidationError("pass at most one of --warm-mic or --cold-mic")
        }
        if let journal {
            _ = try MarkdownJournal.resolveURL(journal)
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
                spaceAfterPasteOverride: spaceAfterPaste || noSpaceAfterPaste
                    ? spaceAfterPaste
                    : nil,
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
            fillers: fillers
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
        let transcriber = TranscriberFactory.make(
            model: chosenModel,
            language: defaults.language,
            automaticParagraphs: defaults.automaticParagraphs,
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
        let capture = AudioCapture(device: chosenDevice, usePreRoll: defaults.warmMicrophone)
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
                language: RecognitionLanguage.displaySelection(
                    defaults.language,
                    model: chosenModel
                ),
                hotkeyName: chosenHotkey.name,
                mode: defaults.mode
            ) { mode in
                modeController.setFallbackMode(mode)
            }
        }
        let history = noHistory
            ? nil
            : TranscriptHistory(retentionDays: defaults.historyRetentionDays)
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
        let recordingRecovery = LastRecordingRecovery()
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
        var recordingPersonalizationUpdate: Task<PersonalizationRefresh, Never>?

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
                    FileHandle.standardError.write(Data(
                        "↻ personalization reloaded · \(refresh.snapshot.vocabularyCount) "
                            .appending("\(vocabularyNoun) · ")
                            .appending("\(refresh.snapshot.snippetCount) \(snippetNoun) · ")
                            .appending("\(refresh.snapshot.fillerCount) \(fillerNoun)\n").utf8
                    ))
                }
                return refresh
            }
        }

        func transcribeAndDeliver(
            _ samples: [Float],
            sampleRate: Int,
            mode modeForCapture: DictationMode,
            sessionID: Int,
            audioDuration seconds: TimeInterval,
            personalizationUpdate: Task<PersonalizationRefresh, Never>
        ) {
            Task { [modeForCapture, samples] in
                do {
                    try recordingRecovery.stage(samples: samples, sampleRate: sampleRate)
                } catch {
                    // The samples are still recoverable in memory and normal
                    // transcription should never fail solely because the
                    // crash-safety copy could not be written.
                    FileHandle.standardError.write(Data(
                        "recovery save failed: \(error.localizedDescription)\n".utf8
                    ))
                }

                let started = Date()
                do {
                    // File I/O and prompt rebuilding normally finish while
                    // the user is speaking. Awaiting here guarantees that the
                    // decoder and post-processing use one coherent revision.
                    let personalization = await personalizationUpdate.value.snapshot
                    let transcription = try await transcriber.transcribe(
                        samples,
                        mode: modeForCapture
                    )
                    let applyCleanup = defaults.cleanup
                        && RecognitionLanguage.supportsEnglishCleanup(transcription.language)
                    if defaults.cleanup && !applyCleanup {
                        FileHandle.standardError.write(Data(
                            "cleanup skipped for detected language \(transcription.language)\n".utf8
                        ))
                    }
                    let spokenSelection = SpokenModeTrigger.resolve(
                        transcription.text,
                        fallbackMode: modeForCapture
                    )
                    let processingSegments: [TimedTranscriptSegment]
                    if defaults.automaticParagraphs,
                       spokenSelection.mode == .notes,
                       modeForCapture != .notes {
                        processingSegments = AudioPauseDetector.refining(
                            transcription.segments,
                            samples: samples,
                            sampleRate: Double(sampleRate)
                        )
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
                        snippets: personalization.snippets
                    )
                    let text = processed.text
                    if processed.usedSpokenModeTrigger {
                        FileHandle.standardError.write(Data(
                            "↪ spoken mode · \(processed.mode.rawValue)\n".utf8
                        ))
                    }
                    let elapsed = Date().timeIntervalSince(started)
                    let completionLog = logTranscripts
                        ? String(format: "→ %.2fs · %@\n", elapsed, text)
                        : String(format: "→ %.2fs · ", elapsed) + "\(text.count) chars\n"
                    FileHandle.standardError.write(Data(completionLog.utf8))
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
                    var commandDeliverySucceeded = commandDelivery == nil
                    if let commandDelivery {
                        do {
                            try commandDelivery.deliver(text)
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
                        commandConfigured: commandDelivery != nil,
                        commandSucceeded: commandDeliverySucceeded
                    )
                    var historyWrite: TranscriptHistoryWrite?
                    if deliveryDecision.deliveryCompleted, let history {
                        do {
                            historyWrite = try await history.appendEntry(
                                text,
                                audioDuration: seconds,
                                processingDuration: elapsed,
                                language: transcription.language
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
                        if deliveryDecision.injectAtCursor {
                            TextInjector.inject(text, appendSpace: defaults.spaceAfterPaste)
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

        let startRecording = {
            guard let sessionID = lifecycle.start() else { return }
            recordingPersonalizationUpdate = preparePersonalization()
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
                    menuBar.setRecordingRecoveryBusy(true)
                }
            } catch {
                lifecycle.failStart(sessionID)
                FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
                MainActor.assumeIsolated {
                    menuBar.setRecordingRecoveryBusy(false)
                }
            }
        }

        let stopRecording = {
            guard let sessionID = lifecycle.beginTranscription() else { return }
            let modeForCapture = recordingMode
            let personalizationUpdateForCapture = recordingPersonalizationUpdate
                ?? preparePersonalization()
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
                    menuBar.setRecordingRecoveryBusy(false)
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
                    menuBar.setRecordingRecoveryBusy(false)
                }
                return
            }
            transcribeAndDeliver(
                samples,
                sampleRate: Int(AudioCapture.targetSampleRate),
                mode: modeForCapture,
                sessionID: sessionID,
                audioDuration: seconds,
                personalizationUpdate: personalizationUpdateForCapture
            )
        }

        let cancelRecording = {
            guard lifecycle.cancelRecording() else { return }
            monitor.stopExitKeyMonitoring()
            _ = capture.stop()
            FileHandle.standardError.write(Data("× recording cancelled\n".utf8))
            MainActor.assumeIsolated {
                overlay?.hide()
                menuBar.setRecording(false)
                menuBar.setRecordingRecoveryBusy(false)
            }
        }

        let retryLastRecording = {
            guard let audio = recordingRecovery.samples(),
                  let sessionID = lifecycle.beginRetry()
            else { return }
            let selection = modeController.selection(
                frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            )
            let personalizationUpdate = preparePersonalization()
            let seconds = Double(audio.samples.count) / Double(audio.sampleRate)
            FileHandle.standardError.write(Data(
                "↻ retrying last recording · \(selection.mode.rawValue)\n".utf8
            ))
            MainActor.assumeIsolated {
                menuBar.setMode(
                    selection.mode,
                    automaticApplicationName: selection.automaticApplicationName
                )
                overlay?.show(.transcribing)
                menuBar.setTranscribing()
                menuBar.setRecordingRecoveryBusy(true)
            }
            transcribeAndDeliver(
                audio.samples,
                sampleRate: audio.sampleRate,
                mode: selection.mode,
                sessionID: sessionID,
                audioDuration: seconds,
                personalizationUpdate: personalizationUpdate
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
            language: RecognitionLanguage.displaySelection(defaults.language, model: chosenModel),
            microphone: micName,
            mode: defaults.mode.rawValue,
            vocabularyCount: vocabulary.entries.count,
            snippetCount: snippets.entries.count,
            fillerCount: fillers.entries.count,
            historyPath: historyPath,
            historyRetentionDays: defaults.historyRetentionDays,
            audioHistoryRetentionDays: audioHistoryRetentionDays,
            delivery: journalWriter.map {
                "journal → \(StartupTUI.displayPath($0.url))"
            } ?? (commandDelivery == nil
                ? "paste at cursor · boundary space \(defaults.spaceAfterPaste ? "on" : "off")"
                : "local command ← transcript on stdin"),
            cleanup: defaults.cleanup,
            automaticParagraphs: defaults.automaticParagraphs,
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
        subcommands: [List.self, Download.self, Path.self, Migrate.self, ModelBenchmark.self]
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

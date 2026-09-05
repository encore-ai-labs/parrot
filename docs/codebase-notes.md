# Codebase notes

Working map of parrot as it actually is (not as `architecture.md` describes it), plus a
prioritized list of what's worth fixing. Findings marked **[measured]** were verified by
running code; **[read]** means derived from reading the source.

Repo state at time of writing: `62f8d98`, 1,333 lines of Swift across 13 files, zero tests.

**Status:** findings 3.6, 3.14, 3.17 are fixed, and 3.3's mechanism turned out to be worse
than described — see the banner below. Everything else still stands.

> ### Fixed since this was written
>
> - **3.6 tap re-enable** — `tapDisabledByTimeout`/`ByUserInput` now re-arm the tap.
> - **3.14 `--hotkey`** — implemented, plus `parrot hotkeys`. Modifiers (with left/right
>   disambiguation by keycode) and plain keys (F13–F20, End, Home, Page Up/Down), the latter
>   swallowed via `.defaultTap` so they don't reach the focused app.
> - **3.17 keystroke copying** — a modifier hotkey now subscribes to `flagsChanged` only, so
>   parrot no longer copies every keystroke on the system.
> - **New: `--input-device` / `parrot devices`** — CoreAudio input selection, and a warning
>   when the default input is Bluetooth.
>
> ### Resolved: 3.1 and 3.3's root cause
>
> `AudioCapture` was rebuilt on `AVCaptureSession` (hot session + 300 ms pre-roll), which
> fixes both the clipping and the Bluetooth degradation. A 1.5 s hold now captures 1.78 s.
> The headset stays at 44100 Hz throughout, and recovers on exit even when deliberately
> selected. `--cold-mic` restores the old open-on-demand behavior. Details below stand as the
> record of *why*.
>
> ### Discovered while fixing 3.3
>
> `AVAudioEngine` opens the **system default input device** the instant `engine.inputNode` is
> touched, before any rebinding is possible. Since Bluetooth can't do A2DP playback and mic
> capture simultaneously, a headset set as default input drops to call quality and stays
> there. Measured:
>
> ```
> 1 engine created     headset=44100 Hz
> 2 inputNode accessed headset=16000 Hz   <- too late already
> ```
>
> Consequences: `--input-device` cannot fully isolate from the default; and the always-hot
> mic (roadmap 2.1) would make the degradation **permanent** rather than per-recording. Fixing
> it properly means moving the input path onto AUHAL or `AVCaptureSession`. Also found: the
> tap must use `inputFormat(forBus:)` — `outputFormat` goes stale after a rebind and the
> mismatch throws an *uncatchable* ObjC exception.

---

## 1. What actually runs

### Entry and command surface

`Parrot.swift` is the `@main` `ParsableCommand`. Five subcommands, `Run` is the default:

| Command | File | Purpose |
|---|---|---|
| `run` (default) | `Parrot.swift:16` | The daemon |
| `setup` | `Setup.swift` | Interactive permission grant |
| `doctor` | `Parrot.swift:177` → `Doctor.swift` | Permission + Fn-mapping checks |
| `models list\|download` | `Parrot.swift:191` | Registry listing / prefetch |
| `hotkeys` | `Parrot.swift` → `Hotkey.swift` | List push-to-talk keys |
| `devices` | `Parrot.swift` → `AudioDevices.swift` | List microphones |
| `apps list\|add\|remove\|clear\|current` | `Apps.swift` → `AppModeRules.swift` | Private automatic mode rules |
| `settings show\|set\|reset` | `Settings.swift` → `Config.swift` | Persistent local daemon defaults |
| `install` | `Install.swift` | LaunchAgent write/remove |

Because `Run` is the `defaultSubcommand`, `parrot --model X`, `--no-overlay`, `--hotkey`, and
`--input-device` all route to it correctly. Model, hotkey, and dictation/notes mode resolve as
one-run CLI override > saved config > built-in default. The LaunchAgent supplies no workflow
arguments and therefore uses the exact same persisted defaults.

### Startup sequence (`Run.run()`, `Parrot.swift:37`)

1. **Doctor gate** — unless `--skip-doctor`. Blocks only on `.fail`, not `.warn`
   (`DoctorReport.allOK`, `Doctor.swift:158`). So "microphone not yet requested" passes.
2. **Runtime-default resolution** — CLI overrides are merged with the private JSON config;
   hotkey and model ids are validated before permissions or model warmup. The recommended
   model remains the final fallback.
3. **Synchronous warmup** — `Parrot.swift:65-79`. A `Task.detached` calls
   `transcriber.warmUp()` while the main thread parks on a `DispatchSemaphore`. This is where
   the model downloads (145 MB – 1.6 GB) and CoreML specialization happens. Blocking here is
   deliberate and correct: it means the first Fn press is never stuck behind a download.
4. **AppKit** — `NSApplication.shared`, `.accessory` policy (no Dock icon).
5. **Wiring** — `HotkeyMonitor`, `AudioCapture`, optional `RecordingOverlay`,
   `MenuBarController`. `capture.onLevel` is bridged to `overlay.pushLevel`.
6. **Tap registration** — `monitor.start { ... }` with the whole product loop as the closure.
7. **SIGINT** via `DispatchSource`, then `app.run()`.

### The product loop (`Parrot.swift:94-156`)

The entire behavior of parrot is one closure:

```
.pressed  → capture.start()  → overlay.show(.recording)     → menuBar.setRecording(true)
.released → capture.stop()   → overlay.show(.transcribing)  → menuBar.setTranscribing()
          → Task { transcriber.transcribe(samples) }
          → MainActor: TextInjector.inject(text) → overlay.hide() → menuBar.setRecording(false)
```

Guard: empty sample array short-circuits to hide + idle without transcribing.

### Threading model

This is the part worth holding in your head, because most of the latent bugs live here.

| Thread | What runs there |
|---|---|
| **CGEventTap thread** | `hotkeyCallback` (`HotkeyMonitor.swift:97`). Copies every event, hops to main. |
| **Main / MainActor** | `HotkeyMonitor.handle`, the product-loop closure, all AppKit + SwiftUI, `TextInjector.inject`. |
| **Audio tap thread** | `AudioCapture.process` (`AudioCapture.swift:79`). Converts, locks, appends, fires `onLevel`. |
| **`WhisperKitTranscriber` actor** | Model load and inference. |
| **Ad-hoc `Task`s** | One per transcription; one per audio buffer for level updates. |

`MainActor.assumeIsolated` is used in five places inside the product loop. It's safe **only
because** `hotkeyCallback` dispatches to `DispatchQueue.main.async` before invoking `handle`
(`HotkeyMonitor.swift:113`). That's load-bearing and undocumented — anyone who "optimizes"
away the main-queue hop turns five `assumeIsolated` calls into five crashes.

### Component detail

**`HotkeyMonitor` + `Hotkey`** — `CGEvent.tapCreate` at `.cgSessionEventTap`,
`.headInsertEventTap`. Tap options and event mask both depend on the hotkey kind:

| Hotkey kind | Tap options | Event mask | Swallowed? |
|---|---|---|---|
| Modifier (fn, r-option, …) | `.listenOnly` | `flagsChanged` | no |
| Plain key (end, f13, …) | `.defaultTap` | `+ keyDown/keyUp` | yes, that key only |

Modifiers edge-detect on a `CGEventFlags` mask, with the physical keycode disambiguating
left from right (both Options set `.maskAlternate`). Leaving them unswallowed is deliberate —
swallowing Fn would break Fn+F1–F12, which is also why `doctor` insists on
"Press 🌐 to → Do Nothing" instead. Plain keys *are* swallowed, because holding End to dictate
would otherwise jump the cursor to end-of-line on every utterance.

Both `tapDisabledByTimeout` and `tapDisabledByUserInput` re-arm the tap.

**`AudioCapture`** — `AVCaptureSession` pinned to one `AVCaptureDevice`, with
`audioSettings` requesting 16 kHz mono Float32 (macOS honors it exactly, so there's no
resampling). The session runs continuously; the delegate always feeds a 300 ms circular
pre-roll and, while capturing, appends to `captured`. `start()` seeds `captured` from the ring
so audio predates the keypress. Deliberately *not* `AVAudioEngine` — see the banner at the top.

**`WhisperKitTranscriber`** — an `actor`. `warmUp()` builds `WhisperKitConfig(model:
verbose: false, prewarm: true, load: true)`. `transcribe` joins result segments with `" "`
then runs `sanitize`.

**`TextInjector`** — `CGEvent(keyboardEventSource: nil, virtualKey: 0)` + `keyboardSetUnicodeString`,
posted as down/up pairs in 20-UTF16-unit chunks. The chunking is required; the API has a
per-event limit.

**`RecordingOverlay`** — a borderless `NSPanel` at `.statusBar` level, `ignoresMouseEvents`,
`canJoinAllSpaces`. Hosts a SwiftUI capsule with a 6-bar waveform. `show`/`hide` drive an
`ObservableObject`; visibility is a `scaleEffect(0 or 1)` with a spring-ish timing curve,
and `hide()` delays `orderOut` by 0.18 s so the animation can play.

**`MenuBarController`** — `NSStatusItem` with an inlined Lucide bird SVG (kept in source so
the executable needs no resource bundle — same reasoning as `ModelRegistry`). Menu shows
state + model, plus Quit.

**`ModelRegistry`** — three hardcoded WhisperKit models. Deliberately not JSON
(commit `abc17a0` dropped the resource bundle for true single-binary).

---

## 2. Design decisions that are right

Worth naming so they don't get "fixed" later:

- **Blocking warmup before `app.run()`.** Trades slow startup for a fast first press.
- **`.listenOnly` tap for modifiers + telling the user to neutralize Fn**, rather than
  swallowing the event. (Plain-key hotkeys do swallow, but only their own keycode.)
- **Model list and SVG inlined in source.** Genuinely single-binary; no `Bundle.module`.
- **LaunchAgent plist instead of `SMAppService`.** `SMAppService.mainApp` needs an `.app`
  bundle; parrot is a bare binary. The comment at `Install.swift:5` gets this right.
- **Push-to-talk over VAD.** Zero idle CPU, no false triggers.
- **`--dump-wav`.** Cheap, high-leverage debugging affordance.

---

## 3. Findings, ranked

### P0 — silently corrupts output or loses audio

**3.1 — ~170 ms of audio is lost at the head of every recording. [measured]** ✅ **FIXED**

`AudioCapture.start()` is called synchronously from the hotkey closure on the main thread,
and the mic doesn't actually produce samples for a long time after that. Measured on this
machine, consistently across cold and warm starts:

```
prepare()   ~20-30 ms   ← blocks main thread
start()     ~40-45 ms   ← blocks main thread
first buffer  +106 ms   ← nothing recorded before this
TOTAL       165-178 ms
```

Two consequences: the first ~170 ms of speech is never captured (clips short first words and
leading syllables), and the main thread — hence the overlay and the whole UI — is blocked for
~65 ms at the exact moment the user presses Fn.

This is the single biggest quality issue in the product. The standard fix is to keep the
engine running with the tap permanently installed, continuously fill a small pre-roll ring
buffer, and have `.pressed` merely flip a flag and seed the capture with the last ~300 ms.
That trades a hot mic (battery, and the mic-in-use indicator stays lit) for correct audio.
If the always-hot mic is unacceptable, the weaker fix is to move `start()` off the main
thread and accept the clipping.

**3.2 — `sanitize()` deletes legitimate dictated text. [measured]** ✅ **FIXED**

`WhisperKitTranscriber.sanitize` (`WhisperKitTranscriber.swift:40`) strips *any* text between
`[]`, `()`, `<||>`, or a pair of `*`. Actual outputs:

| Dictated | Injected |
|---|---|
| `Multiply 2 * 3 and then 5 * 6 equals thirty.` | `Multiply 2 6 equals thirty.` |
| `He said *emphatically* that 2 * 3 * 4 works.` | `He said that 2 4 works.` |
| `The value (roughly ten) is fine.` | `The value is fine.` |
| `Use array[0] to index it.` | `Use array to index it.` |
| `Call foo(x) then bar(y).` | `Call foo then bar .` |
| `Thank you.` (the classic silence hallucination) | `Thank you.` — **not** stripped |

So it removes content it shouldn't and misses the case it was written for (`54fd5b3`).
Should match a known-token allowlist (`BLANK_AUDIO`, `MUSIC`, `Applause`, `silence`,
`nospeech`, …), and/or only strip when the bracketed span is the entire output.

**3.3 — Models download into `~/Documents/huggingface`.** ✅ **FIXED**

New downloads use `~/Library/Application Support/Parrot/models/`. Complete legacy models are
detected and loaded in place so updating Parrot never forces a redownload. The explicit
`parrot models migrate` command moves only known, complete model bundles, refuses to
overwrite an existing managed destination, and leaves legacy compatibility symlinks.

**3.4 — Overlapping recordings cross-talk.** ✅ **FIXED**

`DictationLifecycle` now enforces one idle → recording → transcribing → idle generation at a
time. Presses during transcription are ignored, and stale completion tokens cannot inject text
or change the overlay/menu state.

**3.5 — No minimum duration or energy gate.** ✅ **FIXED**

Captures under 250 ms or below a conservative `0.0005` RMS floor are discarded before model
inference. `--no-audio-gate` is available for diagnosing unusually quiet inputs.

### P1 — reliability

**3.6 — Tap disable is unhandled; the daemon dies silently.** ✅ **FIXED**

`HotkeyMonitor.swift:106-110` catches `tapDisabledByTimeout` / `tapDisabledByUserInput` and
deliberately no-ops — "let the user restart parrot". macOS disables taps on its own schedule.
When it happens, parrot appears to be running (menu bar icon present) but Fn does nothing,
with no error anywhere. Worst possible failure mode for a background daemon, and the fix is
one line: `CGEvent.tapEnable(tap:enable: true)`.

**3.7 — `hide()`'s delayed `orderOut` fires unconditionally.** ✅ **FIXED**

The delayed hide now uses a cancellable work item, and every new `show` cancels the pending
`orderOut` before bringing the overlay forward.

**3.8 — TCC grants break on every update.**

The binary is ad-hoc signed, no Team ID (`codesign -dv`: `Signature=adhoc`,
`TeamIdentifier=not set`). Accessibility grants key off the cdhash, which changes on every
build — so every `parrot` upgrade silently revokes accessibility, and the daemon comes back
in the 3.6 failure mode. A stable Developer ID signature is the real fix; short of that,
`doctor` should at minimum detect and explain it.

**3.9 — No embedded `Info.plist`.** ✅ **FIXED**

The binary now embeds `NSMicrophoneUsageDescription` plus AVFoundation's Continuity Camera
compatibility key through the `__TEXT,__info_plist` section. This also removes a false camera
deprecation warning emitted while configuring a microphone-only capture session. Stable TCC
grants still require the Developer ID signing work in 3.8.

**3.10 — LaunchAgent can crash-loop invisibly.** ✅ **HARDENED**

Failed launches are now throttled to 30 seconds, install reports bootstrap errors, and
`parrot daemon status|start|stop|restart|logs` makes the lifecycle observable. Stable signing
is still required to prevent TCC permission loss after binary replacement (see 3.8).

**3.11 — Multi-monitor: pill lands on the wrong screen.** ✅ **FIXED**

The overlay now selects the screen containing `NSEvent.mouseLocation`, falling back to
`NSScreen.main` only when no screen contains the pointer.

### P2 — privacy and first-run UX

**3.12 — Every transcript is logged in plaintext, forever.** ✅ **FIXED**

Completion logs now contain latency and character count only. Full text requires the explicit
privacy-sensitive `--log-transcripts` flag. LaunchAgent output moved to user-only files under
`~/Library/Logs/Parrot/`, capped at 5 MiB on launch; legacy `/tmp/parrot.*.log` files are no
longer written.

**3.13 — First run looks hung.** ✅ **FIXED**

WhisperKit's progress callback now produces visible percentage progress. Interactive output
repaints at 1% increments; noninteractive output uses bounded 10% newline increments so
LaunchAgent logs remain readable. Both first-run warmup and `parrot models download` end with
an explicit ready message.

**3.18 — LaunchAgent loses selected hotkey/model/note mode.** ✅ **FIXED**

Those choices now have explicit `parrot settings show|set|reset` commands and are stored in
the existing user-only JSON config. Foreground and LaunchAgent runs share one resolver;
`--hotkey`, `--model`, `--notes`, and `--dictation` remain non-persistent one-run overrides.

**3.19 — Mode switching requires a daemon restart and cannot follow the active app.** ✅ **FIXED**

The menu bar changes the fallback mode immediately. Explicit app rules compare only the
frontmost bundle id at recording start and hot-reload after config changes. The mode is frozen
for the complete recording/transcription generation, active-app data is not added to history,
and dictation/notes decoding options are precomputed on one loaded model pipeline.

### P3 — docs/code drift

| Claim | Reality |
|---|---|
| ~~README: `parrot --hotkey right-option`~~ | ✅ **FIXED** — implemented, plus `parrot hotkeys`. |
| ~~`architecture.md`: config at `~/.config/parrot/config.toml`~~ | ✅ **FIXED** — JSON config is documented and implemented. |
| ~~`architecture.md`: models in `~/Library/Application Support/parrot/models/`~~ | ✅ **FIXED** — explicit managed storage plus safe legacy reuse/migration. |
| `architecture.md`: non-goals include "menubar" and "auto-launch at login" | Both shipped (`MenuBarController`, `Install.swift`). |
| ~~`architecture.md`: `ModelDownloader` with progress bar~~ | ✅ **FIXED** — WhisperKit downloads; Parrot owns bounded progress reporting. |
| ~~No `--version` flag~~ | ✅ **FIXED** — release builds are stamped from their tag. |

Dead code: `ModelsManifest` (`TranscriptionModel.swift:19`, orphaned by `abc17a0`),
`Engine.parakeet` (no implementation), `DoctorReport.allClean` (unused, and its doc comment
claims `parrot doctor` uses it — it uses `allOK`), `configureButton(recording:)`'s parameter
(unused since `14ef846`).

The `Transcriber` protocol is currently decorative: `Run` holds a concrete
`WhisperKitTranscriber`, and `warmUp()` isn't on the protocol, so nothing can be generic over
it. It'll need `warmUp()` before a second engine can slot in.

### P4 — concurrency hygiene

**3.14** — `var warmupError` is written from a `Task.detached` and read on the main thread
after a semaphore (`Parrot.swift:66-78`; same pattern at `Parrot.swift:221-227`). The
semaphore does establish ordering, but this won't survive Swift 6 strict concurrency.

**3.15** — `AudioCapture.process` takes an `NSLock` and allocates (`AVAudioPCMBuffer`, an
`Array` copy, and an amortized `append` realloc) on the audio tap thread. Low risk in
practice since this isn't a render callback, but it's the classic audio-thread anti-pattern
and will bite under load.

**3.16** — `pushLevel` spawns a `Task { @MainActor }` per audio buffer (~12/s at 4096 frames
@ 48 kHz) with no coalescing.

**3.17** ✅ **FIXED** — `hotkeyCallback` subscribed to `keyDown`/`keyUp` purely for `--debug-hotkey`, then
`event.copy()`s and main-queue-hops **every keystroke on the system** — including in password
fields. Filtering to `.flagsChanged` before the copy removes the work and the smell.

**3.18** ✅ **FIXED** — `SIGINT` and `SIGTERM` are ignored before their dispatch sources are
created and resumed.

### P5 — smaller things

- No trailing space after injection, so back-to-back dictations concatenate (`helloworld`).
- No `DecodingOptions` passed to WhisperKit — no language hint, and no control over
  temperature fallback, which is the main lever against hallucination loops.
- `Setup.waitForAccessibility` throws `ExitCode(0)` on the incomplete path (`Setup.swift:42`),
  so scripts can't detect that setup didn't finish.
- `Install.resolveBinaryPath` prefers `/usr/local/bin/parrot` even when run from a dev build,
  so a dev `install --launch-at-login` registers the *installed* binary.
- `Doctor` shells out to `/usr/bin/defaults` and `/bin/ps`; `CFPreferencesCopyAppValue` and
  `proc_pidpath` would do it in-process. `task.launchPath` is deprecated (`executableURL`).
- `MenuBarController.setRecording(false)` doubles as "go idle" from the transcribe path —
  the naming no longer matches the states.

### Testing

✅ **FIXED** — `Tests/parrotTests/` now covers the sanitizer. Previously: `sanitize`, `computeRMS`, `WAVWriter`, and
`ModelRegistry` are pure and would be trivial to cover — and `sanitize` in particular is
where a regression just shipped (3.2).

---

## 4. Suggested order of attack

1. **3.2 sanitize** — smallest diff, stops active data loss. Add tests with it.
2. **3.6 tap re-enable** — one line, fixes the worst failure mode.
3. **3.3 downloadBase** — one line plus a migration; gets 1.6 GB out of iCloud.
4. **3.5 min-duration gate** — small, stops random text injection.
5. **3.1 pre-roll ring buffer** — the real UX win, and the largest change. Needs a decision
   on the always-hot-mic trade-off first.
6. **3.4 + 3.7 state machine** — do together; both are the same missing concept.
7. **3.12 log hygiene** + **3.13 download progress** — trust and first-run feel.
8. **3.8 Developer ID signing** — unblocks the LaunchAgent path being genuinely reliable.
9. **P3 doc reconciliation** — either build `--hotkey`/config, or stop advertising them.

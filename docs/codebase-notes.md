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
| `transcribe <files...>` | `FileTranscription.swift` | Local timestamped Markdown/text/JSON file transcription |
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

**3.10a — Local transcript history had no lifecycle controls.** ✅ **FIXED**

History still defaults to keeping everything, but users can now save a 1–3650 day rolling policy
or preview and confirm a one-off prune. Cleanup is entry-accurate on marked cutoff-day files,
conservative around legacy entries, restricted to exact regular daily files, and coordinated with
readers and daemon appends through a cross-process lock. Automatic work runs after delivery rather
than on the inference path.

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

**3.20 — Live dictation can only paste or append to one built-in journal.** ✅ **FIXED**

`--command` and `parrot settings set --command` now hand finalized text to an explicitly configured
local zsh workflow over stdin. Transcript bytes never enter shell source, argv, or environment;
diagnostics are bounded, execution is capped at 10 seconds, and a separate process group lets Parrot
terminate complete pipelines. Failed delivery never falls back into a potentially duplicate paste and
does not add a history entry that retry would duplicate; it keeps the recording recovery slot available.
The runner is post-inference, so it adds no model work or recognition-memory cost.

**3.21 — Correcting a thought mid-note requires stopping and editing by hand.** ✅ **FIXED**

Note mode now applies explicit local backtrack commands after Markdown formatting and before snippet
expansion. `scratch that`, word/sentence deletion, and `undo that` operate on mechanically bounded
suffixes while preserving list/task/heading prefixes. Literal escaping and full dictation-mode bypass
prevent unintended edits; the undo stack stores only removed suffixes and is capped at 32. Edit phrases
do not consume prompt tokens, so the feature adds no model or network step.

**3.22 — Switching note formatting for one thought requires a restart or app rule.** ✅ **FIXED**

An exact leading `note(s) mode` or `dictation mode` trigger now selects processing for one live
capture and is stripped before delivery. Prefix-only matching, `literal` escaping, and stored-media
bypass prevent surprising content loss. The path is a static local regex; it neither adds prompt
tokens nor reruns inference. Triggered note captures retain pause-aware paragraph refinement using
the already captured PCM.

**3.23 — Personalization changes require restarting a warmed daemon.** ✅ **FIXED**

Vocabulary and snippets now hot-reload as one immutable capture revision. The unchanged path reads
only two file signatures; changed data rebuilds the bounded Whisper prompt, compiled vocabulary
replacer, and snippet expander while recording is in progress. Transcription awaits the update so
recognition and deterministic output cannot mix revisions. Invalid manual JSON keeps the last good
state and logs once rather than taking dictation down.

**3.24 — Filler cleanup cannot reflect an individual speaker's habits.** ✅ **FIXED**

`parrot fillers` now manages an explicit private list of whole words and short phrases. One
precompiled, bounded regex removes those phrases before note formatting, repairs local punctuation,
supports `literal` escaping, and cannot rewrite saved snippet bodies. The list hot-reloads as part
of the daemon's coherent personalization revision and never enters model context or a network call.

**3.25 — Only the latest recording can be replayed or reprocessed.** ✅ **FIXED**

Finite retained audio is now an explicit default-off setting. Successfully delivered, indexed
recordings are hard-linked from the existing crash-safety WAV to their stable Markdown IDs, so the
delivery path does not copy or re-encode length-dependent audio. Private permissions, a per-file
cap, exact-name and symlink guards, transcript-bounded rolling retention, orphan cleanup, and an
explicit audio-only clear command bound privacy and storage. `parrot history audio` can list, play,
or reprocess an older recording through the current entirely local model and note pipeline.

**3.26 — A single shortcut makes note mode costly to reach from mixed workflows.** ✅ **FIXED**

An optional dedicated note hotkey now bypasses fallback/app matching for one capture while sharing
the already loaded model and one global event tap. Every edge carries its source through the
gesture state machine, so only the initiating key can complete a double-tap or stop its locked
recording; the alternate key is ignored and Escape remains the explicit discard path. Unrelated
keyDown/keyUp events are rejected synchronously before copying to the main queue. If macOS disables
the tap while either key is down, the partial capture is cancelled instead of losing the release
edge and becoming stranded; an already latched capture remains active.

**3.27 — A note shortcut still shares the primary delivery destination.** ✅ **FIXED**

The dedicated note key can now own a separate Markdown inbox while primary dictation continues
to paste, append elsewhere, or run a local command. The route is frozen with the capture and
preserved across an in-memory retry. Both journals are validated before model warmup; note appends
reuse the existing locked, synced writer and its cursor fallback. Selection is a constant local
comparison and adds no additional event tap, model instance, inference pass, or network access.

**3.28 — Recognition lacks bounded local writing context.** ✅ **FIXED**

An explicit, off-by-default setting can now capture selected text, clipboard text, or both at
hotkey-down and use it only as a local Whisper prompt hint. Cross-process selection reads run away
from microphone startup with a 50ms messaging timeout; the assembled text is capped at 2,048
characters and 32 decoder tokens inside the existing 96-token budget. Parakeet skips the read
entirely. Context is frozen for retry but never logged, delivered, persisted, screen-captured, or
sent over a network.

**3.29 — Local processing can erase the recognizer's recoverable original.** ✅ **FIXED**

Successful live dictations now carry sanitized pre-processing recognition through to history.
When it differs from delivered text, Parrot stores it as Base64 in a versioned hidden Markdown
comment and exposes it through `history show|last|copy --original`; local search matches either
version. Unchanged and older entries fall back to final text. Malformed metadata cannot hide the
visible transcript, and original text follows the same private permissions, retention, locking,
and `--no-history` policy instead of creating another database or network path.

**3.30 — One remembered microphone is not enough for docked/mobile workflows.** ✅ **FIXED**

Users can now save up to eight connected microphones in highest-first order. Startup and recovery
pick the best available ranked UID before a safe non-Bluetooth, non-virtual fallback, and device
notifications promote only a better rank. Promotion during dictation is deferred until capture
ends, preventing both mixed-source audio and reconnect-triggered note loss; the decision is atomic
with capture state, closing the former reconnect/start race. Legacy singular-UID configs decode
unchanged. Ranking runs only on startup/recovery/connection events, never per audio buffer.

**3.31 — Private history is searchable but difficult to turn into a reusable project note.** ✅ **FIXED**

`history export` now collects all history, a local day/week/month, an inclusive date range, or an
all-words search into chronological Markdown or schema-stable JSON Lines. It can surface preserved
original recognition while structured output retains both forms plus timing/language metadata.
Output defaults to a pipe-clean stdout; file writes are private, atomic, and no-clobber unless
explicitly forced. The operation shares the reader lock, leaves source Markdown/audio untouched,
skips daily files outside a requested date period, and runs only when invoked, so note retrieval
has no capture or model cost.

**3.32 — Locked long notes grow RAM with their duration and are unrecoverable mid-capture.** ✅ **FIXED**

Active audio now streams once into the private recovery WAV. The common path retains at most two
minutes of Float32 samples (~7.7 MB), then releases the array and uses bounded incremental file
transcription. Startup repairs an interrupted spool's size fields from its regular-file payload;
Escape removes it, successful delivery resolves it, and only the initiating hotkey ends a locked
recording. The measured active-capture conversion/write cost is ~59 ms per recorded minute and
1.92 MB of disk per minute; the idle daemon performs no spool work.

**3.33 — Cursor delivery can drop or corrupt text without a recovery action.** ✅ **FIXED**

Privacy-first Unicode events remain the default, but their chunks now preserve UTF-16 surrogate
pairs. Apps that drop simulated text can opt into a Command-V transport with bounded delayed
restoration of every readable pasteboard type. Change-count and generation guards prevent an old
snapshot from overwriting a newer user copy or an overlapping Parrot insertion. The idle menu can
reinsert the last finalized transcript without inference, duplicate history, or retained audio;
history seeds the action across restarts while `--no-history` still supports current-session
recovery.

**3.34 — Changing microphones requires restarting an otherwise healthy daemon.** ✅ **FIXED**

The menu bar now lists connected inputs, the device AVFoundation actually opened, transport risk,
and temporary-fallback state. An idle selection moves that UID to the front of the existing saved
fallback order and rebuilds the live session on its serial queue. Device notifications refresh the
menu without polling. A shared lock gate excludes simultaneous capture start, pre-roll is cleared
at the boundary, and failure rolls back the previous session instead of stranding dictation or
mixing two microphones in one note.

**3.35 — A selected microphone can be present but effectively unusable.** ✅ **FIXED**

`parrot devices test` now records a bounded 2–15 second sample from an explicit or preferred input
and computes RMS/peak dBFS, 20 ms activity, and clipping in one local pass. It distinguishes silence,
quiet speech, healthy signal, and clipping with actionable macOS guidance and structured JSON. The
diagnostic does not initialize a recognizer, save audio or history, change device preferences, or
perform network work; non-healthy results use exit status 2 for setup automation.

**3.36 — Recurring notes require rebuilding their Markdown structure every time.** ✅ **FIXED**

`parrot templates` now manages a bounded private library of deterministic Markdown shapes with
starter presets, exact file/text input, a saved note-mode default, and a prefix-only spoken selector
for one capture. Formatting, cleanup, spoken edits, and snippets complete before the template wraps
the transcript. Bodies never enter recognition context; only four recent short names may use the
existing prompt budget. The library hot-reloads atomically without model reload or daemon restart,
while saved-default changes retain the normal explicit restart behavior.

### P3 — docs/code drift

| Claim | Reality |
|---|---|
| ~~README: `parrot --hotkey right-option`~~ | ✅ **FIXED** — implemented, plus `parrot hotkeys`. |
| ~~`architecture.md`: config at `~/.config/parrot/config.toml`~~ | ✅ **FIXED** — JSON config is documented and implemented. |
| ~~`architecture.md`: models in `~/Library/Application Support/parrot/models/`~~ | ✅ **FIXED** — explicit managed storage plus safe legacy reuse/migration. |
| ~~`architecture.md`: claimed no menu bar~~ | ✅ **FIXED** — documents the shipped lightweight menu-bar control surface. |
| ~~`architecture.md`: `ModelDownloader` with progress bar~~ | ✅ **FIXED** — WhisperKit downloads; Parrot owns bounded progress reporting. |
| ~~No `--version` flag~~ | ✅ **FIXED** — release builds are stamped from their tag. |

Dead code: `ModelsManifest` (`TranscriptionModel.swift:19`, orphaned by `abc17a0`),
`Engine.parakeet` (no implementation), `DoctorReport.allClean` (unused, and its doc comment
claims `parrot doctor` uses it — it uses `allOK`), `configureButton(recording:)`'s parameter
(unused since `14ef846`).

✅ **FIXED** — `Run` uses the `Transcriber` protocol through `TranscriberFactory`; warmup,
personalization, in-memory transcription, and file transcription are shared by WhisperKit and both
Parakeet variants. WhisperKit and compact Parakeet keep long-file audio bounded; Unified Parakeet's
upstream file converter still materializes the resampled input before its bounded model windows.

### P4 — concurrency hygiene

**3.14** — `var warmupError` is written from a `Task.detached` and read on the main thread
after a semaphore (`Parrot.swift:66-78`; same pattern at `Parrot.swift:221-227`). The
semaphore does establish ordering, but this won't survive Swift 6 strict concurrency.

**3.15** ✅ **FIXED** — `AudioCapture` consumes CoreMedia's `UnsafeBufferPointer` directly;
the always-hot path no longer materializes an `Array` per buffer. The short `NSLock` remains
to synchronize buffer ownership with hotkey start/stop, and capture growth is amortized only
while a user is actively recording.

**3.16** ✅ **FIXED** — the warm pre-roll path does no RMS or UI work while idle. During an
active capture, `AudioLevelCoalescer` uses latest-wins semantics with at most one scheduled
main-queue delivery, so audio buffers cannot accumulate an unbounded task tail. Warm/cold
capture policy is also persistent for LaunchAgent users, with explicit one-run overrides.

**3.17** ✅ **FIXED** — `hotkeyCallback` subscribed to `keyDown`/`keyUp` purely for `--debug-hotkey`, then
`event.copy()`s and main-queue-hops **every keystroke on the system** — including in password
fields. Filtering to `.flagsChanged` before the copy removes the work and the smell.

**3.18** ✅ **FIXED** — `SIGINT` and `SIGTERM` are ignored before their dispatch sources are
created and resumed.

### P5 — smaller things

- ✅ **FIXED** — Cursor injection adds one configurable delivery-only boundary space, so
  back-to-back dictations cannot concatenate (`helloworld`). History, journals, command stdin,
  and file output retain exact processed text; no surrounding application content is inspected.
- ✅ **FIXED** — WhisperKit receives precomputed dictation/note `DecodingOptions`, an optional
  pinned language (or per-capture detection), and bounded personalization/context prompt tokens.
  Its decoder retains the upstream temperature-fallback and hallucination thresholds.
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

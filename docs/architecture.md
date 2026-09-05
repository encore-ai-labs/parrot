# Architecture

## Goals

1. **CLI executable.** Single binary, launched from the terminal. No menubar, no dock icon, no settings window.
2. **Push-to-talk.** Hold Fn, speak, release — transcript appears at the cursor.
3. **Minimal recording feedback.** A small floating pill at the bottom of the screen while recording, so the user knows the mic is hot. Click-through, borderless, hidden when idle.
4. **On-device.** No network calls for transcription. Audio never leaves the machine.
5. **Pluggable models.** Whisper by default; optional Parakeet engines through one typed registry and factory.
6. **Native and lean.** One Swift Package executable target. No sidecar processes. No HTTP servers.

## Non-goals

- Cross-platform (macOS only)
- Dock icon, settings window, preferences UI
- Cloud transcription providers
- AI post-processing, summarization, agents
- Speaker diarization, meeting recording, semantic search

> Two original non-goals were later shipped: a menu-bar status item
> (`MenuBarController`) and launch-at-login (`parrot install`). The dock icon and
> settings-window exclusions still hold — the process runs `.accessory` and is
> configured entirely by flags.

## Why Swift

- **CoreML / ANE access.** WhisperKit and FluidAudio are Swift-native and run inference on the Apple Neural Engine — lower power, lower latency than CPU/GPU paths in Rust.
- **No FFI for platform APIs.** `AVCaptureSession`, `CGEventTap`, `CGEvent`, `AXIsProcessTrusted`, `NSWindow` — all first-party, no bindings to maintain.
- **Permissions plumbing** (microphone, accessibility) is dramatically smoother in a Swift binary than via Rust crates.
- **AppKit overlay for free.** The recording indicator (see below) is a borderless `NSWindow` — trivial in Swift, awkward in Rust.

The binary is a Swift Package executable — `swift build`, `swift run`, ship a single binary. Even with the overlay window, there is no `.app` bundle, no menubar entry, no dock icon.

## High-level shape

```
$ parrot
                                    ┌──────────────────┐
                                    │   ParrotCLI      │
                                    │   (main.swift)   │
                                    └────────┬─────────┘
                                             │ wires modules, runs RunLoop
                                             ▼
┌──────────────────┐  hotkey down   ┌──────────────────┐
│   HotkeyMonitor  │ ─────────────▶ │  AudioCapture    │
│  (CGEventTap)    │  hotkey up     │(AVCaptureSession)│
└──────────────────┘ ◀───────────── └────────┬─────────┘
                                             │ [Float] PCM
                                             ▼
                                    ┌──────────────────┐
                                    │   Transcriber    │
                                    │   (protocol)     │
                                    │  ┌────────────┐  │
                                    │  │ WhisperKit │  │
                                    │  └────────────┘  │
                                    │  ┌────────────┐  │
                                    │  │  Parakeet  │  │
                                    │  └────────────┘  │
                                    └────────┬─────────┘
                                            │ String
                                            ▼
                                    ┌──────────────────┐
                                    │    Personal      │
                                    │   Vocabulary     │
                                    └────────┬─────────┘
                                             │ String
                                             ▼
                                    ┌──────────────────┐
                                    │  TextInjector    │
                                    │   (CGEvent)      │
                                    └──────────────────┘
```

## Modules

### `main.swift` (ParrotCLI)

Argument parsing (via `swift-argument-parser`), config loading, module wiring. The daemon calls
`NSApplication.shared.setActivationPolicy(.accessory)` so it has no Dock icon, creates its own
status item, then runs `NSApp.run()` to drive the AppKit event loop. File-oriented subcommands do
not initialize the app or microphone. The daemon exits cleanly on SIGINT and logs operational
status to stderr.

Subcommands:
- `parrot` (default) — run the daemon
- `parrot models list` — show registered models, mark which are downloaded
- `parrot models download <id>` — pre-fetch a model
- `parrot doctor` — check microphone and accessibility permissions, print remediation steps
- `parrot vocabulary` — manage local recognition hints and exact text replacements
- `parrot transcribe <files...>` — bounded-memory local file transcription to Markdown,
  text, or JSON

### `HotkeyMonitor`

Global hotkey via `CGEventTap` (requires Accessibility permission). Default: **hold Fn**.
Configurable with `--hotkey`; `parrot hotkeys` lists the options. Two kinds, handled
differently (see `Hotkey.swift`):

- **Modifiers** — Fn, and the left/right Option/Command/Control/Shift pairs. Detected as
  `flagsChanged` edges. Left and right share a `CGEventFlags` mask, so the physical keycode
  disambiguates them. The tap stays `.listenOnly`: a modifier held alone does nothing, so
  there's no reason to swallow it, and swallowing Option would be actively harmful.
- **Plain keys** — F13–F20, End, Home, Page Up/Down, Forward Delete, or any
  `--hotkey keycode:<n>`. Detected as `keyDown`/`keyUp` with auto-repeat filtered. These *do*
  something in the focused app, so the tap switches to `.defaultTap` and swallows that one
  key's events — otherwise dictating on End would jump the cursor to end-of-line every time.

The tap subscribes to `keyDown`/`keyUp` only when the chosen hotkey needs them (or under
`--debug-hotkey`). With a modifier hotkey it listens to `flagsChanged` alone, so parrot isn't
copying every keystroke on the system.

A quick double-tap locks recording on. A first release inside the 550 ms double-tap window
waits out that window; longer push-to-talk holds still stop immediately. Once locked, only
pressing the selected hotkey again ends and transcribes the recording. A temporary event tap
watches only for Escape so it can cancel and discard; all other ordinary keystrokes pass
through to the focused application without ending the recording.

When macOS disables the tap (`tapDisabledByTimeout` / `tapDisabledByUserInput`) it is
re-armed immediately. Left unhandled, parrot keeps running — menu bar icon and all — while
the hotkey silently stops working.

**Fn key caveats, two of them:**

1. macOS maps Fn (🌐) to "Show Emoji & Symbols" or "Start Dictation" depending on System
   Settings → Keyboard → Press 🌐 key to. The tap sees the keypress regardless, but the system
   action also fires. `parrot doctor` detects this and tells the user to set "Do Nothing".
2. **Third-party keyboards don't send Fn at all.** On those boards `Fn` is a firmware-local
   layer key, handled inside the keyboard to produce F-keys and media controls; macOS never
   sees an event. Only Apple keyboards emit a real `fn`. Anyone on a mechanical keyboard must
   pick a different hotkey.

### `AudioCapture`

`AVCaptureSession` pinned to a single `AVCaptureDevice`, with `audioSettings` requesting
16 kHz mono Float32 — macOS honors that exactly, so there is no resampling step.

The session runs continuously from daemon start rather than opening on each keypress, and the
delegate always writes into a 300 ms circular pre-roll buffer. Pressing the hotkey flips a flag
and seeds the capture from that ring, so recording begins *before* the key went down. A 1.5 s
hold yields ~1.78 s of audio. Idle warm buffers update only the ring: Parrot skips RMS and UI
meter delivery until a capture is active. `parrot settings set --cold-mic` persistently reverts
to opening the device only while the key is held, trading clipped leading audio for no idle mic
indicator; `--cold-mic` and `--warm-mic` are one-run overrides.

**Why not `AVAudioEngine`.** It opens the *system default* input the instant
`engine.inputNode` is touched, before any code can rebind it. Bluetooth can't carry A2DP
playback and mic capture at once, so a headset set as default input gets dragged onto HFP and
the user's music collapses to call quality — even when parrot was told to record from a
different mic. Measured, headset as system default while capturing from a USB mic:

```
AVAudioEngine      inputNode accessed -> 44100 Hz -> 16000 Hz, never recovers
AVCaptureSession   full session cycle -> 44100 Hz throughout
```

`AVCaptureSession` opens only the device it is handed, so a Bluetooth device sitting as the
system default is harmless. parrot warns only when the *selected* mic is Bluetooth.

All session configuration, start, stop, and recovery work runs on one serial queue. Parrot
observes AVFoundation interruption/runtime/device notifications plus `NSWorkspace` sleep and
wake notifications. A stream boundary clears pre-roll and cancels any partial recording rather
than transcribing discontinuous audio. Recovery rebuilds stale inputs with bounded backoff; if
the preferred mic is absent, only a non-virtual, non-Bluetooth fallback is eligible, and the
preferred device is restored when it reconnects. The audio delegate consumes the
`UnsafeBufferPointer` in place, avoiding the former per-buffer `Array` allocation.

### `AudioDevices`

CoreAudio enumeration and selection: `parrot devices` lists inputs with transport type,
`--input-device <name|uid>` pins one (substring match, case-insensitive), and
`--allow-bluetooth-input` opts back into a Bluetooth mic. When the system default is
Bluetooth, parrot prefers the built-in mic and says so.

### `Transcriber` (protocol)

```swift
protocol Transcriber {
    var modelID: String { get }
    func warmUp() async throws
    func transcribe(_ audio: [Float], mode: DictationMode) async throws -> LiveTranscription
    func transcribeFile(at url: URL, mode: DictationMode) async throws -> TimedTranscription
}
```

`LiveTranscription` carries both text and the recognized language code. English-only Whisper
and Parakeet models resolve `auto` to `en` without a detection pass. Multilingual Whisper uses
an explicit language token or WhisperKit's in-pipeline detection, reusing the same resident model.
`RecognitionLanguage` canonicalizes names, codes, and common region identifiers, then rejects
model/language mismatches before permissions or warmup. The 147 MB multilingual Base option
preserves the small on-device footprint; the existing English recommendation remains unchanged.

Concrete implementations:

- `WhisperKitTranscriber` — wraps the `WhisperKit` package. CoreML, ANE-accelerated.
- `ParakeetTranscriber` — wraps FluidAudio for compact Parakeet TDT/CTC and Parakeet Unified INT8.
- `TranscriberFactory` — selects the concrete actor from the registry's engine field.

Adding an engine = one new file conforming to `Transcriber`.

### `TextInjector`

`CGEventCreateKeyboardEvent` + `CGEventKeyboardSetUnicodeString` — pastes the transcript at the current cursor position. Works in nearly every text field on macOS (some Electron apps and secure fields are flaky; platform constraint).

Cursor delivery prepares a separate string with one trailing boundary space by default, avoiding
concatenation across consecutive captures. It does not double existing whitespace and can be
disabled with `--no-space-after-paste` or the persisted setting. Preparation lives inside
`TextInjector`, after delivery routing, so the boundary byte never enters transcript history,
Markdown journals, local-command stdin, file output, recovery state, or model context. The policy
does not inspect surrounding application text, selections, windows, or the clipboard.

### `MarkdownJournal`

`--journal <path>` replaces cursor injection with a timestamped append to a user-selected
`.md` or `.markdown` file. The path can also be saved with `parrot settings set --journal`;
`--paste` is the one-run override. Journal delivery is separate from private transcript history,
so history can remain a recovery log or be disabled independently.

The writer validates its destination before model warmup, creates only missing directories,
uses owner-only permissions for new paths, and leaves permissions on an existing journal alone.
Each append is one advisory-locked `O_APPEND` transaction followed by `fsync`, keeping entries
whole across concurrent callers and durable before the UI reports completion. If a runtime
append fails, delivery falls back to `TextInjector` rather than silently dropping the result.

### `LocalCommandDelivery`

`--command <shell-command>` replaces cursor injection with an explicit user-owned local workflow;
the same destination can be persisted with `parrot settings set --command`. Journal, command, and
cursor delivery are mutually exclusive, while private transcript history remains independent.

The runner invokes `/bin/zsh -lc` but never interpolates the transcript into shell source, argv, or
the environment. Final UTF-8 text is supplied only through a private, automatically unlinked stdin
file, so large notes cannot deadlock on a pipe and dictated shell syntax remains data. Stdout goes to
`/dev/null`; a nonblocking bounded reader drains stderr while retaining at most 4 KiB for failures.
The child starts in its own process group. A 10-second timeout sends TERM and then KILL to that group,
preventing a pipeline or grandchild from being stranded; lingering background children are also
cleaned up after a successful shell exit. A command failure suppresses cursor fallback and history
insertion to avoid duplicate side effects or retry entries, and retains the last-recording recovery
slot for an explicit retry.
Command execution begins only after recognition and text processing, so it does not change model load,
inference latency, accuracy, or resident model memory.

### `PersonalVocabulary`

Local vocabulary lives at `~/.config/parrot/vocabulary.json` with mode `0600`. Short preferred
spellings are encoded into Whisper prompt tokens once when the model warms up. The prompt is
capped at 96 tokens and prioritizes the most recently added terms, bounding both prefill cost
and context usage regardless of vocabulary size.

After transcription and annotation cleanup, a single deterministic replacement pass applies
`spoken → written` mappings case-insensitively at word/phrase boundaries. Matches are computed
against the original transcript, so replacements cannot cascade. This gives exact results for
recurring names and jargon without an LLM, network request, or variable post-processing latency.

For the daemon, `PersonalizationController` checks the inode, size, and modification time of both
private personalization files at recording start. Unchanged files require only two metadata reads.
An atomic replacement builds one immutable revision containing the vocabulary replacer, bounded
Whisper prompt terms, and snippet expander. Whisper retokenizes that small prompt on its already
loaded tokenizer while audio is being captured; Parakeet swaps only the deterministic replacer.
The transcription task awaits that update before decoding, so prompt hints and post-processing
always use the same revision. A malformed hand edit warns once and preserves the last good state.

### `SpeechCleanup`

`--cleanup` enables an opt-in, deterministic pass between transcription/vocabulary replacement
and note formatting. It removes a conservative set of hesitation forms, bounded exact
multi-word false starts, selected function-word stutters, and matching prefix restarts. It
explicitly preserves ambiguous conversational words and meaningful repetition; `--no-cleanup`
overrides a saved setting for one run.

The implementation performs a fixed number of precompiled regular-expression passes. It loads
no additional model, allocates no transcript-sized token graph, and makes no network request.
Cleanup runs before `NoteFormatter` so spoken structure still works, and before
`SnippetExpander` so saved snippet bodies remain byte-for-byte unchanged. File transcription
uses the same pass for both primary text and timestamped segment text.

### `AudioPauseDetector` / `AutomaticParagraphFormatter`

Note mode enables pause-aware paragraphs by default. Current recognition engines already return
coarse timed segments, but Whisper segments can include the silence before the next thought.
`AudioPauseDetector` therefore reads only a 3.15-second window around each boundary (or uses the
live samples already in memory), derives a local adaptive noise threshold, and shortens the
preceding boundary only after at least 1.2 seconds of continuous silence. File memory remains
bounded independently of recording length, and opposite-phase stereo channels are measured by
energy rather than averaged into false silence.

`AutomaticParagraphFormatter` reconstructs the transcript from those segments while ignoring
whitespace. It inserts a blank line only if that reconstruction exactly matches the recognized
text; otherwise it returns the original bytes. Explicit existing line structure wins. This adds
no model, prompt, semantic rewrite, or network access, and plain dictation never enters the pass.
Users can persistently or temporarily disable it.

### `NoteFormatter`

`--notes` enables an explicit spoken-command layer after transcription and vocabulary
replacement. It converts commands such as `new paragraph`, `bullet point`, `numbered item`,
`new task`, and `heading two` into Markdown structure, along with a small set of spoken
punctuation commands. `literal <command>` protects command words when they should appear as
text. Normal dictation bypasses the formatter entirely.

All command patterns are compiled once as static regular expressions. Formatting is a bounded,
deterministic local string pass: it does not invoke a language model, inspect the destination
application, or make a network request. The command phrases are included in Whisper's existing
96-token prompt budget only when note mode is active, improving their recognition without an
unbounded latency cost.

### `SpokenEditProcessor`

After `NoteFormatter` creates Markdown structure, note mode runs a deterministic backtrack pass.
Explicit commands—`scratch that`, `delete last word`, `delete last sentence`, and `undo that`—edit
only the transcript suffix already produced in the current capture. Clause and sentence scope uses
fixed punctuation/line boundaries; Markdown list, checkbox, and heading prefixes are preserved.
`literal <command>` keeps the words, and ordinary dictation bypasses the processor entirely.

Undo records only the removed suffix and its UTF-16 insertion offset, not complete transcript
snapshots, and retains at most 32 actions. Static regular expressions are compiled once. The pass
runs before `SnippetExpander`, preventing commands inside a user-owned snippet body from executing.
Edit phrases do not consume Whisper prompt tokens, so recognition uses the exact same model path as
existing note mode. There is no extra model, semantic rewrite, application context, network request,
or unbounded memory growth.

### `SpokenModeTrigger`

Live captures may begin with `note mode`, `notes mode`, or `dictation mode` to override the
fallback/app-selected processing mode for that capture only. The static prefix matcher strips an
optional separator, supports `literal` escaping, and never scans for suffix or mid-sentence
matches. Stored-media transcription bypasses it so source recordings remain authoritative.

Mode resolution happens after recognition but before cleanup and formatting. Pause-aware
paragraphs are calculated against the original transcript and timed segments before the leading
trigger is removed, preserving their reconstruction invariant. A dictation-to-notes switch refines
pause boundaries from the already captured PCM only when automatic paragraphs are enabled. No
extra decoding pass, prompt tokens, model, context capture, or network request is added.

### `SnippetLibrary` / `SnippetExpander`

Reusable multiline text lives in owner-readable `~/.config/parrot/snippets.json`. The explicit
phrase `insert snippet <trigger>` expands after note and lowercase formatting, which preserves
the body byte-for-byte while still formatting surrounding dictation. `literal insert snippet
<trigger>` escapes expansion. The compiled matcher scans the original transcript once and
applies replacements back-to-front, so inserted bodies cannot cascade into other snippets.

Only the four newest command phrases—not their bodies—are eligible for Whisper's fixed prompt
budget. Every saved trigger remains available to the deterministic expander. This keeps startup
and per-dictation costs bounded even when the local library grows large.

Vocabulary and snippet CLI writes are atomic, so a running daemon observes a complete old or new
library on the next recording. It never needs to reload the Core ML model or restart the process.

### `TranscriptHistory`

Successful, non-empty transcripts are appended to one Markdown file per local calendar day
under `~/.local/share/parrot/transcripts/`. The actor serializes writes from overlapping
transcription tasks. Its directory is forced to mode `0700` and each file to `0600`.
`--no-history` disables all history writes for that daemon run.

All daemon appends and CLI reads share a directory-level advisory lock; retention rewrites take
the exclusive side of that same lock. This coordinates separate Parrot processes and prevents a
cleanup from replacing a file while a completed transcript is being appended. Readers and cleanup
accept only exact daily filenames backed by regular, non-symlink files.

History remains unbounded by default for backward compatibility. A saved
`historyRetentionDays` value opts into an exact rolling 24-hour policy. The daemon applies it once
at startup, then at most hourly after successful delivery so cleanup never extends recording,
model, or cursor-delivery latency. `parrot history prune` builds the same plan under a shared lock
and changes no transcript files unless `--confirm` is supplied; the confirmed path rebuilds its
plan under an exclusive lock before applying it. Entire days before the cutoff day are deleted.
On the cutoff day, stable marked entries are trimmed individually, while ambiguous legacy content
is preserved. Journals and arbitrary Markdown paths are outside this subsystem.

`LastRecordingRecovery` provides one bounded audio recovery slot. Before inference, accepted
16 kHz mono samples are streamed as a private PCM WAV and atomically renamed to
`~/.local/share/parrot/recovery/last-recording.wav`; this avoids materializing a second complete
audio buffer for a long hands-free note. Successful cursor or journal delivery removes the WAV,
while inference failure or process interruption leaves it for the next launch. The daemon keeps
the latest successful samples only in memory so **Retry Last Recording** can reuse the warmed
model and current mode; a new accepted capture replaces them, and **Forget Last Recording**
clears memory and disk. Recovery therefore does not become an unbounded audio history.

Each new entry includes an HTML-comment marker containing a stable, timestamp-derived ID. The
comment stays invisible in rendered Markdown while allowing `TranscriptHistoryReader` to parse
note bodies containing arbitrary Markdown headings. A compatibility parser reads unmarked files
from older releases. `parrot history` exposes recent listing, local full-text search, exact show,
latest-text output for pipes, clipboard recovery, and the underlying directory path.

New entries also include a hidden metrics comment with audio and transcription milliseconds
and, when available, the recognized language code.
`parrot stats` combines those measurements with localized word counts to report voice time,
speaking pace, processing speed, and an optional typing-time comparison. Counts and streaks
include old entries without timing metadata. All calculation reads the local Markdown directly;
there is no telemetry store or network call.

### File transcription

`parrot transcribe` accepts AVFoundation-readable audio and video without starting AppKit,
the microphone, Accessibility APIs, or the daemon. It resolves saved model/mode/casing defaults,
then loads vocabulary and snippets once. One registry-selected `Transcriber` is warmed for the
batch and files are processed sequentially, so model memory is not multiplied.

WhisperKit uses its incremental loader with 120-second staging and one buffered chunk.
FluidAudio's compact Parakeet path streams from disk; Unified uses overlapping 15-second model
windows and reports emission timings. Parrot projects either engine's result into the same
compact report containing final text, language, duration, processing time, real-time factor,
and segment start/end/text.

Markdown is the default output and includes both the deterministically formatted note and a
timestamped timeline. Text and schema-versioned JSON are also supported. Output planning occurs
before model load, rejects duplicate destinations and input replacement, and refuses existing
files unless `--force` is explicit. `SafeTranscriptWriter` uses a `0600` temporary file, `fsync`,
then an atomic no-clobber or replacement rename; newly created output directories are `0700`. Input media is
opened read-only and never added to normal dictation history.

### Daemon lifecycle and logs

An advisory lock at `~/.config/parrot/daemon.lock` is held for the process lifetime, preventing
a foreground invocation and LaunchAgent from both owning the global hotkey and microphone.
The LaunchAgent keeps operational stdout/stderr under `~/Library/Logs/Parrot/` with directory
mode `0700` and file mode `0600`; normal completion logs include latency and character count,
not transcript text. Oversized inherited logs are capped at 5 MiB on launch. `--log-transcripts`
is an explicit privacy-sensitive debugging opt-in.

`parrot daemon status|start|stop|restart|logs` wraps the user launchd domain. The existing
`com.digimata.parrot` label is retained for upgrade compatibility, bootstrap errors are fatal
to installation, and failed launches are throttled to 30 seconds.

### `RecordingOverlay`

A single borderless `NSWindow` displayed at the bottom-center of the active screen while recording. Provides visual feedback that the mic is hot — the only piece of UI in the app.

Window configuration:
- `styleMask: .borderless`
- `backgroundColor: .clear`, `isOpaque: false`, `hasShadow: true`
- `level: .statusBar` (or `.floating`) — sits above all other windows
- `ignoresMouseEvents = true` — clicks pass through to whatever is underneath
- `collectionBehavior: [.canJoinAllSpaces, .stationary, .ignoresCycle]` — visible across Spaces, doesn't appear in window switcher

Content: a compact SwiftUI waveform hosted via `NSHostingView`. `AudioCapture` emits RMS only
while recording, and `AudioLevelCoalescer` keeps only the newest sample behind at most one
scheduled main-queue delivery. A slow UI therefore cannot accumulate audio-buffer tasks.

States:
- **Hidden** — idle. No window on screen.
- **Recording** — shown on `.pressed`, mic level animated.
- **Transcribing** — brief spinner state between hotkey release and text injection (usually <500 ms).
- **Hidden** — back to idle after injection.

This is the only reason the process needs an `NSApplication` run loop instead of a bare `CFRunLoop`.

### `ModelRegistry`

JSON-driven, mirrors OpenWhispr's pattern:

```swift
struct TranscriptionModel: Codable {
    let id: String              // "whisper-large-v3-turbo"
    let displayName: String
    let engine: Engine          // .whisperKit | .parakeet
    let sizeMB: Int
    let downloadURL: URL
    let languages: [String]
    let recommended: Bool
}

enum Engine: String, Codable { case whisperKit, parakeet }
```

Backed by a hardcoded array in `ModelRegistry.swift` — *not* a JSON resource.
The `models.json` resource bundle was dropped so the executable ships as a true
single binary with nothing to install alongside it. Adding a model = appending an entry. Adding an engine = one new `Transcriber` conformance + one entry in the `Engine` enum.

The registry is the single source of truth for: download URLs, file names, sizes, recommended flags, what shows up in `parrot models list`.

`parrot models benchmark` loads any AVFoundation-readable local audio file through the shared
16 kHz conversion path, warms one registered model through `TranscriberFactory`, and repeats
inference on the same samples. It reports load time separately from median inference latency and real-time
factor. An optional reference transcript adds locally computed, case/punctuation-insensitive
word-error rate. `--spoken-mode-trigger` exercises the live leading-trigger path. JSON output
includes the hardware model, macOS version, exact run timings, requested/effective mode,
automatic-paragraph state, and vocabulary count so results remain comparable. No audio,
reference, or transcript leaves the Mac.

### Model storage and download progress

`ModelStorage` passes explicit destinations to WhisperKit and FluidAudio, so all new model
downloads land under `~/Library/Application Support/Parrot/models/` instead of the library default in
Documents. Before downloading, it recognizes a complete model in either managed storage or
the older `~/Documents/huggingface/` layout. Managed storage wins when both exist; otherwise
the legacy model is loaded in place with its existing tokenizer cache, avoiding a redownload.

`parrot models migrate` is deliberately explicit because the old Hugging Face tree may be
shared with another local tool. It moves only complete model variants known to Parrot, never
overwrites an existing destination, and leaves an absolute compatibility symlink for each
moved model. The daemon ownership lock must be available before migration begins.

The engine libraries perform each transfer. `ModelDownloadProgress` consumes their progress
callback, repainting stderr at 1% increments in a terminal and emitting newline-delimited
10% increments for noninteractive logs. This keeps first-run feedback visible without
flooding LaunchAgent logs.

### `Config`

A `Codable` struct at `~/.config/parrot/config.json`, holding the chosen microphone UID,
lowercase preference, first-run completion flag, and optional defaults for hotkey, model,
dictation/notes mode, pause-aware paragraphs, speech cleanup, warm/cold microphone policy,
cursor spacing, and delivery destination.
Every field is optional,
so older config files decode unchanged and nil continues to mean "use the built-in default."

JSON rather than the TOML originally sketched: `Codable` gives it to us for free, and a TOML
parser would have been a new dependency for a handful of keys. The directory and file are
forced to `0700` and `0600` respectively; the first read upgrades permissions left by older
releases without rewriting the file.

Precedence is CLI flags > saved config > interactive prompt > built-in default. Missing or
corrupt config is treated as a first run, never an error. `parrot settings show|set|reset`
manages the daemon defaults. Because the LaunchAgent intentionally supplies no workflow
arguments beyond `--skip-doctor`, it follows the same saved values as a foreground launch;
one-run CLI overrides never become accidental persistent state.

### Local app-mode rules

`parrot apps add <running-name-or-bundle-id> --mode notes|dictation` stores an explicit
`AppModeRule` in the same private config. At the start of each recording,
`DictationModeController` compares only `NSWorkspace.frontmostApplication.bundleIdentifier`
against those rules. It never reads window titles, accessibility text, selections,
clipboards, or pixels, and the selected application is not written to history.

The controller captures a `DictationMode` before audio capture begins. That immutable value
travels through transcription and formatting, so changing focus while Whisper runs cannot
change an in-flight result. A rule wins only for a matching foreground app and naturally
reverts to the menu-selected fallback elsewhere. Explicit `--notes` or `--dictation` disables
rules for that process. A config file signature (inode, size, and modification time) is
checked at recording start; the file is decoded only after an actual change, so rule commands
hot-reload with a measured steady-state cost of about 42 microseconds per recording with 100
rules.

`WhisperKitTranscriber` still owns one model pipeline. During its existing warmup it
precomputes separate bounded decoding options for dictation and notes. Selecting a mode is an
in-memory options choice—not a model load, a tokenizer pass, or a network request on the hot
path. The menu-bar Mode submenu changes only the fallback and is disabled while an automatic
rule controls the current app.

### `TerminalSelect`

Arrow-key menus for the first-run questions. Puts the terminal in raw mode (`ECHO` and
`ICANON` off, `VMIN`/`VTIME` set — canonical mode overloads those slots with `VEOF`/`VEOL`,
so leaving them alone makes `read()` block until four bytes arrive). Restoring the original
`termios` on every exit path is a correctness requirement, not a nicety: leaving raw mode set
would hand the user a shell with no echo and no line editing. Ctrl-C is handled in-loop rather
than left to SIGINT for that reason.

Falls back to the older typed prompt when stdin or stderr isn't a TTY.

## Permissions

Two prompts on first run, both surfaced via `parrot doctor`:

1. **Microphone** — standard `AVCaptureDevice` request, fires on first audio engine start.
2. **Accessibility** — required for `CGEventTap` (hotkey) and `CGEvent` posting (text injection). User toggles in System Settings → Privacy & Security → Accessibility, granting the *terminal* (or whatever launched parrot) permission, since the binary inherits its parent's TCC identity.

`parrot doctor` checks both and prints actionable next steps if either is missing. Without these, the daemon refuses to start.

### TCC quirk worth knowing

When you launch `parrot` from `Terminal.app`, accessibility permission is granted to *Terminal*, not parrot itself. This means:
- Switching terminals (Terminal → iTerm → Ghostty) requires re-granting permission.
- Running under `launchd` requires granting permission to whatever spawns it.

This is a macOS platform behavior, not a parrot bug. `parrot doctor` will identify the parent process and tell the user which app needs the permission.

## Models — what ships

Current registry:

| Engine | Model | Size | Notes |
|---|---|---|---|
| WhisperKit | `whisper-base.en` | ~145 MB | Default; quickest load and lowest memory |
| WhisperKit | `whisper-base` | ~147 MB | 100 languages; explicit or automatic detection |
| FluidAudio | `parakeet-tdt-ctc-110m.en` | ~331 MB | Optional; smallest and fastest Parakeet |
| FluidAudio | `parakeet-unified.en` | ~614 MB | Optional; punctuation-aware English Parakeet |
| WhisperKit | `whisper-small.en` | ~488 MB | More accurate English, higher latency |
| WhisperKit | `whisper-small` | ~486 MB | Higher-capacity multilingual Whisper |
| WhisperKit | `whisper-large-v3-turbo` | ~1.62 GB | Highest-capacity multilingual option |

Models are not bundled. New downloads live in
`~/Library/Application Support/Parrot/models/`; complete models from the legacy
`~/Documents/huggingface/` layout remain usable until the user runs
`parrot models migrate`.

## Data flow, end-to-end

1. User runs `parrot` in a terminal.
2. `ParrotCLI` validates permissions (`parrot doctor` logic), loads config, instantiates modules.
3. Sets `.accessory` activation policy and enters `NSApp.run()`. Status: `listening`. Overlay hidden.
4. User holds Fn.
5. `HotkeyMonitor` fires `.pressed`. `RecordingOverlay` shows. Status: `recording`.
6. `AudioCapture` flips its capturing flag and seeds from the pre-roll ring (the session is already running). Buffers fill. Overlay animates mic level.
7. User releases Fn.
8. `HotkeyMonitor` fires `.released`. Overlay switches to spinner. Status: `transcribing`.
9. `AudioCapture` stops and `LastRecordingRecovery` atomically stages one private safety WAV.
10. The active `Transcriber` runs CoreML inference and returns text plus its language code.
11. In note mode, `AudioPauseDetector` and `AutomaticParagraphFormatter` conservatively insert
    blank lines at deliberate pauses. `SpeechCleanup` optionally removes conservative English
    disfluencies and is skipped for every other detected language; then `NoteFormatter` applies
    explicit Markdown structure commands.
12. `SnippetExpander` replaces explicit saved-snippet commands with their local bodies, which
    are never passed through cleanup or note formatting.
13. `TextInjector` posts the string at the cursor, or `MarkdownJournal` durably appends it when
    journal delivery is selected. `TranscriptHistory` independently saves the recovery copy.
14. The safety WAV is removed after delivery; the samples remain in memory for one-click retry.
    Overlay hides. Status: `listening`. Loop.
15. User hits `^C`. Process exits cleanly.

`DictationLifecycle` serializes this loop as idle → recording → transcribing → idle and assigns
each capture a generation token. Hotkey presses during transcription are ignored, and only the
current generation may inject text or reset UI. Before inference, `CaptureQuality` rejects
captures under 250 ms or below a conservative RMS floor; `--no-audio-gate` is the explicit
debugging escape hatch. Retrying a previous capture enters the same single-flight transcription
phase directly, so retry cannot overlap a new recording or load a second model.

End-to-end latency target: <500 ms after hotkey release for utterances under 10 seconds, on Apple Silicon.

## What we are deliberately NOT building

- No streaming partial transcripts in v1. Press, speak, release, get full text.
- No VAD-based hands-free mode. Push-to-talk is more reliable and uses zero idle CPU.
- No cloud transcript sync or hosted account. History, vocabulary, and settings stay local.
- No general-purpose AI rewriting in the core dictation path. Vocabulary prompting and exact
  replacements are bounded, deterministic, and on-device.
- No settings window or dock app. Configuration remains CLI-first; runtime status and actions
  are available from the menu bar.

These are deliberate cuts. Each can be revisited if real usage demands it.

## Project layout (planned)

Organized by feature area. These are folders within a single SPM executable target — Swift sees them as one module, but the directory grouping keeps related code together. If a group later earns its keep as a reusable library (e.g. `Transcription` consumed by another tool), it can be promoted to its own SPM target with no rewriting.

As built (differences from the original plan noted inline):

```
parrot/
  Package.swift                 # SPM, single executable target
  Sources/parrot/
    Parrot.swift                # entry point, subcommands, the product loop
    Doctor.swift                # permission + Fn-mapping checks
    Setup.swift                 # interactive first-run permission grant
    Install.swift               # LaunchAgent CLI lifecycle controls
    Config.swift                # private persistent defaults and precedence
    Settings.swift              # saved default management CLI
    Apps.swift                  # app-mode rule CLI
    AppModeRules.swift          # frontmost bundle-id mode policy + hot reload

    Daemon/
      DaemonLock.swift          # cross-process hotkey/mic ownership lock
      LaunchAgentManager.swift  # private logs and launchctl management

    Transcription/
      Transcriber.swift         # protocol (decorative for now — see roadmap 6.5)
      WhisperKitTranscriber.swift
      FileTranscription.swift   # incremental import, reports, safe output writer

    Models/
      ModelRegistry.swift       # hardcoded array, not JSON
      ModelStorage.swift        # managed cache, legacy reuse, explicit migration
      ModelDownloadProgress.swift # bounded interactive/log progress output
      TranscriptionModel.swift  # Codable types

    Audio/
      AudioCapture.swift        # AVCaptureSession + pre-roll ring buffer
      AudioDevices.swift        # CoreAudio input enumeration/selection

    Input/
      HotkeyMonitor.swift       # CGEventTap
      Hotkey.swift              # hotkey names, keycodes, parsing
      TextInjector.swift        # CGEvent posting

    UI/
      RecordingOverlay.swift    # borderless NSPanel + SwiftUI pill
      MenuBarController.swift   # NSStatusItem

  docs/
    architecture.md             # this file
    codebase-notes.md           # how it actually works + open findings
    releasing.md                # cutting a release
  .plan/
    plan.md                     # original M0-M8 milestones
    roadmap.md                  # active work
  README.md
```

`ParakeetTranscriber.swift` is implemented through FluidAudio. `Resources/models.json` remains
intentionally unbuilt: the typed source registry keeps the shipped executable self-contained.
WhisperKit and FluidAudio perform model transfers, while Parrot owns destinations, completeness
checks, and bounded progress reporting. The SwiftPM test target lives at `Tests/parrotTests/`.

Build: `swift build -c release`. Resulting binary at `.build/release/parrot`. Install: copy to `~/.local/bin/` or `/usr/local/bin/`.

### On Swift "modules"

Swift's module unit is the **SPM target** (one target = one module = one `import` namespace). For parrot v1 we use a single executable target with the folder structure above; everything is in the same module so no `import` statements between files. If we ever want enforced boundaries (e.g. `Transcription` and `UI` shouldn't reach into `Audio` internals), we promote folders to separate targets in `Package.swift` — a structural change, not a semantic one.

## Open questions

- **First-run UX.** Bundle `whisper-base.en` so `parrot` works out of the box, or always require an explicit download? Probably the latter — keeps the binary small and the model directory clean.

Settled since the original draft:

- **Parakeet integration** — FluidAudio 0.15.6. It provides maintained model downloads,
  compact disk-backed file transcription, Unified timing output, and tested Core ML execution.
  Parrot keeps both engines opt-in based on its own same-audio benchmark rather than changing
  the default from an upstream headline number.

- **AUHAL vs. `AVCaptureSession` for the input path** — `AVCaptureSession`. Measured to isolate
  fully from the system default device, and it delivers 16 kHz mono Float32 directly via
  `audioSettings`, so no conversion layer was needed. AUHAL would have been more code for no
  demonstrated benefit.
- **Code signing** — yes. Ad-hoc signing keys the TCC grant to the cdhash, so Accessibility
  is silently revoked on every update. A Developer ID identity is available; wiring it into
  the release workflow is roadmap 5.2.
- **Hotkey conflicts** — solved by making the hotkey configurable (`--hotkey`,
  `parrot hotkeys`) rather than by picking a universally-safe default. There isn't one: Fn
  doesn't exist on third-party keyboards at all.

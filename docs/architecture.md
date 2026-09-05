# Architecture

## Goals

1. **CLI executable.** Single binary, launched from the terminal. No menubar, no dock icon, no settings window.
2. **Push-to-talk.** Hold Fn, speak, release — transcript appears at the cursor.
3. **Minimal recording feedback.** A small floating pill at the bottom of the screen while recording, so the user knows the mic is hot. Click-through, borderless, hidden when idle.
4. **On-device.** No network calls for transcription. Audio never leaves the machine.
5. **Pluggable models.** Whisper out of the box; Parakeet (or future engines) via a JSON-driven registry.
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

Argument parsing (via `swift-argument-parser`), config loading, module wiring. Calls `NSApplication.shared.setActivationPolicy(.accessory)` so the process has no dock icon and no menu bar entry, then runs `NSApp.run()` to keep the process alive and drive the AppKit run loop (needed for `NSWindow`, `CGEventTap`, and AVFoundation). Exits cleanly on SIGINT. Logs status to stderr so a user running it in a terminal can see what's happening.

Subcommands:
- `parrot` (default) — run the daemon
- `parrot models list` — show registered models, mark which are downloaded
- `parrot models download <id>` — pre-fetch a model
- `parrot doctor` — check microphone and accessibility permissions, print remediation steps
- `parrot vocabulary` — manage local recognition hints and exact text replacements

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
waits out that window; longer push-to-talk holds still stop immediately. While locked, a second,
temporary event tap watches for the first non-hotkey `keyDown`, consumes that key and its
matching `keyUp`, and ends the recording. Keeping this in a separate tap means ordinary
push-to-talk mode still does not observe unrelated keystrokes. Pressing the hotkey once more
also ends a locked recording.

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
hold yields ~1.78 s of audio. `--cold-mic` reverts to opening the device only while the key is
held, trading the clipped leading audio for no idle mic indicator.

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

### `AudioDevices`

CoreAudio enumeration and selection: `parrot devices` lists inputs with transport type,
`--input-device <name|uid>` pins one (substring match, case-insensitive), and
`--allow-bluetooth-input` opts back into a Bluetooth mic. When the system default is
Bluetooth, parrot prefers the built-in mic and says so.

### `Transcriber` (protocol)

```swift
protocol Transcriber {
    func transcribe(_ audio: [Float]) async throws -> String
    var modelID: String { get }
}
```

Concrete implementations:

- `WhisperKitTranscriber` — wraps the `WhisperKit` package. CoreML, ANE-accelerated.
- `ParakeetTranscriber` — wraps `FluidAudio` (or direct CoreML) for NVIDIA Parakeet TDT.

Adding an engine = one new file conforming to `Transcriber`.

### `TextInjector`

`CGEventCreateKeyboardEvent` + `CGEventKeyboardSetUnicodeString` — pastes the transcript at the current cursor position. Works in nearly every text field on macOS (some Electron apps and secure fields are flaky; platform constraint).

### `PersonalVocabulary`

Local vocabulary lives at `~/.config/parrot/vocabulary.json` with mode `0600`. Short preferred
spellings are encoded into Whisper prompt tokens once when the model warms up. The prompt is
capped at 96 tokens and prioritizes the most recently added terms, bounding both prefill cost
and context usage regardless of vocabulary size.

After transcription and annotation cleanup, a single deterministic replacement pass applies
`spoken → written` mappings case-insensitively at word/phrase boundaries. Matches are computed
against the original transcript, so replacements cannot cascade. This gives exact results for
recurring names and jargon without an LLM, network request, or variable post-processing latency.

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

### `SnippetLibrary` / `SnippetExpander`

Reusable multiline text lives in owner-readable `~/.config/parrot/snippets.json`. The explicit
phrase `insert snippet <trigger>` expands after note and lowercase formatting, which preserves
the body byte-for-byte while still formatting surrounding dictation. `literal insert snippet
<trigger>` escapes expansion. The compiled matcher scans the original transcript once and
applies replacements back-to-front, so inserted bodies cannot cascade into other snippets.

Only the four newest command phrases—not their bodies—are eligible for Whisper's fixed prompt
budget. Every saved trigger remains available to the deterministic expander. This keeps startup
and per-dictation costs bounded even when the local library grows large.

### `TranscriptHistory`

Successful, non-empty transcripts are appended to one Markdown file per local calendar day
under `~/.local/share/parrot/transcripts/`. The actor serializes writes from overlapping
transcription tasks. Its directory is forced to mode `0700` and each file to `0600`; audio is
never stored. `--no-history` disables all history writes for that daemon run.

Each new entry includes an HTML-comment marker containing a stable, timestamp-derived ID. The
comment stays invisible in rendered Markdown while allowing `TranscriptHistoryReader` to parse
note bodies containing arbitrary Markdown headings. A compatibility parser reads unmarked files
from older releases. `parrot history` exposes recent listing, local full-text search, exact show,
latest-text output for pipes, clipboard recovery, and the underlying directory path.

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

Content: a small SwiftUI view hosted via `NSHostingView`, showing a pulsing dot + "listening" text, optionally a live mic level meter fed from `AudioCapture`. Total footprint: ~120pt wide, ~40pt tall, positioned 60pt above the bottom of the screen.

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

`parrot models benchmark` loads any AVFoundation-readable local audio file through
WhisperKit's 16 kHz conversion path, warms one registered model, and repeats inference on the
same samples. It reports load time separately from median inference latency and real-time
factor. An optional reference transcript adds locally computed, case/punctuation-insensitive
word-error rate. JSON output includes the hardware model, macOS version, exact run timings,
note-mode state, and vocabulary count so results remain comparable. No audio, reference, or
transcript leaves the Mac.

### `ModelDownloader` — not built

WhisperKit handles downloading itself, so there is no `ModelDownloader.swift`.
Two consequences:

- **Models land wherever `swift-transformers` puts them**, which defaults to
  `~/Documents/huggingface` — the user's Documents folder, iCloud-synced on many
  Macs. `WhisperKitConfig(downloadBase:)` fixes this; tracked as 1.4 in the roadmap.
- **There is no progress output.** `verbose: false` means the first run prints
  nothing through a 145 MB–1.6 GB fetch and looks hung. Tracked as 4.2.

### `Config`

A `Codable` struct at `~/.config/parrot/config.json`, holding the chosen microphone UID,
whether lowercase mode is on, and a flag marking first-run setup complete. Every field is
optional, and nil means "not yet decided" — that's what separates a first run (ask) from a
later one (respect the earlier answer, including a "no").

JSON rather than the TOML originally sketched: `Codable` gives it to us for free, and a TOML
parser would have been a new dependency for three keys.

Precedence is CLI flags > saved config > interactive prompt > built-in default. Missing or
corrupt config is treated as a first run, never an error.

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
| WhisperKit | `whisper-base.en` | ~145 MB | Default; fastest English dictation |
| WhisperKit | `whisper-small.en` | ~488 MB | More accurate English, higher latency |
| WhisperKit | `whisper-large-v3-turbo` | ~1.62 GB | Highest-capacity multilingual option |

Models currently live in `~/Documents/huggingface/` (WhisperKit's default). Not bundled — fetched on first selection or via `parrot models download`.

## Data flow, end-to-end

1. User runs `parrot` in a terminal.
2. `ParrotCLI` validates permissions (`parrot doctor` logic), loads config, instantiates modules.
3. Sets `.accessory` activation policy and enters `NSApp.run()`. Status: `listening`. Overlay hidden.
4. User holds Fn.
5. `HotkeyMonitor` fires `.pressed`. `RecordingOverlay` shows. Status: `recording`.
6. `AudioCapture` flips its capturing flag and seeds from the pre-roll ring (the session is already running). Buffers fill. Overlay animates mic level.
7. User releases Fn.
8. `HotkeyMonitor` fires `.released`. Overlay switches to spinner. Status: `transcribing`.
9. `AudioCapture` stops, hands buffer to active `Transcriber`.
10. `Transcriber` runs CoreML inference. Returns string.
11. If `--notes` is active, `NoteFormatter` applies explicit Markdown structure commands.
12. `SnippetExpander` replaces explicit saved-snippet commands with their local bodies.
13. `TextInjector` posts the string at the cursor and `TranscriptHistory` saves it locally.
14. Overlay hides. Status: `listening`. Loop.
15. User hits `^C`. Process exits cleanly.

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

    Daemon/
      DaemonLock.swift          # cross-process hotkey/mic ownership lock
      LaunchAgentManager.swift  # private logs and launchctl management

    Transcription/
      Transcriber.swift         # protocol (decorative for now — see roadmap 6.5)
      WhisperKitTranscriber.swift

    Models/
      ModelRegistry.swift       # hardcoded array, not JSON
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

Not built: `Config.swift`, `ModelDownloader.swift`, `ParakeetTranscriber.swift`,
`Resources/models.json`. No test target yet (roadmap 1.2).

Build: `swift build -c release`. Resulting binary at `.build/release/parrot`. Install: copy to `~/.local/bin/` or `/usr/local/bin/`.

### On Swift "modules"

Swift's module unit is the **SPM target** (one target = one module = one `import` namespace). For parrot v1 we use a single executable target with the folder structure above; everything is in the same module so no `import` statements between files. If we ever want enforced boundaries (e.g. `Transcription` and `UI` shouldn't reach into `Audio` internals), we promote folders to separate targets in `Package.swift` — a structural change, not a semantic one.

## Open questions

- **Parakeet via FluidAudio vs. direct CoreML?** FluidAudio is faster to integrate but adds a dependency. Decide once we benchmark both. Tracked as issue #1 upstream.
- **First-run UX.** Bundle `whisper-base.en` so `parrot` works out of the box, or always require an explicit download? Probably the latter — keeps the binary small and the model directory clean.

Settled since the original draft:

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

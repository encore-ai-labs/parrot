# Roadmap — active maintenance

Follow-on to [`docs/codebase-notes.md`](../docs/codebase-notes.md), which has the evidence for
each item. Numbers in parentheses (3.2, 3.6, …) reference findings there.

Decisions locked in:
- **Always-hot mic + pre-roll ring buffer.** Accepts a permanently-lit mic indicator to
  eliminate clipping entirely.
- **Developer ID signing.** Stable TCC identity so Accessibility grants survive updates.
- **Repo stays internal to encore-ai-labs.** See [`docs/releasing.md`](../docs/releasing.md).

Ordering is cheapest-first within each phase, and each phase is independently shippable.

---

## Phase 1 — stop corrupting output

Small diffs, no design questions, immediate correctness win. Ship as one release.

**1.1 Rewrite `sanitize()` (3.2)** — ✅ **done.** Moved to `TranscriptSanitizer`, which only
removes a bracketed span when there's positive evidence it's an annotation: a `<|...|>` control
token, contents matching a known non-speech phrase, a SHOUTED_TAG in square brackets, or the
span being the entire transcript. Everything else is kept — a stray `[MUSIC]` is a visible
annoyance the user can delete, while silently dropping half a sentence is a bug they may never
notice.

**1.2 Add a test target** — ✅ **done**, `Tests/parrotTests/`. No library split was needed:
SwiftPM links a test target against an executable target fine. Seeded with every regression
case from notes §3.2.

**1.3 Minimum-duration + energy gate (3.5)** — drop captures under ~300 ms or below an RMS
floor before they reach Whisper. `computeRMS` is already being calculated and thrown away at
`Parrot.swift:114`. Kills the "accidental Fn brush injects a hallucination" failure.

**1.4 Move the model cache out of `~/Documents` (3.3)** — ✅ **done.** New downloads use
`~/Library/Application Support/Parrot/models`. Existing complete models are reused in place;
an explicit migration moves only known variants, never overwrites, and leaves compatibility
links rather than moving another tool's whole Hugging Face tree.

---

## Phase 2 — the audio path ✅ **done**

Shipped: `AudioCapture` rebuilt on `AVCaptureSession` with a hot session and a 300 ms pre-roll
ring buffer.

**2.0 Move off `AVAudioEngine`'s default-device binding** — ✅ **done, via `AVCaptureSession`.**

`AVAudioEngine` opened the *system default* input the instant `engine.inputNode` was touched,
before any rebinding could apply. With a Bluetooth headset as default that dragged it onto HFP
and wrecked playback — even when parrot was recording from a different mic, which is exactly
what a user hit in practice. Measured, headset as system default while capturing from USB:

```
AVAudioEngine      inputNode accessed -> 44100 Hz -> 16000 Hz, never recovers
AVCaptureSession   full session cycle -> 44100 Hz throughout
```

`AVCaptureSession` opens only the device it's handed. It also honors an `audioSettings` request
for 16 kHz mono Float32 directly, so the `AVAudioConverter` path was deleted rather than ported.

**2.1 Hot session + pre-roll** — ✅ **done.** The session runs from daemon start; the hotkey
just flips a flag and seeds the capture from a 300 ms ring. A 1.5 s hold now yields 1.78 s of
audio (was 0.90 s), so the front of an utterance is never clipped and the main thread never
blocks on device startup.

**2.5 `--cold-mic` escape hatch** — ✅ **done.** Opens the mic only while the key is held.

**2.6 README note on the always-on mic indicator** — ✅ **done.**

Still open:

**2.2 Device changes** — ✅ **done.** Active-device disconnects cancel discontinuous captures,
rebuild the session on a safe non-virtual/non-Bluetooth fallback, and restore the selected mic
when it reconnects.

**2.3 Sleep/wake** — ✅ **done.** Workspace sleep stops the capture session and clears pre-roll;
wake rebuilds and restarts it. AVFoundation interruption-end and runtime-error notifications
share the same serialized, bounded-backoff recovery path.

**2.4 Allocation on the audio callback** — ✅ **done.** The delegate consumes the CoreMedia
`UnsafeBufferPointer` directly for capture, pre-roll, and RMS instead of materializing an
`Array` for every buffer. The short lock remains to synchronize hotkey stop/start handoff.

**2.7 Live mic switching** — ✅ **done.** The menu-bar microphone submenu shows the actual input,
fallback state, and Bluetooth/virtual warnings. Idle selection safely rebuilds the session without
restarting, persists the chosen device at the front of the existing fallback order, and refreshes
only on connection events.

---

## Phase 3 — state machine and reliability

**3.1 One explicit state machine (3.4, 3.7)** — an `idle | recording | transcribing` enum
owned on the MainActor. Presses while transcribing are ignored (or queued). Fixes the
overlapping-recording cross-talk where an old transcription hides the overlay for a new
recording and injects into whatever is focused *now*. Also lets the overlay's delayed
`orderOut` carry a generation token so a fast re-press can't hide a live recording.

**3.2 Re-enable the tap when macOS disables it (3.6)** — ✅ **done.**

**3.3 Filter to `.flagsChanged` before copying (3.17)** — ✅ **done.** Modifier hotkeys now
subscribe to `flagsChanged` only; `keyDown`/`keyUp` are added only for plain-key hotkeys or
`--debug-hotkey`.

**3.4 Multi-monitor overlay (3.11)** — position the pill on the screen containing
`NSEvent.mouseLocation` instead of `NSScreen.main`, which is meaningless for an `.accessory`
app with no key window.

---

## Phase 4 — privacy and first-run feel

**4.1 Stop logging transcripts by default (3.12)** — full transcript text moves behind
`--verbose`; the default line keeps timing and character count only. Under the LaunchAgent,
logs move from world-readable `/tmp/parrot.err.log` to `~/Library/Logs/parrot/` with
rotation. A permanent plaintext record of everything ever dictated contradicts the product's
whole pitch.

**4.2 Download progress (3.13)** — ✅ **done.** WhisperKit's callback drives a 1% repainting
stderr indicator in terminals and bounded 10% lines in daemon logs. Model warmup and explicit
downloads both print a ready result.

**4.3 Trailing space on injection** — back-to-back dictations currently concatenate into
`helloworld`. Default to appending a space, with `--no-trailing-space` to opt out.

**4.4 `DecodingOptions`** — pass a language hint and cap temperature fallback, the main lever
against Whisper hallucination loops. Currently unset.

---

## Phase 5 — packaging, signing, distribution

**5.1 Embed an `Info.plist` (3.9)** — via `-sectcreate __TEXT __info_plist`, carrying
`NSMicrophoneUsageDescription`. Required once parrot runs under launchd with its own TCC
identity rather than inheriting the terminal's.

**5.2 Developer ID signing + hardened runtime** — the real fix for TCC grants dying on every
update (3.8). Note the hardened runtime **requires** the
`com.apple.security.device.audio-input` entitlement or the mic silently stops working.

**5.3 Notarization** — Gatekeeper hygiene for anyone who downloads the tarball in a browser.
Lower priority than 5.2: `curl` doesn't set the quarantine xattr, so the `curl | sh` path is
unaffected either way.

**5.4 LaunchAgent must fail loudly (3.10)** — today, a missing Accessibility grant means exit
1 → `KeepAlive` relaunch → an invisible 10-second crash loop. Run the doctor checks even
under launchd, surface a user-visible notification, and exit in a way that doesn't spin.

**5.5 `parrot update` subcommand** — self-update against the private repo's releases. See
[`docs/releasing.md`](../docs/releasing.md).

---

## Phase 6 — maintainability

**6.1 CI on pull requests** — ✅ **done**, `.github/workflows/ci.yml` builds and tests on
push to master and on PRs. Note the fork gate still applies to `push` events, so PR runs are
the reliable trigger until workflows are enabled in the Actions tab.

**6.2 `--version`** — ✅ **done.** Release builds are stamped from their `v*` tag; local
source builds report `development`.

**6.3 Implement `--hotkey` (3.14)** — ✅ **done.** Modifiers with left/right disambiguation,
plain keys (F13–F20, End, Home, Page Up/Down, Forward Delete) swallowed via `.defaultTap`,
`--hotkey keycode:<n>` escape hatch, and `parrot hotkeys` for discovery. Turned out to matter
more than "advertised but missing": third-party keyboards never send `fn` at all, so parrot
was unusable from a mechanical keyboard.

**6.4 Delete dead code** — `ModelsManifest`, `DoctorReport.allClean`,
`configureButton(recording:)`'s unused parameter. Keep `Engine.parakeet` (tracked as issue #1).

**6.5 Add `warmUp()` to the `Transcriber` protocol** — ✅ **done.** Live dictation, file
transcription, explicit downloads, and benchmarks now instantiate engines through one factory
and operate against the same `Sendable` protocol.

**6.6 Reconcile `architecture.md`** — ✅ **done.** — it documents a TOML config, a `ModelDownloader`, an
Application Support model path, and "no menubar / no launch-at-login" as non-goals. Three of
those are wrong and two shipped anyway.

**6.7 Config file** — ✅ **done**, as `~/.config/parrot/config.json` (JSON, not TOML — no
dependency needed). Stores the chosen mic and lowercase mode, written on first run.

**6.8 Suppress the Continuity Camera deprecation log** — ✅ **done.** The single executable
embeds `NSCameraUseContinuityCameraDeviceType` and its microphone usage description in the
Mach-O `__TEXT,__info_plist` section.

**6.9 Persist daemon workflow defaults** — ✅ **done.** `parrot settings show|set|reset`
stores hotkey, model, and dictation/notes mode in the private JSON config. Foreground and
LaunchAgent startup share CLI > saved > built-in precedence; `--dictation` provides a one-run
escape from a saved notes mode.

**6.10 Local app-aware modes** — ✅ **done.** Explicit bundle-id rules hot-reload and select
dictation/notes at recording start without reading screen content or retaining active-app
history. The menu bar switches the fallback live, and both modes use precomputed prompt
options on the same model pipeline.

**6.11 Local file transcription** — ✅ **done.** `parrot transcribe` turns one file or a
sequential batch into timestamped Markdown, text, or compact JSON using one warmed model.
WhisperKit's incremental loader bounds long-recording memory, saved local text-processing
defaults apply consistently, output collisions are rejected before inference, and private
atomic writes never modify the source media.

**6.12 Atomic self-updates** — ✅ **done.** Released binaries fetch a cache-busted installer
from their immutable source tag. Installs swap the executable's directory entry rather than
overwriting a running signed Mach-O inode, and protected directories use the standard macOS
administrator authorization dialog.

**6.13 Fast local English engines** — ✅ **done.** FluidAudio-backed Parakeet 110M and Unified
INT8 are optional Core ML engines behind the same daemon, file-transcription, download, and
benchmark interfaces. Same-audio M3 Max measurements are checked into
[`docs/model-benchmarks.md`](../docs/model-benchmarks.md); Whisper Base remains the default
because it loads much faster and uses less warm memory.

**6.14 Direct local Markdown journal** — ✅ **complete.** A saved or one-run journal
destination turns each finished dictation into a timestamped Markdown section without injecting
into the focused app. It is validated before recording, uses locked and synced appends, keeps
history independently optional, and adds no inference or network work.

**6.15 Conservative local speech cleanup** — ✅ **complete.** An opt-in shared processing
pass removes unambiguous hesitation forms and bounded false starts without an LLM. Ambiguous
words and emphatic/grammatical repetition are preserved, snippet bodies bypass cleanup, and
live plus file transcription use identical saved/one-run override semantics.

**6.16 Reliable cursor delivery and last-result recovery** — ✅ **complete.** Unicode-event
insertion remains the clipboard-free default and no longer splits surrogate pairs. An explicit
clipboard/Command-V compatibility path preserves every readable pasteboard type, restores after
a bounded configurable delay, and never overwrites a newer user copy. The idle menu can reinsert
the last finalized result without inference, duplicate history, or retained audio.

**6.17 Event-driven live microphone control** — ✅ **complete.** The menu bar exposes the current
AVFoundation input and connected devices without idle polling. A lock-protected input-swap gate,
pre-roll reset, off-main session rebuild, and rollback path preserve note continuity and keep the
saved priority fallback behavior intact.

---

## Suggested release cadence

| Release | Contents |
|---|---|
| `v0.1.0` | Phase 1 — correctness + first tests |
| `v0.2.0` | Phase 2 — hot mic, zero clipping |
| `v0.3.0` | Phase 3 + 4 — reliability, privacy, first-run |
| `v0.4.0` | Phase 5 + 6 — signed builds, CI, docs true again |

Phase 1 and Phase 3.2 are the highest value-per-line in the whole list and could ship together
today if you want something in your hands immediately.

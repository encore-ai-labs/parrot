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

**1.1 Rewrite `sanitize()` (3.2)** — replace blanket bracket-stripping with a known-token
allowlist (`BLANK_AUDIO`, `MUSIC`, `Applause`, `silence`, `noise`, `nospeech`, …), matched
case-insensitively. Only strip a bracketed span if it matches a known tag, or if it's the
entire output. Stops `2 * 3` → `2`.

**1.2 Add a test target** — `Tests/parrotTests/`. Requires splitting the SPM manifest into a
`parrotCore` library target plus a thin `parrot` executable, since you can't link a test
target against an executable. Cover `sanitize` (with the table from notes §3.2 as fixtures),
`computeRMS`, `WAVWriter` round-trip, `ModelRegistry` lookup.

**1.3 Minimum-duration + energy gate (3.5)** — drop captures under ~300 ms or below an RMS
floor before they reach Whisper. `computeRMS` is already being calculated and thrown away at
`Parrot.swift:114`. Kills the "accidental Fn brush injects a hallucination" failure.

**1.4 Move the model cache out of `~/Documents` (3.3)** — set
`WhisperKitConfig(downloadBase:)` to `~/Library/Application Support/parrot/models`. Add a
one-time migration that moves an existing `~/Documents/huggingface` tree rather than
re-downloading 145 MB–1.6 GB, and leaves it alone if anything else put it there.

---

## Phase 2 — the audio path

The main UX win (3.1). Biggest change in the plan; own release.

> **Blocker discovered — read before starting.** `AVAudioEngine` binds and opens the *system
> default* input device the instant `engine.inputNode` is touched, before any code can rebind
> it. Measured against a WH-1000XM4 as default input:
>
> ```
> 0 start              headset=44100 Hz
> 1 engine created     headset=44100 Hz
> 2 inputNode accessed headset=16000 Hz   ← already dropped to HFP
> 3 AU uninitialized   headset=16000 Hz
> 4 device rebound     headset=16000 Hz   ← too late, and it never recovers
> ```
>
> Bluetooth can't do A2DP playback and mic capture simultaneously, so opening a headset's mic
> collapses its playback to call quality. **Under the always-hot design that becomes permanent
> for as long as parrot runs** — music is ruined the entire session, not just while recording.
>
> `--input-device` (shipped) picks which mic the samples come from, but cannot prevent the
> default device from being opened. The only real fixes:
>
> 1. **Rewrite the input path on AUHAL** (`kAudioUnitSubType_HALOutput`, device set before
>    `AudioUnitInitialize`) or `AVCaptureSession` with an explicit `AVCaptureDevice`. Neither
>    touches the system default. **This is a hard prerequisite for 2.1.**
> 2. Interim: warn when the default input is Bluetooth (shipped) and have the user change
>    System Settings → Sound → Input.
>
> Also fixed along the way: the tap must be installed with `inputNode.inputFormat(forBus:)`,
> not `outputFormat(forBus:)`. The latter goes stale after a device rebind, and the mismatch
> throws an **uncatchable ObjC exception** that hard-crashes the process.

**2.0 Move the input path off `AVAudioEngine`'s default-device binding** — AUHAL or
`AVCaptureSession`, per the blocker above. Everything below depends on it.

**2.1 Restructure `AudioCapture` around a hot engine**

```
daemon start ──► engine.start() once, on a background queue
                 tap permanently installed, always converting to 16 kHz
                        │
                        ▼
                 pre-roll ring buffer (last ~300 ms, preallocated, overwritten)
                        │
     Fn down ──────────►│  capturing = true; seed output with ring contents
     Fn up   ──────────►│  capturing = false; drain
```

Fn-down becomes a flag flip — no `prepare()`, no `start()`, nothing blocking the main thread,
and the capture *begins before the keypress*. Removes both the ~170 ms of lost audio and the
~65 ms main-thread stall.

**2.2 Handle device changes** — currently the engine is rebuilt per recording, so plugging in
AirPods is picked up for free. A hot engine makes this explicit work: observe
`AVAudioEngineConfigurationChange`, rebuild the converter against the new input format, and
restart the engine. Without this, 2.1 regresses every headset swap into silence.

**2.3 Handle sleep/wake** — a long-lived engine stops across sleep. Observe
`NSWorkspace.didWakeNotification` and restart. Same failure mode as 2.2 if skipped.

**2.4 Preallocate on the audio thread (3.15)** — with the tap now running continuously rather
than only while recording, the per-buffer allocations and `NSLock` in `process()` go from
"tolerable" to "happening 12×/sec forever". Preallocate the ring and the conversion buffer.

**2.5 `--cold-mic` escape hatch** — keeps the old behavior for anyone who doesn't want the
permanent mic indicator, and gives us a way to A/B if 2.1 misbehaves.

**2.6 README note** — the always-on orange mic indicator is a visible behavior change and
should be documented, not discovered.

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

**4.2 Download progress (3.13)** — wire WhisperKit's progress callback to a `\r` stderr bar so
the first run doesn't look hung through a 145 MB–1.6 GB fetch. Make `parrot models download`
print something, including on success.

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

**6.1 CI on pull requests** — today `.github/workflows/release.yml` only fires on `v*` tags,
so nothing is ever built or tested before a release. Add a build + test workflow on push/PR.

**6.2 `--version`** — doesn't exist. Wire it to a generated version string stamped at build
time so bug reports are actionable.

**6.3 Implement `--hotkey` (3.14)** — ✅ **done.** Modifiers with left/right disambiguation,
plain keys (F13–F20, End, Home, Page Up/Down, Forward Delete) swallowed via `.defaultTap`,
`--hotkey keycode:<n>` escape hatch, and `parrot hotkeys` for discovery. Turned out to matter
more than "advertised but missing": third-party keyboards never send `fn` at all, so parrot
was unusable from a mechanical keyboard.

**6.4 Delete dead code** — `ModelsManifest`, `DoctorReport.allClean`,
`configureButton(recording:)`'s unused parameter. Keep `Engine.parakeet` (tracked as issue #1).

**6.5 Add `warmUp()` to the `Transcriber` protocol** — it's currently decorative; `Run` holds
a concrete `WhisperKitTranscriber` and nothing can be generic over it. Prerequisite for the
Parakeet work in issue #1.

**6.6 Reconcile `architecture.md`** — ✅ **done.** — it documents a TOML config, a `ModelDownloader`, an
Application Support model path, and "no menubar / no launch-at-login" as non-goals. Three of
those are wrong and two shipped anyway.

**6.7 Config file** *(optional)* — `~/.config/parrot/config.toml` as promised in
`architecture.md`. Flags may genuinely be enough; decide after 6.3.

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

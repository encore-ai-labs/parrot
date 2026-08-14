# parrot

A minimal macOS dictation daemon. Push-to-talk, on-device transcription, text inserted at the cursor.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/encore-ai-labs/parrot/master/scripts/install.sh | sh
parrot setup      # grants mic + accessibility, downloads the model
parrot hotkeys    # pick a push-to-talk key — fn only works on Apple keyboards
parrot devices    # pick a mic — avoid Bluetooth if you listen to music
```

Or build it yourself — see [Build from source](#build-from-source).

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML — so the installer refuses to run on Intel.

The installer drops the binary in `/usr/local/bin/parrot`. Builds are unsigned for now, so the installer strips the quarantine xattr — once you've inspected the script you'll see exactly what it does.

## How to use

1. **Run it** in any terminal tab — `parrot`, or `parrot --hotkey end` to pick your own key.
   It lives in the menu bar while it runs; `^C` quits.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold your push-to-talk key, speak, release.** A small pill appears at the bottom of the screen while the mic is hot.
4. **The transcript types itself in at the cursor** when you release. Usually within 200-300ms.

That's it. There is no record button, no stop button, no "send" — the key is the whole interface.

> **The mic is held open the whole time parrot runs**, so macOS shows the mic-in-use
> indicator continuously. That's what lets a capture start ~300 ms *before* you press the key —
> no clipped first words. `--cold-mic` opens the mic only while the key is held, at the cost of
> losing the front of each utterance.

> **Don't use `parrot install --launch-at-login` yet.** Under `launchd` parrot gets its own
> TCC identity rather than inheriting your terminal's, and the binary is still ad-hoc signed
> with no embedded `Info.plist` — the combination produces a silent relaunch loop. A terminal
> tab is reliable today.

### Choosing a microphone

Started from a terminal, parrot asks which mic to use. Enter takes the recommended one, so
the usual case is a single keystroke:

```
microphone:
    1) Parth's iPhone Microphone      unknown
    2) WH-1000XM4                     bluetooth, ⚠ drops headset playback to call quality
    3) Logitech BRIO                  usb
  ★ 4) MacBook Pro Microphone         built-in
    5) ZoomAudioDevice                virtual, ⚠ virtual — may be silent
choose [1-5], or Enter for ★:
```

Type a number, or part of a name (`brio`). To skip the prompt:

```sh
parrot devices                # just list them
parrot --input-device brio    # pick up front, no prompt
parrot --no-pick-mic          # use the recommended one, no prompt
```

There's no prompt when there's no terminal (under `launchd`, say) — it falls through to the
recommended device.

**Don't record from Bluetooth headphones if you're listening to music on them.** macOS can't
run high-quality playback and mic capture on the same Bluetooth device at once — opening a
headset's mic drags it from A2DP (stereo, 44.1 kHz) down to HFP (mono, 16 kHz), and your audio
turns to telephone quality. parrot warns if you pick one, and defaults to a wired or built-in
mic instead.

Your headset being the *system default input* is harmless — parrot opens only the device you
chose. Picking any non-Bluetooth mic keeps your music intact, no System Settings change
needed.

### Using a different key

**On a third-party keyboard, `fn` will not work** — and not because of parrot. On those boards
`Fn` is a firmware-local layer key the keyboard handles internally to produce F-keys and media
controls; macOS never sees it at all. Only Apple keyboards emit a real `fn`. Pick another key:

```sh
parrot hotkeys                     # see every option
parrot --hotkey right-option       # the alt/option key right of the spacebar
parrot --hotkey end                # or any plain key — parrot swallows it
```

Two kinds of key work:

- **Modifiers** — `right-option`, `right-control`, `right-command`, `right-shift`, and the
  `left-` variants. Inert when held alone, so parrot leaves the keypress alone.
- **Plain keys** — `f13`–`f20`, `end`, `home`, `page-up`, `page-down`, `forward-delete`.
  These normally *do* something, so while parrot is running it swallows them — holding `end`
  to dictate won't jump your cursor to end-of-line.

For anything else, find its keycode with `parrot run --debug-hotkey`, then pass
`--hotkey keycode:<n>`. It gets swallowed too.

## CLI

```sh
parrot                                 # run in the foreground (^C to quit)
parrot setup                           # one-time setup: permissions + model download
parrot install --launch-at-login       # register a LaunchAgent (background daemon)
parrot install --uninstall             # remove the LaunchAgent
parrot doctor                          # check permissions + fn key setting
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot hotkeys                         # list push-to-talk keys
parrot devices                         # list microphones
parrot --input-device brio             # pick a specific mic
parrot --no-pick-mic                   # skip the mic prompt
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --hotkey right-option           # change the push-to-talk key
parrot --no-overlay                    # disable the bottom-of-screen pill
parrot run --debug-hotkey              # print keycodes for every key you press
```

## Stack

- **Swift** — single SPM executable target
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **AVCaptureSession** — mic capture, pinned to one device
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — recording-indicator pill

See [docs/architecture.md](docs/architecture.md) for design notes.

## Build from source

```sh
swift build -c release
.build/release/parrot --help
```

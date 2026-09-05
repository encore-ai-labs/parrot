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

On each launch, release builds check GitHub for a newer stable release without delaying
startup. Interactive launches offer to update and restart in place; the menu-bar menu also
gets an **Update Parrot…** action. You can update directly at any time with `parrot update`.
Downloaded release archives are checked against their published SHA-256 checksum before
installation. Network failures do not affect startup and are retried on the next launch.

If an update needs administrator access, Parrot hands the real terminal through to `sudo`,
so its password prompt remains interactive. A failed or cancelled update leaves the existing
binary in place; run `parrot update` again to retry.

## How to use

1. **Run it** in any terminal tab — `parrot`, or `parrot --hotkey end` to pick your own key.
   It lives in the menu bar while it runs; `^C` quits.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold your push-to-talk key, speak, release.** A small pill appears at the bottom of the screen while the mic is hot.
4. **The transcript types itself in at the cursor** when you release. Usually within 200-300ms.

Parrot handles one dictation at a time. If transcription is still finishing, another hotkey
press is ignored so an older result can never hide a newer recording or paste into a newly
focused field. Very short and near-silent captures are discarded before inference to avoid
accidental Whisper hallucinations; `--no-audio-gate` disables that safety check for debugging
an unusually quiet input.

When Fn/Globe is selected, Parrot temporarily changes macOS's bare Fn action to
**Do Nothing** while the daemon is running. That prevents the emoji picker, input-source
switcher, or Apple Dictation from racing Parrot. Your previous setting is restored on a
normal quit. Other hotkeys do not change this system preference.

For hands-free dictation, quickly double-tap the push-to-talk key. Recording stays on after
the second release; press Return, any other ordinary key, or the push-to-talk key again to
stop. The exit key is consumed, so it will not type or submit before the transcript arrives.
Press **Escape** at any point while recording to cancel and discard the audio without
transcribing, saving history, or injecting text. Escape is consumed as part of cancellation.

### Local note mode

Save note mode as your default, or use `--notes` (or `--note-mode`) for one run, to turn
explicit spoken structure into Markdown without an LLM or network request:

```sh
parrot settings set --mode notes
parrot --notes                       # one-run override
```

| Say | Markdown result |
|---|---|
| `new paragraph`, `new line` | Paragraph or line break |
| `bullet point`, `new bullet`, `next bullet` | `- ` list item |
| `numbered item`, `next numbered item` | `1. ` list item |
| `checkbox`, `new task`, `task item` | `- [ ] ` task |
| `heading`, `heading two` | `## ` heading |
| `heading one`, `heading three` | `# ` or `### ` heading |
| `period`, `comma`, `colon`, `semicolon` | Punctuation |
| `question mark`, `exclamation point`, `em dash` | Punctuation |

Note mode changes only these exact commands; it does not summarize, invent, or rewrite your
words. To speak a command literally, prefix it with `literal`—for example, `literal new
paragraph`. Normal dictation stays unchanged unless note mode is active. Use `--dictation`
for a one-run override when notes are saved as your default. Formatted Markdown is what gets
pasted and saved to local history.

### Reusable voice snippets

Save text or Markdown you type repeatedly, then insert it during either normal dictation or
note mode with an explicit voice command:

```sh
parrot snippets add signature --text $'Thanks,\nParth'
parrot snippets add "meeting notes" --file ~/Templates/meeting.md
parrot snippets list
parrot snippets show "meeting notes"
parrot snippets remove signature
```

Say **“insert snippet meeting notes”** to paste the saved template. Say **“literal insert
snippet meeting notes”** when you want those words instead of an expansion. Expansion is a
single deterministic pass: snippet bodies retain their exact capitalization and Markdown,
and a command inside a body cannot trigger another snippet.

Snippets stay in `~/.config/parrot/snippets.json` with user-only permissions (`0600`). Only
the four most recently added trigger phrases may enter Whisper's fixed prompt budget; snippet
bodies never enter model context and nothing is sent over the network. Restart a running
daemon after changing snippets.

### Transcript history

Successful dictations are also appended to daily Markdown files under
`~/.local/share/parrot/transcripts/`. The startup screen shows today's exact file. The
directory and files are restricted to your macOS user (`0700`/`0600`), and nothing is sent
anywhere. History is searchable directly from the terminal, and every result has a stable ID:

```sh
parrot history                         # newest 20 entries
parrot history search project roadmap # all words, case/diacritic insensitive
parrot history show 20260904-203827-123
parrot history last                    # transcript text only; useful in pipes
parrot history copy                    # copy latest, or pass an entry ID
parrot history path                    # print the Markdown directory
```

Search scans only the local Markdown files. New entries contain invisible Markdown comments
that provide reliable boundaries and IDs even when a note contains its own headings; history
written by older Parrot versions remains readable. For a private session that should leave no
transcript history, run:

```sh
parrot --no-history
```

### Private usage stats

`parrot stats` summarizes the Markdown history on your Mac—there is no account, telemetry
event, or network request. It reports dictations, words, characters, active days, streaks, and
the equivalent typing time. New entries also carry an invisible local timing marker, enabling
actual voice time, speaking pace, transcription speed, and an estimated time saved; older
history remains compatible and is included in every count.

```sh
parrot stats                         # all-time local summary
parrot stats --period today          # today, week, month, or all
parrot stats --typing-wpm 55         # tune the comparison to your typing speed
parrot stats --period week --json    # script-friendly output
```

That's it. There is no record button, no stop button, no "send" — the key is the whole interface.

> **The mic is held open the whole time parrot runs**, so macOS shows the mic-in-use
> indicator continuously. That's what lets a capture start ~300 ms *before* you press the key —
> no clipped first words. `--cold-mic` opens the mic only while the key is held, at the cost of
> losing the front of each utterance.

> **Don't use `parrot install --launch-at-login` yet.** Under `launchd` parrot gets its own
> TCC identity rather than inheriting your terminal's, and the binary is still ad-hoc signed
> without a stable Developer ID identity. That can produce a silent relaunch loop after an
> update revokes its permissions. A terminal tab is reliable today. The agent now throttles
> failed launches and exposes its state and logs, but stable signing is still the prerequisite
> for recommending it broadly.

If you are testing launch-at-login, Parrot prevents a second foreground or background copy
from claiming the mic and global hotkey at the same time. Operational logs are stored under
`~/Library/Logs/Parrot/` with user-only permissions, capped on launch, and transcript text is
omitted by default.
Use `parrot daemon status`, `parrot daemon restart`, and `parrot daemon logs` to diagnose it;
pass `--log-transcripts` only when you intentionally want dictated text in stderr or those logs.

### Choosing a microphone

Started from a terminal, parrot asks which mic to use. Arrow keys to move, Enter to choose —
it starts on your last choice, so the usual case is a single keystroke:

```
microphone
  Parth's iPhone Microphone  unknown
  WH-1000XM4                 bluetooth  ⚠ playback drops to call quality
  Logitech BRIO              usb
❯ MacBook Pro Microphone     built-in · recommended
  ZoomAudioDevice            virtual  ⚠ virtual — may be silent
↑↓ to move · enter to choose
```

`j`/`k` work too, as do the number keys. `q` or Ctrl-C backs out. To skip the prompt entirely:

```sh
parrot devices                # just list them
parrot --input-device brio    # pick up front, no prompt
parrot --no-pick-mic          # use the remembered one, no prompt
```

There's no prompt when there's no terminal (under `launchd`, say) — it falls through to your
remembered device, or the recommended one.

**Don't record from Bluetooth headphones if you're listening to music on them.** macOS can't
run high-quality playback and mic capture on the same Bluetooth device at once — opening a
headset's mic drags it from A2DP (stereo, 44.1 kHz) down to HFP (mono, 16 kHz), and your audio
turns to telephone quality. parrot warns if you pick one, and defaults to a wired or built-in
mic instead.

Your headset being the *system default input* is harmless — parrot opens only the device you
chose. Picking any non-Bluetooth mic keeps your music intact, no System Settings change
needed.

### Lowercase mode

The first time you run parrot it asks whether to lowercase everything:

```
lowercase mode
❯ keep capitalization   "Hey there."  (default)
  lowercase everything  "hey there."
↑↓ to move · enter to choose
```

Keeping capitalization is the default. Your answer is saved, so it only asks once. Change it any time with `--lowercase` /
`--no-lowercase`, or re-run the whole first-time setup with `--reconfigure`.

### Personal vocabulary

Teach Parrot names, acronyms, product jargon, and exact spellings that matter in your notes:

```sh
parrot vocabulary add RustPond
parrot vocabulary add "rust pond" --as RustPond
parrot vocabulary add "jay son" --as JSON
parrot vocabulary list
parrot vocabulary remove "jay son"
```

Preferred spellings bias Whisper during recognition, within a fixed prompt budget so a large
vocabulary cannot grow dictation latency without bound. Entries with `--as` also run through
a deterministic, case-insensitive replacement pass. Replacements match whole words or phrases,
never substrings, and do not cascade into one another.

The vocabulary is stored only at `~/.config/parrot/vocabulary.json` with user-only permissions
(`0600`). Restart a running daemon after changing it. No vocabulary, transcript, or audio is
sent to a server.

### Benchmark local models

New model downloads are stored locally at
`~/Library/Application Support/Parrot/models/`, outside Documents and iCloud Drive. Parrot
continues to use models downloaded by older releases from `~/Documents/huggingface/`, so an
upgrade never forces a large redownload. Inspect the exact locations and status with:

```sh
parrot models list
parrot models path
```

To move known legacy Parrot model folders into managed storage, first stop the daemon and run
`parrot models migrate`. Migration never overwrites an existing managed model and leaves
compatibility links at the old paths for other local tools. Tokenizer metadata may remain in
the shared legacy Hugging Face cache; the large Core ML model bundles are what Parrot moves.
Downloads show percentage progress in both interactive terminals and daemon logs.

Measure a model with the same audio on your own Mac instead of relying on generic benchmark
claims. Record a short representative sample (running Parrot once with `--dump-wav` writes the
last capture to `/tmp/parrot-last.wav`), then run:

```sh
parrot models benchmark whisper-base.en \
  --audio /tmp/parrot-last.wav \
  --reference "The exact words you dictated." \
  --runs 3
```

Parrot reports model-load time, every inference time, median latency, and real-time factor
(RTF; lower is faster). With a reference it also reports word-error rate (WER; lower is more
accurate). The benchmark uses your saved vocabulary and snippets by default; pass
`--no-vocabulary` and `--no-snippets` for a clean model comparison, or `--notes` to benchmark
the complete local note-formatting path.
Use `--json` to save comparable machine-readable reports. Download each candidate first with
`parrot models download <id>` so network time is not included in model-load time.

### Settings

Parrot stores settings only at `~/.config/parrot/config.json`, with user-only permissions.
The chosen microphone and lowercase choice are remembered during setup. Hotkey, model, and
note/dictation mode can be saved explicitly:

```sh
parrot settings
parrot settings set --hotkey right-option
parrot settings set --model whisper-small.en --mode notes
parrot settings reset               # resets hotkey/model/mode only
parrot daemon restart               # apply to a running LaunchAgent
```

Saved defaults are what a LaunchAgent uses, so launch-at-login no longer falls back to Fn or
plain dictation. Command-line flags remain one-run overrides: `--hotkey`, `--model`,
`--notes`, and `--dictation` take priority without changing the file. `--reconfigure` resets
the complete first-run configuration.

### App-aware modes

Parrot can automatically use note mode in selected apps and plain dictation everywhere else:

```sh
parrot apps add Notes --mode notes
parrot apps add com.apple.TextEdit --mode notes
parrot apps list
parrot apps remove Notes
parrot apps clear
```

An app name works while that app is running; its bundle identifier always works. Rules are
stored in the same private local config and hot-reload on the next recording—no daemon
restart is needed. Parrot reads only the frontmost app's bundle identifier at hotkey time. It
does not inspect window titles, selected text, clipboard contents, or screen pixels, and it
does not save the active app in transcript history or send it anywhere.

The menu-bar icon also has a **Mode** submenu for switching the fallback between Dictation
and Notes immediately. An automatic app rule temporarily wins while its app is focused, then
Parrot returns to the chosen fallback. Passing `--notes` or `--dictation` disables automatic
rules for that run. Both modes share one loaded speech model; their prompt tokens are
precomputed during warmup, so switching does not load another model or add a network step.

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
parrot --version                       # show the installed release version
parrot update                          # install the latest stable release
parrot setup                           # one-time setup: permissions + model download
parrot install --launch-at-login       # register a LaunchAgent (background daemon)
parrot install --uninstall             # remove the LaunchAgent
parrot daemon status                   # installed/loaded/running state and pid
parrot daemon start                    # start an installed LaunchAgent
parrot daemon stop                     # stop it without uninstalling it
parrot daemon restart                  # restart it after configuration changes
parrot daemon logs --lines 100         # inspect private operational logs
parrot doctor                          # check permissions + fn key setting
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot models path                     # show managed and legacy model locations
parrot models migrate                  # safely move known legacy model bundles
parrot models benchmark <id> --audio sample.wav
parrot hotkeys                         # list push-to-talk keys
parrot devices                         # list microphones
parrot apps add Notes --mode notes     # local automatic mode rule
parrot apps list                       # show saved app-mode rules
parrot vocabulary                      # list personal recognition hints/replacements
parrot vocabulary add "rust pond" --as RustPond
parrot snippets                        # list reusable local voice snippets
parrot snippets add meeting --file template.md
parrot history                         # list recent local transcripts
parrot history search project roadmap # search private Markdown history
parrot history copy                    # recover the latest transcript to clipboard
parrot stats                            # private usage/timing insights from history
parrot settings                         # show effective saved daemon defaults
parrot settings set --hotkey end --mode notes
parrot --notes                         # explicit spoken commands → local Markdown
parrot --dictation                     # override a saved notes mode for one run
parrot --input-device brio             # pick a specific mic
parrot --no-pick-mic                   # skip the mic prompt
parrot --lowercase                     # lowercase all transcribed text
parrot --no-history                    # don't save local Markdown transcript history
parrot --reconfigure                   # redo first-time setup
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

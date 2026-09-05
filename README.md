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

If the install directory needs administrator access, Parrot uses the standard macOS authorization
prompt; otherwise it updates without prompting. Parrot always swaps in a fresh executable instead
of overwriting the running binary. A failed or cancelled update leaves the existing binary in place;
run `parrot update` again to retry.

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

The microphone session recovers automatically after sleep, AVFoundation interruptions, and
media-service resets. If a selected USB/interface mic disconnects, Parrot discards any partial
recording and temporarily uses a safe built-in or wired input—never a virtual or Bluetooth mic—
then switches back when the preferred device returns. Recovery is serialized and uses bounded
backoff, so failures cannot create a busy loop.

When Fn/Globe is selected, Parrot temporarily changes macOS's bare Fn action to
**Do Nothing** while the daemon is running. That prevents the emoji picker, input-source
switcher, or Apple Dictation from racing Parrot. Your previous setting is restored on a
normal quit. Other hotkeys do not change this system preference.

For hands-free dictation, quickly double-tap the push-to-talk key. Recording stays on after
the second release; tap the selected push-to-talk key once more to stop and transcribe.
Ordinary keys, including Return, remain usable and do not stop the recording.
Press **Escape** at any point while recording to cancel and discard the audio without
transcribing, saving history, or injecting text. Escape is consumed as part of cancellation.

Cursor delivery adds one trailing boundary space by default, so consecutive captures become
`first thought. second thought.` instead of `first thought.second thought.` Existing trailing
whitespace is never doubled. This delivery-only space is not stored in history, journals, command
input, or file transcripts. Disable it for exact-input workflows with
`parrot settings set --no-space-after-paste`, or use `--no-space-after-paste` for one run.

If inference fails—or the daemon is interrupted after a recording—open the menu-bar bird and
choose **Retry Recovered Recording**. After any successful dictation, **Retry Last Recording**
can immediately reprocess the in-memory audio with the currently selected mode, without loading
a second model. **Forget Last Recording** clears both the memory copy and any recovery file.

Recovery is deliberately a single local slot, not an audio archive. Parrot writes a private
16-bit WAV to `~/.local/share/parrot/recovery/last-recording.wav` before inference, atomically
replaces it with the next accepted capture, and deletes it after successful text delivery. The
samples remain only in daemon memory until the next accepted capture or an explicit forget. A
failed or crash-interrupted inference keeps the WAV so the next daemon launch can restore it.

### Local note mode

Save note mode as your default, or use `--notes` (or `--note-mode`) for one run, to turn
explicit spoken structure into Markdown without an LLM or network request:

```sh
parrot settings set --mode notes
parrot --notes                       # one-run override
```

Long notes also get paragraph breaks automatically when you pause for at least 1.2 seconds.
Parrot measures local audio energy around recognition boundaries; it does not send text to an
LLM, infer new wording, or alter normal dictation. A break is inserted only when the timed
segments reproduce the recognized text exactly, so vocabulary replacements and model output
remain authoritative. Use `--no-auto-paragraphs` for one run or save the preference with
`parrot settings set --no-auto-paragraphs`.

| Say | Markdown result |
|---|---|
| `new paragraph`, `new line` | Paragraph or line break |
| `bullet point(s)`, `new bullet`, `next bullet (point)` | `- ` list item |
| `numbered item`, `next numbered item` | `1. ` list item |
| `checkbox`, `new task`, `task item` | `- [ ] ` task |
| `heading`, `heading two` | `## ` heading |
| `heading one`, `heading three` | `# ` or `### ` heading |
| `period`, `comma`, `colon`, `semicolon` | Punctuation |
| `question mark`, `exclamation point`, `em dash` | Punctuation |
| `scratch that`, `delete that`, `never mind` | Remove the current clause or last punctuated phrase |
| `delete last word`, `delete previous word` | Remove the latest word |
| `delete last sentence`, `delete previous sentence` | Remove the latest sentence |
| `undo that` | Restore the most recent spoken deletion |

The edit commands make corrections before text leaves Parrot. For example, saying “The deadline
is Monday, scratch that, the deadline is Tuesday” produces only “The deadline is Tuesday.”
Backtracking uses punctuation, line boundaries, and Markdown prefixes—not semantic guessing—so
it has constant model cost and preserves earlier clauses, list markers, checkboxes, and headings.
Parrot deliberately does not reinterpret an ambiguous word such as “actually”; say `scratch that`
when you want a correction.

Note mode changes only these exact commands; it does not summarize, invent, or rewrite your words.
To speak any command literally, prefix it with `literal`—for example, `literal scratch that` or
`literal new paragraph`. Editing runs after Markdown formatting but before snippet expansion, so
commands in a saved snippet body remain untouched. Normal dictation stays unchanged unless note
mode is active. Use `--dictation` for a one-run override when notes are saved as your default.
The corrected Markdown is what gets pasted, routed, and saved to local history.

To select the processing mode for just one live capture, begin with `note mode` (or `notes
mode`) or `dictation mode`. Parrot removes that leading trigger and processes the remaining
words in the requested mode, so you can say “note mode, bullet point ship the release” without
changing settings or restarting the daemon. Triggers are prefix-only to protect ordinary prose;
later mentions of “note mode” stay untouched. Say `literal note mode ...` to dictate the leading
words themselves. This switch is deterministic, adds no model or network request, and does not
apply when transcribing stored audio/video files.

### Local speech cleanup

For cleaner spoken drafts, enable Parrot's conservative on-device cleanup pass:

```sh
parrot settings set --cleanup
parrot daemon restart
```

It removes hesitation forms such as `um`, `uh`, and `erm`, exact multi-word false starts such
as “I wanted to, I wanted to…”, a small set of function-word stutters, and prefix restarts such
as “w- want”. Cleanup is deterministic text processing: it loads no language model, makes no
network request, and runs before note formatting and snippet insertion. Potentially meaningful
words and repetitions—including “like”, “right”, “okay”, “very very”, “no, no”, “had had”,
and “that that”—are deliberately preserved.

Cleanup is off by default so upgrades never rewrite established dictation unexpectedly. Use
`parrot --cleanup` for one run, `parrot --no-cleanup` to override a saved setting, or
`parrot settings set --no-cleanup` to turn it off persistently. The same flags work with
`parrot transcribe` for local audio and video files.

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

### Direct Markdown journal

For focused note-taking, route every finished dictation directly into one Markdown file instead
of typing into the frontmost app:

```sh
parrot settings set --mode notes --journal ~/Documents/Notes/inbox.md
parrot daemon restart
```

Each capture becomes a timestamped section while preserving note-mode headings, lists, tasks,
paragraphs, and snippets. The destination is validated before the microphone or model starts;
new journals and parent directories are private (`0600`/`0700`), appends are locked and synced,
and existing journal permissions are left unchanged. This is a native file output—no shell,
plugin, account, or network service receives the transcript.

Journal delivery does not duplicate text at the cursor. Parrot's private searchable history
continues independently as a recovery log; use `--no-history` when the journal should be the
only saved copy. A write failure falls back to typing at the cursor so a finished thought is
not silently lost. Override a saved destination for one run, or switch back permanently:

```sh
parrot --paste
parrot settings set --paste
```

### Local command delivery

Route each finalized dictation into any local script or CLI that accepts standard input:

```sh
parrot --command /usr/bin/pbcopy                         # one run: copy instead of paste
parrot settings set --command '$HOME/bin/route-parrot-note'
parrot daemon restart
```

This is the extensible path for Obsidian helpers, task managers, project-specific Markdown
routers, and other user-owned automations. Parrot invokes `/bin/zsh -lc` with the configured
command and writes the final UTF-8 text to standard input. Dictated text is never inserted into
the command string, arguments, or environment, so shell syntax in a transcript remains inert.
Standard output is discarded; on failure, at most 4 KiB of standard error is shown for diagnosis.

Commands run with your macOS user permissions and inherit your environment. They get 10 seconds;
after that Parrot terminates the command's entire process group. Parrot itself makes no network
request for delivery, though a script you explicitly configure can. Commands must finish in the
foreground; Parrot also cleans up background children when the shell returns. Command, journal,
and cursor delivery are mutually exclusive. After successful delivery, private history is written
normally. If the command fails, Parrot does not risk duplicate side effects by falling back to
cursor paste or adding a retry-duplicate history entry; it keeps the last recording available from
the menu bar for retry. Restore normal cursor delivery with
`parrot settings set --paste`. For a plain Markdown inbox, prefer the built-in `--journal` path:
it adds timestamps, locks and syncs each append, and does not execute a shell.

### Transcribe voice memos and recordings

Turn an existing audio or video file into a private local Markdown note with the same saved
model, mode, casing, vocabulary, and snippets used by live dictation:

```sh
parrot transcribe voice-memo.m4a
parrot transcribe interview.mp3 --notes
parrot transcribe lecture.mp4 --format json --output lecture.json
parrot transcribe *.m4a --output-directory ./transcripts
```

Without an output option, Parrot writes `voice-memo.md` beside `voice-memo.m4a`. Markdown is
the default and contains the processed note plus a timestamped recognition timeline. `text`
and `json` are also available; `--stdout` makes a single-file result pipe-friendly, and
`--no-timestamps` omits the timeline. Existing files are never replaced unless you pass
`--force`, which performs an atomic replacement.

Files are decoded through AVFoundation and transcribed entirely on-device. Long recordings
are streamed in bounded chunks, batches reuse one warmed model and run one file at a time,
and source media is never copied, changed, or added to dictation history. Created directories
and transcript files use private `0700`/`0600` permissions.

### Multilingual dictation

English stays on the compact `whisper-base.en` default. For local dictation and file
transcription in any Whisper-supported language, switch to the similarly sized multilingual
model and either pin a language for the lowest latency or detect it per recording:

```sh
parrot languages
parrot settings set --model whisper-base --language es   # Spanish, fixed and fastest
parrot settings set --model whisper-base --language auto # detect each recording
parrot daemon restart

parrot --model whisper-base --language French            # one run
parrot transcribe interview.m4a --model whisper-base --language auto
```

`whisper-base` is a 147 MB multilingual model; `whisper-small` is the optional 486 MB
higher-capacity alternative. Both recognize 100 language codes locally through WhisperKit.
Names such as `Spanish` and region identifiers such as `pt-BR` are canonicalized to Whisper
codes. Parrot rejects incompatible combinations instead of silently sending Spanish to an
English-only model. Automatic detection adds one language-classification decoder step; pinning
the known language skips it. The selected or detected language is included in file reports,
benchmark JSON, and private Markdown-history metadata.

Speech cleanup and spoken Markdown structure commands are currently English-specific. When
another language is detected, Parrot automatically skips English filler-word cleanup so it
cannot delete valid foreign-language words; normal recognition, casing, vocabulary replacement,
snippets, history, journal delivery, and cursor insertion continue locally.

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
sent to a server; the bounded recording recovery slot described above also stays local.

### Benchmark local models

New model downloads are stored locally at
`~/Library/Application Support/Parrot/models/`, outside Documents and iCloud Drive. Parrot
continues to use models downloaded by older releases from `~/Documents/huggingface/`, so an
upgrade never forces a large redownload. Inspect the exact locations and status with:

```sh
parrot models list
parrot languages
parrot models path
```

To move known legacy Parrot model folders into managed storage, first stop the daemon and run
`parrot models migrate`. Migration never overwrites an existing managed model and leaves
compatibility links at the old paths for other local tools. Tokenizer metadata may remain in
the shared legacy Hugging Face cache; the large Core ML model bundles are what Parrot moves.
Downloads show percentage progress in both interactive terminals and daemon logs.

Parrot includes two optional English-only Parakeet engines. Whisper Base remains the default:
it starts quickly, uses the least warm memory, and is the safest general choice. Pick a
Parakeet model when repeated inference speed matters more than model load cost:

| Model | Local download | Best fit |
|---|---:|---|
| `whisper-base.en` | 145 MB | Default; quickest load and lowest memory |
| `whisper-base` | 147 MB | 100 languages; fixed language or automatic detection |
| `parakeet-tdt-ctc-110m.en` | 331 MB | Small, very fast English engine |
| `parakeet-unified.en` | 614 MB | Fast English engine with punctuation and capitalization |
| `whisper-small` | 486 MB | Higher-capacity multilingual Whisper |

```sh
parrot models download parakeet-tdt-ctc-110m.en
parrot settings set --model parakeet-tdt-ctc-110m.en
parrot daemon restart
```

Both engines run through Core ML on the Mac and use the same private vocabulary replacement,
note formatting, history, live dictation, file transcription, and benchmark flows. Parakeet is
English-only and does not currently use Whisper's acoustic prompt hints. See the
[measured model comparison](docs/model-benchmarks.md) before changing the default.

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
the complete local note-formatting path. Add `--spoken-mode-trigger` to benchmark the live
leading mode-selection path; JSON records both the requested and effective mode.
Use `--json` to save comparable machine-readable reports. Download each candidate first with
`parrot models download <id>` so network time is not included in model-load time.
For reproducible tests or managed deployments, `PARROT_MODELS_DIRECTORY` overrides only the
managed model cache location; transcript, config, and legacy-model paths stay unchanged.

### Settings

Parrot stores settings only at `~/.config/parrot/config.json`, with user-only permissions.
The chosen microphone and lowercase choice are remembered during setup. Hotkey, model,
language, note/dictation mode, pause-aware paragraphs, cleanup, and delivery can be saved explicitly:

```sh
parrot settings
parrot settings set --hotkey right-option
parrot settings set --model whisper-small.en --mode notes
parrot settings set --no-auto-paragraphs # disable the note-mode default
parrot settings set --cleanup
parrot settings set --journal ~/Documents/Notes/inbox.md
parrot settings set --command '$HOME/bin/route-parrot-note'
parrot settings set --paste         # restore paste-at-cursor delivery
parrot settings reset               # resets transcription/formatting/delivery defaults
parrot daemon restart               # apply to a running LaunchAgent
```

Saved defaults are what a LaunchAgent uses, so launch-at-login no longer falls back to Fn or
plain dictation. Command-line flags remain one-run overrides: `--hotkey`, `--model`,
`--notes`, `--dictation`, `--auto-paragraphs`, `--no-auto-paragraphs`, `--cleanup`, and
`--no-cleanup` take priority without changing the file. `--journal`, `--command`, and `--paste`
similarly select one delivery destination without changing saved defaults. `--reconfigure`
resets the complete first-run configuration.

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
parrot languages                       # supported language names and codes
parrot models download <id>            # pre-download a model
parrot models path                     # show managed and legacy model locations
parrot models migrate                  # safely move known legacy model bundles
parrot models benchmark <id> --audio sample.wav
parrot transcribe voice-memo.m4a       # adjacent timestamped Markdown
parrot transcribe *.m4a --output-directory ./notes
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
parrot settings set --no-space-after-paste # exact cursor text; default adds one boundary space
parrot --journal ~/Documents/Notes/inbox.md # append there; don't type at cursor
parrot --command '$HOME/bin/route-parrot-note' # final text on stdin; don't paste
parrot --paste                         # override any saved destination for one run
parrot --no-space-after-paste          # exact cursor insertion for this run
parrot --notes                         # explicit spoken commands → local Markdown
parrot --notes --no-auto-paragraphs    # keep a long note continuous
parrot --dictation                     # override a saved notes mode for one run
parrot --cleanup                       # conservative local filler/false-start cleanup
parrot --no-cleanup                    # preserve disfluencies for this run
parrot --input-device brio             # pick a specific mic
parrot --no-pick-mic                   # skip the mic prompt
parrot --lowercase                     # lowercase all transcribed text
parrot --no-history                    # don't save local Markdown transcript history
parrot --reconfigure                   # redo first-time setup
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --model whisper-base --language auto # efficient multilingual auto-detection
parrot --hotkey right-option           # change the push-to-talk key
parrot --no-overlay                    # disable the bottom-of-screen pill
parrot run --debug-hotkey              # print keycodes for every key you press
```

## Stack

- **Swift** — single SPM executable target
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **FluidAudio** — optional Parakeet inference via CoreML
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

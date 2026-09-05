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

Very old builds may print `sudo: unable to read password: Input/output error` before they can
self-update. Bootstrap past that updater bug once with the current installer:

```sh
curl -fsSL https://raw.githubusercontent.com/encore-ai-labs/parrot/master/scripts/install.sh | sh
```

It uses the normal macOS administrator dialog when `/usr/local/bin` is not writable; subsequent
`parrot update` runs use the repaired flow.

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

When Fn/Globe is selected as either shortcut, Parrot temporarily changes macOS's bare Fn action to
**Do Nothing** while the daemon is running. That prevents the emoji picker, input-source
switcher, or Apple Dictation from racing Parrot. Your previous setting is restored on a
normal quit. Other hotkeys do not change this system preference.

For hands-free dictation, quickly double-tap the push-to-talk key. Recording stays on after
the second release; tap the selected push-to-talk key once more to stop and transcribe.
Ordinary keys, including Return, remain usable and do not stop the recording.
Press **Escape** at any point while recording to cancel and discard the audio without
transcribing, saving history, or injecting text. Escape is consumed as part of cancellation.

For an instant note-taking lane, configure an optional second key. It can also append directly to
a local Markdown inbox while the primary key keeps typing at the cursor:

```sh
parrot settings set --note-hotkey right-option \
  --note-journal ~/Documents/Notes/inbox.md
parrot daemon restart
```

The primary key keeps using the fallback or app-aware mode; the note key always starts that one
capture in local Markdown note mode. Both support hold and double-tap. A locked recording can be
stopped only by the same key that started it—the other configured key is ignored—and Escape still
cancels. Parrot routes both through one event tap and does not inspect the frontmost app when the
dedicated note key is used. Disable it with `parrot settings set --no-note-hotkey`.
The note inbox is an independent per-shortcut destination: it does not change the primary key's
saved paste, journal, or command route. Disable only that routing with
`parrot settings set --no-note-journal`. New inbox files and directories are private; existing
permissions are preserved. Appends use the same advisory lock and `fsync` durability as normal
journal delivery. Retrying a recording preserves the mode and destination that originally
captured it.

Cursor delivery adds one trailing boundary space by default, so consecutive captures become
`first thought. second thought.` instead of `first thought.second thought.` Existing trailing
whitespace is never doubled. This delivery-only space is not stored in history, journals, command
input, or file transcripts. Disable it for exact-input workflows with
`parrot settings set --no-space-after-paste`, or use `--no-space-after-paste` for one run.

If inference fails—or the daemon is interrupted during or after a recording—open the menu-bar bird
and choose **Retry Recovered Recording**. After a successful short dictation, **Retry Last
Recording** can immediately reprocess the in-memory audio with the currently selected mode,
without loading a second model. **Forget Last Recording** clears both the memory copy and any
recovery file.

Recovery is deliberately a single local slot, not an audio archive. While the mic is active,
Parrot streams a private 16-bit WAV to
`~/.local/share/parrot/recovery/last-recording.wav`. A new capture replaces the previous slot;
Escape deletes the partial file. If Parrot or macOS exits mid-note, the next launch repairs the WAV
header from the intact audio payload and offers the recording for retry. The first two minutes also
stay in memory for the fastest common path; after that Parrot drops the sample array and transcribes
incrementally from disk, keeping capture RAM bounded at about 7.7 MB regardless of note length.
Successful delivery deletes the recovery pathname. When finite audio history is explicitly
enabled, a private hard link keeps that delivered recording under transcript history instead.

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

### Personal filler phrases

Teach Parrot the verbal habits you personally want removed without asking a language model to
rewrite the rest of your thought:

```sh
parrot fillers add basically
parrot fillers add "you know"
parrot fillers add "to be honest"
parrot fillers
parrot fillers remove basically
```

Configured phrases are removed case-insensitively at whole-word boundaries in every live
dictation, even when general cleanup is off. They run before note commands and snippet expansion,
repair adjacent clause punctuation, and never alter a configured phrase inside a saved snippet
body. Say **“literal you know”** when you need to keep a phrase for one occurrence. File
transcription uses the same list; pass `--no-fillers` to preserve the source verbatim.

This list is deliberately explicit because conversational words can carry meaning. Parrot never
learns or guesses fillers from transcript history. Up to 128 phrases of six words each are stored
only in `~/.config/parrot/fillers.json` with user-only permissions (`0600`) and hot-reload on the
next recording. Matching is one precompiled local regex pass with no prompt tokens, model call,
account, telemetry, or network request.

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
bodies never enter model context and nothing is sent over the network. Changes become active on
the next recording, even when the daemon is already running.

### Optional local recognition context

If names, dates, or project terms are already visible where you are writing, Parrot can use a
small amount of that text as a local Whisper recognition hint:

```sh
parrot settings set --context selected-text # focused app's current selection
parrot settings set --context clipboard     # current plain-text clipboard value
parrot settings set --context both          # clipboard first, selection prioritized last
parrot settings set --context off           # default: read neither source
parrot daemon restart
```

This is explicit opt-in and Whisper-only. At hotkey-down, Parrot snapshots at most 2,048
characters, normalizes whitespace, and reserves at most 32 of its existing 96 decoder prompt
tokens for the newest context. The Accessibility read runs with a 50ms cross-process timeout
away from microphone startup; a missing selection, denied read, or slow app simply means no hint.
Parakeet skips context without reading either source because that engine has no prompt API.

Context stays in memory for that capture and its retry. It is never printed, written to transcript
history or journals, included in delivered text, sent over a network, or used for screen OCR. Use
`parrot --context selected-text` for a one-run override without changing the saved setting.

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
parrot history show latest --original  # recognition before cleanup/replacements
parrot history last --original         # original recognition, clean for pipes
parrot history copy latest --original  # recover original recognition to clipboard
parrot history export --period today   # clean chronological Markdown to stdout
parrot history export --period week --output ~/Documents/parrot-week.md
parrot history export --since 2026-09-01 --until 2026-09-05 --query "project roadmap"
parrot history export --format jsonl --output history.jsonl
parrot history path                    # print the Markdown directory
parrot history prune --keep-days 30    # preview a rolling cleanup
```

Search scans only the local Markdown files and matches both the delivered text and the original
recognition. When local processing changes a transcript (for example vocabulary replacement,
cleanup, note formatting, spoken editing, or snippet expansion), Parrot keeps that original in a
versioned, Base64-encoded hidden Markdown comment. It is not encrypted: anyone who can read the
private file can decode it. Unchanged entries add no duplicate, and old entries without an original
fall back to their delivered text for `--original`.

Other invisible comments provide reliable boundaries and IDs even when a note contains its own
headings; history written by older Parrot versions remains readable. Original recognition follows
the same retention policy as its entry and is never written with `--no-history`. For a private
session that should leave no transcript history, run:

```sh
parrot --no-history
```

`history export` turns all history, a day, week, month, custom inclusive date range, or local
search result into one chronological note. Markdown is the readable default; JSON Lines includes
stable IDs, ISO-8601 timestamps, final/original text, language, model, mode, audio duration,
processing duration, and real-time factor for local tools. Add `--original` to make recoverable
pre-processing recognition the primary text. Search matches both versions with the same
case/diacritic-insensitive all-words behavior as `history search`.

Without `--output`, export writes only document bytes to stdout, so pipes stay clean. File output
is an atomic private `0600` write, creates missing parent directories as `0700`, and refuses to
replace an existing file unless `--force` is explicit. Export holds the existing shared history
lock while reading, never edits source history or retained audio, and adds no recording or
inference work.

History is kept forever by default. To opt into automatic retention, save a rolling window and
restart the daemon:

```sh
parrot settings set --history-retention-days 30
parrot daemon restart
```

Parrot then removes entries older than exactly 30 × 24 hours at daemon startup and checks at most
hourly after a completed dictation. Cleanup is local and runs after delivery, so it adds no model,
network, or inference latency. You can inspect the exact daily files and entry counts first, then
apply a one-off cleanup explicitly:

```sh
parrot history prune --keep-days 30
parrot history prune --keep-days 30 --confirm
parrot settings set --keep-history-forever
```

Only regular, non-symlink `YYYY-MM-DD.md` files in Parrot's private history directory are eligible;
unrelated files and Markdown journals are untouched. On the cutoff day, entries from older Parrot
versions without stable boundary markers are conservatively preserved. Deletion removes Parrot's
files at the application level, but cannot promise forensic erasure from filesystem snapshots or
storage backups.

#### Optional recording history

By default Parrot keeps no delivered audio—only the latest bounded retry samples in memory. If you
want to replay or reprocess older notes, opt into a finite private audio window and restart the
daemon:

```sh
parrot settings set --audio-history-days 7
parrot daemon restart

parrot history audio                         # retained recordings plus note excerpts
parrot history audio play latest             # open locally in the default audio player
parrot history audio reprocess latest        # current saved model and mode, text to stdout
parrot history audio reprocess ID --notes --model whisper-small.en
parrot history audio delete ID                  # preview; add --confirm to delete audio only
parrot history audio path
```

Audio stays as 16 kHz mono PCM WAV under `~/.local/share/parrot/transcripts/audio/`, with the same
stable ID as its Markdown entry and user-only directory/file permissions (`0700`/`0600`). At about
1.9 MB per minute, the configured rolling limit keeps storage predictable; a shorter transcript
retention automatically shortens audio retention too. Cleanup runs at startup and at most hourly,
removing expired audio and recordings whose transcript was pruned. `parrot history prune
--confirm` also removes paired audio immediately.

Archiving hard-links Parrot's already-synchronized crash-recovery WAV, so it does not re-encode,
copy, or allocate a second recording on the delivery path. Playback and reprocessing are entirely
local; reprocessing uses the same saved vocabulary, fillers, snippets, formatting, and on-device
model as file transcription. Only successfully delivered entries with successfully written
Markdown history are archived. Cancelled, rejected, failed, `--no-history`, and command-delivery
failure captures are not.

Turn off future recording history without deleting existing files, or preview and explicitly clear
only the retained WAVs while keeping transcript text:

```sh
parrot settings set --no-audio-history
parrot history audio clear                      # preview
parrot history audio clear --confirm
```

The archive accepts only Parrot-shaped regular WAV filenames, never follows symlinks, and caps one
recording at 256 MiB. As with transcript deletion, clearing is application-level deletion rather
than guaranteed forensic erasure from snapshots or backups.

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
model, mode, casing, vocabulary, fillers, and snippets used by live dictation:

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
history remains compatible and is included in every count. New dictations also record the local
model and effective workflow mode in that hidden marker, so the same command compares real-world
real-time factor per model and shows how often dictation versus notes mode is used. This is private
on-device measurement—not telemetry—and makes it practical to choose the fastest model on your
own Mac instead of relying on somebody else's benchmark.

```sh
parrot stats                         # all-time local summary
parrot stats --period today          # today, week, month, or all
parrot stats --typing-wpm 55         # tune the comparison to your typing speed
parrot stats --period week --json    # script-friendly output
```

That's it. There is no record button, no stop button, no "send" — the key is the whole interface.

> **By default, the mic is held open the whole time parrot runs**, so macOS shows the mic-in-use
> indicator continuously. That's what lets a capture start ~300 ms *before* you press the key —
> no clipped first words. The warm session only maintains the pre-roll while idle: RMS metering
> and waveform UI work begin with an actual recording. Save `parrot settings set --cold-mic`
> to open the mic only while the key is held, at the cost of losing the front of each utterance.
> Use `--cold-mic` for one run or `--warm-mic` to override a saved cold policy.

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
parrot --no-pick-mic          # use saved priority/remembered mic, no prompt
```

There's no prompt when there's no terminal (under `launchd`, say) — it falls through to your
highest available saved device, or the recommended one.

For a dock/headset setup, save an explicit highest-first order once:

```sh
parrot devices prioritize "Logitech BRIO" "MacBook Pro Microphone"
parrot devices                         # shows ranks and disconnected saved devices
parrot daemon restart                  # apply it to a running background daemon
parrot devices automatic               # return to safe automatic selection
```

Parrot uses the first connected ranked microphone. If it disappears, capture recovers onto the
next ranked device, then onto a safe non-Bluetooth, non-virtual fallback. When a better-ranked mic
returns, Parrot promotes it automatically. A reconnect during an active dictation waits until that
dictation ends, so one note never mixes microphones or gets discarded merely because a dock was
plugged in. Explicit priorities may include Bluetooth; automatic fallback still avoids it.

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
(`0600`). Additions, corrections, removals, and snippet changes hot-reload on the next hotkey
press—no daemon or model restart. Parrot checks only private file metadata on an unchanged capture;
when a file changes, it rebuilds the bounded Whisper prompt and deterministic matchers while you
speak. A malformed manual edit keeps the last known-good personalization instead of breaking
dictation. No vocabulary, transcript, or audio is sent to a server; the bounded recording recovery
slot described above also stays local.

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
accurate). The benchmark uses your saved vocabulary, fillers, and snippets by default; pass
`--no-vocabulary`, `--no-fillers`, and `--no-snippets` for a clean model comparison, or
`--notes` to benchmark the complete local note-formatting path. Add `--spoken-mode-trigger` to
benchmark the live leading mode-selection path; JSON records both the requested and effective mode.
Use `--json` to save comparable machine-readable reports. Download each candidate first with
`parrot models download <id>` so network time is not included in model-load time.
For reproducible tests or managed deployments, `PARROT_MODELS_DIRECTORY` overrides only the
managed model cache location; transcript, config, and legacy-model paths stay unchanged.

### Settings

Parrot stores settings only at `~/.config/parrot/config.json`, with user-only permissions.
The chosen microphone and lowercase choice are remembered during setup. Hotkey, model,
language, note/dictation mode, pause-aware paragraphs, cleanup, capture policy, and delivery
can be saved explicitly:

```sh
parrot settings
parrot settings set --hotkey right-option
parrot settings set --note-hotkey right-command # optional direct note-mode shortcut
parrot settings set --note-journal ~/Documents/Notes/inbox.md # only the note key appends here
parrot settings set --context selected-text # opt-in bounded local Whisper hint
parrot settings set --model whisper-small.en --mode notes
parrot settings set --no-auto-paragraphs # disable the note-mode default
parrot settings set --cleanup
parrot settings set --cold-mic     # no idle mic; capture starts may clip
parrot settings set --warm-mic     # default: fast 300ms pre-roll
parrot settings set --journal ~/Documents/Notes/inbox.md
parrot settings set --command '$HOME/bin/route-parrot-note'
parrot settings set --paste         # restore paste-at-cursor delivery
parrot settings reset               # resets transcription/formatting/capture/delivery defaults
parrot daemon restart               # apply to a running LaunchAgent
```

Saved defaults are what a LaunchAgent uses, so launch-at-login no longer falls back to Fn or
plain dictation. Command-line flags remain one-run overrides: `--hotkey`, `--note-hotkey`,
`--no-note-hotkey`, `--note-journal`, `--no-note-journal`, `--context`, `--model`,
`--notes`, `--dictation`, `--auto-paragraphs`, `--no-auto-paragraphs`, `--cleanup`,
`--no-cleanup`, `--warm-mic`, and `--cold-mic` take priority without changing the file.
`--journal`, `--command`, and `--paste` similarly select one delivery destination without
changing saved defaults. `--reconfigure` resets the complete first-run configuration.

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
restart is needed. App-mode matching reads only the frontmost app's bundle identifier at hotkey
time; it never inspects window titles or screen pixels. Selected text or clipboard content is read
only when the separate recognition-context setting is explicitly enabled, and neither app identity
nor context is saved to transcript history or sent anywhere.

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
parrot --hotkey fn --note-hotkey right-option # one-run direct note shortcut
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
parrot devices prioritize "USB mic" "MacBook Pro Microphone" # ranked fallback
parrot devices automatic               # clear saved microphone priorities
parrot apps add Notes --mode notes     # local automatic mode rule
parrot apps list                       # show saved app-mode rules
parrot vocabulary                      # list personal recognition hints/replacements
parrot vocabulary add "rust pond" --as RustPond
parrot fillers                         # list personal phrases removed locally
parrot fillers add "you know"          # hot-reloads on the next recording
parrot snippets                        # list reusable local voice snippets
parrot snippets add meeting --file template.md
parrot history                         # list recent local transcripts
parrot history search project roadmap # search private Markdown history
parrot history copy                    # recover the latest transcript to clipboard
parrot history last --original         # recover recognition before local processing
parrot history export --period week --output weekly-notes.md
parrot history export --query "project roadmap" --format jsonl
parrot history audio                   # list opt-in retained local recordings
parrot history audio reprocess latest  # rerun one through the current local model/mode
parrot history prune --keep-days 30    # preview; add --confirm to remove old entries
parrot stats                            # private usage/timing insights from history
parrot settings                         # show effective saved daemon defaults
parrot settings set --hotkey end --mode notes
parrot settings set --note-hotkey right-option # direct local note-mode capture
parrot settings set --note-journal ~/Documents/Notes/inbox.md # note-key-only inbox
parrot settings set --context selected-text # opt-in local recognition hint
parrot settings set --no-note-journal           # note key returns to primary delivery
parrot settings set --no-note-hotkey           # return to one shortcut
parrot settings set --history-retention-days 30 # automatic rolling local cleanup
parrot settings set --audio-history-days 7      # opt-in replay/reprocess window
parrot settings set --no-audio-history          # stop retaining new audio
parrot settings set --keep-history-forever      # default: never auto-delete history
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
parrot --cold-mic                      # no idle mic; capture starts may clip
parrot --warm-mic                      # override a saved cold policy for this run
parrot --lowercase                     # lowercase all transcribed text
parrot --no-history                    # don't save local Markdown transcript history
parrot --reconfigure                   # redo first-time setup
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --model whisper-base --language auto # efficient multilingual auto-detection
parrot --hotkey right-option           # change the push-to-talk key
parrot --note-hotkey right-command     # second key always uses note mode
parrot --note-hotkey right-command --note-journal ~/notes/inbox.md
parrot --context both                  # one-run selected-text + clipboard hint
parrot --no-note-journal               # ignore a saved note inbox for this run
parrot --no-note-hotkey                # ignore a saved note key for this run
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

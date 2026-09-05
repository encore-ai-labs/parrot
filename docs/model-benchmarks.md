# Local model benchmark

Measured on 2026-09-05 with an Apple M3 Max MacBook Pro (36 GB) running macOS 15.7.
All inference ran locally through Parrot's release build. The 14.13-second English sample was
generated once with the macOS `say` voice and reused byte-for-byte for every model. Note mode,
three timed runs, and a normalized reference transcript were enabled; vocabulary and snippets
were disabled.

Spoken sample: “Project Alpha. Heading two, release checklist. Bullet point, verify the local
model. Next bullet, measure transcription speed. New task, document memory usage. New paragraph,
everything stays on this Mac.” The WER reference omitted punctuation and the spoken formatting
commands that note mode intentionally consumes.

| Model | Download | Load | Median inference | Realtime | WER | Maximum RSS |
|---|---:|---:|---:|---:|---:|---:|
| Whisper Base English | 145 MB | 0.57 s | 0.453 s | 31x | 0.0% | 165 MB |
| Parakeet 110M | 331 MB | 5.92 s | 0.073 s | 194x | 5.3% | 313 MB |
| Parakeet Unified INT8 | 614 MB | 16.82 s | 0.109 s | 130x | 0.0% | 692 MB |

On this one controlled sample, Parakeet 110M inference was 6.2 times faster than Whisper Base
and Unified was 4.2 times faster. The compact model made one substitution (`Mac` → `map`);
the other two matched the normalized reference. These measurements are a regression-friendly
sanity check, not a broad accuracy ranking: accents, acoustics, vocabulary, and hardware will
change the result.

Whisper Base therefore remains Parrot's default. It loaded roughly 10 times faster than the
compact model and 30 times faster than Unified, and had the lowest maximum resident memory.
The optional Parakeet choices are useful for long sessions or repeated file transcription,
where their one-time model load can be amortized.

## Multilingual Base validation

The multilingual path was separately measured on the same Mac with the local debug CLI and two
new single-speaker macOS `say` clips. Each row is the median of five warmed inference runs with
vocabulary and snippets disabled.

| Audio | Model / language | Duration | Median | Realtime | WER | Detected |
|---|---|---:|---:|---:|---:|---|
| Spanish | Multilingual Base / `es` | 6.59 s | 0.269 s | 24.5x | 0.0% | `es` |
| Spanish | Multilingual Base / `auto` | 6.59 s | 0.343 s | 19.2x | 0.0% | `es` |
| English | English Base / `en` | 5.38 s | 0.220 s | 24.4x | 4.8% | `en` |
| English | Multilingual Base / `en` | 5.38 s | 0.299 s | 18.0x | 4.8% | `en` |

Automatic Spanish detection cost 74 ms over the fixed-language median while preserving 0% WER.
Multilingual Base was 36% slower than English Base on the English clip with equal WER, supporting
the product decision to leave `.en` as the default and make multilingual recognition explicit.
The English WER is one normalized substitution (`nine` → `9`), not a missing spoken word.

## Pause-aware paragraph cost

The note path was measured on a 7.05-second two-thought `say` clip with 1.6 seconds of inserted
digital silence. Both configurations used English Base, five warmed debug-CLI runs, the same
note prompt, and no vocabulary or snippets.

| Note formatting | Median | Realtime | WER | Output |
|---|---:|---:|---:|---|
| Automatic paragraphs off | 0.361 s | 19.5x | 0.0% | One paragraph |
| Automatic paragraphs on | 0.367 s | 19.2x | 0.0% | Two paragraphs |

Adaptive pause detection added 5.8 ms (1.6%) to the median while preserving every normalized
word. The formatter-only performance test processes a 200-segment note 100 times in roughly
25 ms total on this Mac, or about 0.25 ms per long note. Plain dictation bypasses both passes.

## Spoken one-capture mode cost

A 3.63-second `say` clip beginning “note mode, bullet point...” was measured for 20 warmed
English Base runs on the same optimized binary. The decoder stayed in plain dictation mode in
both cases; only the deterministic post-transcription trigger path changed.

| Trigger processing | Median | Realtime | WER against intended output | Output |
|---|---:|---:|---:|---|
| Off | 0.129 s | 28.2x | 0.0% | Spoken control words retained |
| On | 0.125 s | 29.0x | 0.0% | Markdown bullet/task; trigger removed |

The 3.8 ms difference favored the trigger run and is ordinary inference variance, so this sample
shows no measurable trigger overhead. The static matcher adds no decoder prompt or second model
pass; its focused long-input test exits in well under a millisecond.

## Personalization hot-reload cost

The daemon's unchanged-file path was measured in the debug test harness with 1,000 vocabulary
entries, 1,000 snippets, and the maximum 128 personal fillers. One thousand complete checks
averaged 130 ms, or about **0.130 ms per recording**. Library size does not affect that steady-state
path because Parrot reads only three file signatures. JSON decoding, matcher compilation, and
bounded Whisper prompt tokenization happen only after an atomic file change; prompt rebuilding
starts at hotkey-down so normal speech time hides it.
The loaded Core ML model is never replaced or warmed again.

## Personal filler cleanup cost

With three configured phrases, 1,000 complete cleanup passes over a typical project-note sentence
averaged 13 ms in the debug test harness, or about **0.013 ms per dictation**. A worst-case test with
all 128 allowed phrases removed matches throughout a 40-sentence note 100 times in 219 ms, or about
**2.19 ms per long note**. The matcher is compiled only when `fillers.json` changes and contributes
no acoustic prompt, model inference, or network work.

## Retained-audio delivery cost

Opt-in recording history reuses the private WAV that Parrot already synchronizes for crash
recovery. A focused test repeatedly archived and removed a one-minute recording 100 times; ten runs
averaged 45 ms, or about **0.45 ms per archive-plus-delete cycle**. The archive itself is a hard link
to the same inode, so it performs no second PCM conversion, byte copy, or length-dependent
allocation. Age/orphan scans run at startup and at most hourly after successful delivery, outside
capture and inference.

## Dedicated note-hotkey routing cost

Primary and note shortcuts share one `CGEventTap` and one gesture controller; they do not load or
warm a second transcription pipeline. In the debug test harness, 10,000 irrelevant key-routing
checks with two configured modifier hotkeys averaged 3–5 ms, or **0.3–0.5 microseconds per event**.
Modifier-only pairs never subscribe to ordinary keyDown/keyUp events. If a plain key is configured,
unrelated keystrokes are rejected synchronously before Parrot copies or dispatches them.

## Reproduce it

Use representative audio and an exact reference on your own Mac:

```sh
parrot models download parakeet-tdt-ctc-110m.en
parrot models download parakeet-unified.en

parrot models benchmark whisper-base.en \
  --audio sample.aiff --reference "Exact spoken words" \
  --runs 3 --notes --no-vocabulary --no-fillers --no-snippets

parrot models benchmark parakeet-tdt-ctc-110m.en \
  --audio sample.aiff --reference "Exact spoken words" \
  --runs 3 --notes --no-vocabulary --no-fillers --no-snippets

parrot models benchmark parakeet-unified.en \
  --audio sample.aiff --reference "Exact spoken words" \
  --runs 3 --notes --no-vocabulary --no-fillers --no-snippets
```

Use `--json` for machine-readable results. Model download time is deliberately excluded from
load time; download each candidate before benchmarking it.

To measure the one-capture spoken mode switch, begin the audio with `note mode` or `dictation
mode` and add `--spoken-mode-trigger`. The JSON report records `noteMode` as the decoder mode and
`effectiveMode` as the post-trigger processing mode, making prompt and processing differences
explicit.

For multilingual models, benchmark both a fixed language and automatic detection. Fixed
language is the latency baseline because it skips detection; `auto` measures the real cost for
a workflow that mixes languages:

```sh
parrot models benchmark whisper-base --audio spanish.wav --language es \
  --reference "El texto exacto que dijiste" --runs 3
parrot models benchmark whisper-base --audio spanish.wav --language auto \
  --reference "El texto exacto que dijiste" --runs 3
```

JSON output records `requestedLanguage` separately from the language recognized by the model.

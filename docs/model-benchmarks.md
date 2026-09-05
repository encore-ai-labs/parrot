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

## Reproduce it

Use representative audio and an exact reference on your own Mac:

```sh
parrot models download parakeet-tdt-ctc-110m.en
parrot models download parakeet-unified.en

parrot models benchmark whisper-base.en \
  --audio sample.aiff --reference "Exact spoken words" \
  --runs 3 --notes --no-vocabulary --no-snippets

parrot models benchmark parakeet-tdt-ctc-110m.en \
  --audio sample.aiff --reference "Exact spoken words" \
  --runs 3 --notes --no-vocabulary --no-snippets

parrot models benchmark parakeet-unified.en \
  --audio sample.aiff --reference "Exact spoken words" \
  --runs 3 --notes --no-vocabulary --no-snippets
```

Use `--json` for machine-readable results. Model download time is deliberately excluded from
load time; download each candidate before benchmarking it.

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

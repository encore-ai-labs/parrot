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

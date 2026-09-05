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

## Live long-note capture cost

The active microphone path converts each incoming Float32 buffer once into the private PCM16
recovery spool. Ten one-minute runs in 1,024-sample chunks averaged **59 ms per recorded minute**
on this Mac, spread across the minute rather than paid after hotkey release. PCM16 grows by
**1.92 MB per minute**. The normal in-memory capture path is capped at 1,920,000 samples—about
**7.7 MB / two minutes**—then released while the file continues. Warm idle buffers never touch the
spool. WhisperKit decodes with one incremental 120-second chunk buffered; compact Parakeet uses its
disk-backed converter. Unified Parakeet still materializes resampled file input before running its
bounded 15-second model windows, so the default Whisper engine remains the strictest memory choice
for very long live notes.

## Dedicated note-hotkey routing cost

Primary and note shortcuts share one `CGEventTap` and one gesture controller; they do not load or
warm a second transcription pipeline. In the debug test harness, 10,000 irrelevant key-routing
checks with two configured modifier hotkeys averaged 3–5 ms, or **0.3–0.5 microseconds per event**.
Modifier-only pairs never subscribe to ordinary keyDown/keyUp events. If a plain key is configured,
unrelated keystrokes are rejected synchronously before Parrot copies or dispatches them.

The optional note-inbox destination adds one source/availability comparison at hotkey-down. In the
debug performance harness, 100,000 route selections averaged 11 ms, or about **0.11 microseconds
per capture**. Delivery then reuses the existing `MarkdownJournal` append path. It does not alter
audio capture, prompt size, inference, or steady-state event routing.

## Optional recognition-context cost

Recognition context is off by default, so established capture and inference paths add no clipboard
or Accessibility read and reuse their precomputed decoder options. When enabled, source preparation
is bounded to 2,048 characters and at most 32 context tokens inside the existing 96-token prompt.
In the debug performance harness, 100 preparations from two 28,000-character inputs averaged
47 ms total on this Mac, or about **0.47 ms per capture**. Selected-text IPC has a separate 50ms
timeout and runs concurrently with recording rather than delaying microphone startup.

## Original-recognition history cost

History stores a second text payload only when deterministic local processing changes the result.
The payload is UTF-8 Base64 inside the existing Markdown entry, so it adds no model pass, audio
copy, database, or network request. In the debug performance harness, 100 encode-and-decode
round trips of a roughly 24 KB recognition averaged 142 ms total on this Mac, or about **1.42 ms
per unusually long changed entry**. Normal dictations are much shorter, unchanged entries store
nothing extra, and history work remains after successful delivery.

## Ranked microphone routing cost

Microphone selection is event-driven: no priority work runs in the sample-buffer callback. With
the maximum eight saved UIDs, 100,000 higher-rank connection decisions averaged 70 ms in the
debug performance harness on this Mac, or about **0.70 microseconds per device connection event**.
Startup and actual recovery additionally enumerate current CoreAudio devices, work that already
existed and remains outside capture and inference.

Live menu selection remains event-driven and updates the same bounded priority list. In the debug
performance harness, 10,000 selected-device reorderings at the maximum eight saved UIDs averaged
**43 ms**, or about **4.3 microseconds per user selection**. Actual AVCaptureSession input
replacement is a one-time asynchronous hardware operation on the existing serial session queue;
it does not block the menu, run during capture, add idle polling, or touch transcription/model work.

## Local microphone-test cost

`parrot devices test` is an explicit diagnostic, so it adds no daemon-idle or ordinary-dictation
work. The capture is bounded to 2–15 seconds at 16 kHz mono Float32 (at most about 960 KB), keeps no
recovery file, and discards its normal 300 ms warm pre-roll before analysis. The analyzer makes one
pass for RMS, peak, 20 ms active-frame share, and clipped-sample share; it does no model or network
work. In the debug test harness, ten analyses of the same ten-second signal completed in **137 ms**
on this Mac, about **13.7 ms per diagnostic**. AVCaptureSession startup and the requested listening
period are intentionally excluded because they depend on physical hardware and chosen duration.

## Local note-template cost

Templates do not affect audio capture or add inference. With no selected template, the finalized
text returns directly after one branch. With a template selected, rendering performs fixed string
replacement after the existing note pipeline. In the debug performance harness, 100 renderings of
the same roughly 108 KB note completed in about **100 ms** on this Mac, approximately **1.0 ms per
unusually long note**. Template bodies never enter the decoder prompt; at most four short spoken
selector names share the existing bounded prompt-term path.

The running daemon checks four private-library file signatures at recording start. The existing
hot-reload test performed 1,000 unchanged checks in about **137 ms** total on this Mac, or roughly
**0.14 ms per capture** across vocabulary, snippets, fillers, and templates. Decoding and matcher
rebuilding occur only after an atomic file replacement is observed.

## Local history export cost

History export is an explicit CLI operation and adds no capture, delivery, model, or daemon-idle
work. In the debug performance harness, filtering 5,000 in-memory notes for two search words and
rendering the 295 matches as metadata-bearing JSON Lines averaged **49 ms** on this Mac. The reader
reads only daily Markdown files that can overlap a requested date period under one shared lock;
rendering keeps no audio and makes no network or model request.

## Real-world model evidence

Synthetic samples are useful, but the most relevant speed evidence comes from the user's own
microphone, note lengths, and Mac. Every newly delivered dictation therefore records its registry
model ID, effective dictation/notes mode, audio duration, and processing duration inside the
private Markdown entry. `parrot stats` groups those local measurements and reports aggregate
real-time factor per model. Incomplete timings remain visible in dictation counts but are excluded
from the speed denominator, so older or partial entries cannot make a model look artificially fast.

This aggregation is an explicit CLI operation and adds no work to capture or inference beyond the
small metadata fields already written with history. It reads no retained audio and makes no network
request. The test harness groups and summarizes 5,000 mixed-model records to keep that analysis
cost bounded as history grows; it averaged **100 ms** in the debug performance harness on this Mac.

## Cursor-delivery preparation cost

The privacy-first cursor path now forms small keyboard events on Unicode-scalar boundaries so raw
UTF-16 chunking cannot split surrogate pairs. In the debug performance harness, preparing a roughly
9,800-character Unicode note 100 times averaged **224 ms**, or about **2.24 ms per unusually long
note**. Normal notes are much shorter, and this work happens after inference only when cursor
delivery is selected.

The optional clipboard compatibility path sends Command-V immediately; its configurable restore
delay is asynchronous and is not added to transcription or insertion latency. It snapshots local
pasteboard data only after a finished cursor-bound transcript and performs no model or network work.

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

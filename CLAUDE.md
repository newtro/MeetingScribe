# MeetingScribe

Native macOS app (Swift 6.3, macOS 26, arm64) that captures a live meeting, transcribes it
on-device, and asks the `claude` CLI for real-time ASK / FLAG / ANSWER suggestions against a
context brief. Used in live client meetings.

## Two locations — do not merge them

| What | Where |
| --- | --- |
| **Source + build** (this repo) | `/Volumes/Cache/repos/MeetingScribe` |
| **Runtime data** | `~/Documents/MeetingScribe` — `context.md`, `contexts/*.md`, `sessions/` |

The data path is hardcoded in `src/Store.swift` (`Paths.root`). Another Claude session reads
`sessions/` live, so the paths and file formats there are a contract — do not change them.
Keeping data off the external drive also means meetings still work if the Cache drive is
unmounted.

## Build, sign, install

```bash
./build.sh            # compile + sign into build/MeetingScribe.app
./build.sh --install  # also installs to /Applications and registers with LaunchServices/Spotlight
```

SwiftPM (`Package.swift`, sources in `src/`), Swift 5 language mode on purpose — avoids strict-concurrency
churn. FluidAudio is pinned `exact: "0.17.1"` with `traits: []` (drops its prebuilt text-normalization engine).
`build.sh` fetches the diarization model once into `build/models/Nemotron3` (pinned HF revision, ~200 MB) and
copies it into `Contents/Resources/Nemotron3`, so meetings never download anything. If SwiftPM hangs fetching
FluidAudio's `NemoTextProcessing` binary artifact (it still resolves it with the trait off), curl the zip from
the URL in FluidAudio's `Package.swift` into `~/Library/Caches/org.swift.swiftpm/artifacts/` under SwiftPM's
underscored-URL file name.
Signed with the stable **"ImageSmith Dev"** identity so the Screen Recording (TCC) grant survives
rebuilds. **Do not switch back to ad-hoc (`SIGN_ID=-`)**: ad-hoc ties the grant to the binary
hash, every rebuild silently revokes it, and capture fails with SCStreamError -3801.

## Architecture

- `Capture.swift` — one `SCStream`, `capturesAudio` + `captureMicrophone`.
  `.audio` = **REMOTE** (everything the Mac plays, i.e. the call), `.microphone` = **LOCAL**.
  Channel separation is by *source*, not by speaker.
- `Transcriber.swift` — one `SpeechAnalyzer` + `SpeechTranscriber` per channel, on-device.
  Converts CMSampleBuffer → analyzer format; pads silence on PTS gaps so `result.range` maps to
  wall-clock time. Volatile results → live pane only; finals → files.
- `Diarizer.swift` — NVIDIA Nemotron 3 Diarization via FluidAudio (Core ML, `Nemotron3Config.fast32` = 2.88 s
  streaming, ≤8 speakers per channel). One `ChannelDiarizer` per channel, fed the exact buffers (incl. silence
  padding) the analyzer gets via `ChannelTranscriber.onAudio`, so 10 ms frame *i* = analyzer time *i*·10 ms.
  One shared model and one serial queue for both channels. Each final waits ≤4 s for the diarizer to cover its
  `result.range`, gets the probability-weighted majority speaker (`R1…R8` / `L1…L8`, arrival order, per
  session), and requests resolve in order. Model missing/failing → one error, lines written unlabeled.
- `Recorder.swift` — wires capture → transcribers (+ diarizers) → `SessionStore`, plus `EchoFilter`: holds
  LOCAL finals ~8s and drops any that closely match a REMOTE final within ±20s (speaker bleed
  when not on headphones).
- `Store.swift` — writes `sessions/<ISO8601 start>/transcript.jsonl`
  (`{"t","ch":"remote"|"local","text","spk"?}` — `spk` only when known) and `transcript.txt`
  (`[HH:MM:SS] REMOTE: …`, deliberately without speakers),
  fsync'd per write. Also `Paths.briefs()`: `context.md` + `contexts/*.md`, newest first.
- `Advisor.swift` — every 45s and on "Ask now": `claude -p --output-format text --tools ""
  --strict-mcp-config --no-session-persistence`, prompt = selected brief verbatim + last 4 min of
  transcript. 30s timeout. Parses ASK/FLAG/ANSWER items, dedupes against the last 3 responses
  (content-word overlap ≥ 0.35 with a boilerplate stoplist), appends to `suggestions.md`.
  The brief owns the instructions; the app adds none.
- `App.swift` — SwiftUI. Control bar (Start/Stop, RECORDING badge, elapsed, brief picker,
  Ask now, text size), transcript pane, suggestions pane (FLAG most prominent).
- `Main.swift` — dev modes:
  - `--selftest N` live capture for N seconds (run via `open -W /Applications/MeetingScribe.app --args --selftest 60`
    so TCC attributes it to the bundle); logs to `~/Documents/MeetingScribe/selftest.log`
  - `--filetest remote.wav local.wav` feeds audio files through the real transcription path
  - `--advisortest transcript.jsonl [--brief path]` runs two advisor cycles
  - `--render out.png [--dark] [--idle]` renders the UI offscreen with sample data

## Known limits

- **Speaker labels are anonymous and per channel.** `R2` is "second remote voice heard this
  session", not a person, and R/L slots are independent (the same person is never linked across
  channels or sessions). >8 speakers on a channel degrades silently. Without headphones the LOCAL
  diarizer also hears the call, which can use up L slots even though EchoFilter drops the text.
- One speaker per final: a final spanning a speaker change gets the majority speaker.
- The advisor prompt labels LOCAL as "Scott's microphone", which is wrong for in-room meetings.
- Transcript lines are appended in finalization order, so `t` can be a few seconds out of order.

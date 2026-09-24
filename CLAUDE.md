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

`swiftc -swift-version 5` (Swift 5 language mode on purpose — avoids strict-concurrency churn).
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
- `Recorder.swift` — wires capture → transcribers → `SessionStore`, plus `EchoFilter`: holds
  LOCAL finals ~8s and drops any that closely match a REMOTE final within ±20s (speaker bleed
  when not on headphones).
- `Store.swift` — writes `sessions/<ISO8601 start>/transcript.jsonl`
  (`{"t","ch":"remote"|"local","text"}`) and `transcript.txt` (`[HH:MM:SS] REMOTE: …`),
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

- **No speaker attribution.** LOCAL vs REMOTE is the only split. Every remote participant is
  one undifferentiated REMOTE stream; in an in-person meeting everyone is LOCAL. The advisor
  prompt labels LOCAL as "Scott's microphone", which is wrong for in-room meetings.
- Transcript lines are appended in finalization order, so `t` can be a few seconds out of order.

## Current investigation

Adding **speaker diarization** — evaluating NVIDIA's Nemotron diarization model — so REMOTE
(and in-room LOCAL) can be split into individual speakers. Constraints any approach must meet:

- **Stays on-device.** No audio leaves the machine; only transcript text goes to the CLI.
- **Must not block or slow the capture pipeline.** Diarization should consume the same audio
  the transcribers get, off the capture queue.
- **Must keep the file contract.** Adding a speaker field is fine only if it is additive
  (e.g. a new `"spk"` key in `transcript.jsonl`); `ch` and `text` must keep their meaning.
- Speaker labels must line up with `SpeechTranscriber` result time ranges (`result.range`,
  already requested via `.audioTimeRange`).

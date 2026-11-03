# Project-ready pilot verification — 2026-11-02

## Delivered behavior

Generic saved projects trigger bounded folder/Git preparation when created or reopened. Local notes and AI history become immutable cited packets. Live speech is independent from the continuous attention detector and queued research. The native prompter has stable topics, evidence/proposal labels, background results, wheel takeover, bottom/Jump resume, and a separate window. Existing transcript paths and formats are preserved.

## Observed checks

- Release build and stable ImageSmith Dev signing: passed. Installed in `/Applications/MeetingScribe.app`. Previous installed bundle retained at `build/rollback/MeetingScribe.app`.
- `--workflowtest`: passed with synthetic speech timing/revisions/echo/flush; bounded CLI cancellation/output limits; model receipts/fallback; queue priority; source/finality/session races; folder/Git exclusions and immutable citations; switch/deadline/source-mutation fences; legacy archive formats; actual AppKit anchor/takeover/resume layout.
- Native folder selection, project creation and reopen: exercised through the installed UI.
- Standard Claude preparation on an unrelated synthetic project: 18.9 seconds, actual receipt `claude-opus-5-5`, 7 cited claims.
- Real target folder preparation initially timed out with a 40-claim output and 120-second request budget. Opening briefs now request at most 16 claims, leaving the full corpus for retrieval, and synthesis may use up to 240 seconds within the overall 300-second deadline. Reopening the target completed in approximately 87 seconds, with 16 claims and explicit coverage limits. No client content or paths are embedded in runtime source/defaults.
- Real standard-mode attention and typed-answer smoke: actual receipts `claude-haiku-5-5` and `claude-sonnet-5-5`; accepted cited cues. The first detector response exposed readable IDs where UUIDs were expected. Strict UUID/null schema constraints and explicit app-assigned new issue identity fixed the failure; a regression check covers this. Fast was off.
- Bundled model loading/prediction: both Unified managers concurrently and Nemotron fast32 passed. Missing-bundle Apple fallback was separately exercised and reported explicitly.
- Two-channel local TTS replay: correct timeline sample counts with intentional offsets/gaps, R1/L1 labels, full sentence tails, no runtime errors. An accuracy error dropped “dollars” from “forty two thousand dollars”; this is not evidence of meeting-level accuracy.
- Installed ScreenCaptureKit smoke: microphone and screen-audio permissions present; 517 remote and 939 local buffers over 10 seconds; stop/drain completed and labeled final text was saved. No advisor ran during this capture check. The additive test session is titled “Capture verification (10 seconds)”.
- Independent integration review found and fixed Quit during startup/drain, speech readiness after engine changes, session packet identity, and stale scroll intent.

Evidence is in ignored local `build/verification/`, including workflow JSON reports, `advice-provider-smoke.log`, `speech-smoke/` and `capture-check.log`. It is not published or committed. The actual preparation packet stays in the normal local project library.

## Live acceptance still required

Tomorrow is the first actual meeting test for conversational usefulness, speaker separation under real acoustics, names/numbers/units, end-to-end latency, and one-to-two-second glance comprehension. The receiving side of application-window sharing has not been rehearsed. Premium Fast entitlement/effective speed was not exercised; the UI labels it requested unless confirmed.

This release uses local text/source/Git snapshots. It does not refresh Outlook, Teams, SharePoint, Dynamics, Power Automate, Teamwork or remote Git. Unsupported Office/PDF material is listed; existing text exports are usable. Incremental extraction caching and historical-packet pruning are deferred. Citation validation checks source existence and exact quotes, not semantic truth or deployment/acceptance. Sources can be incomplete or stale; coverage is displayed.

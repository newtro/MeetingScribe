# Project meetings

Open MeetingScribe → Projects → New project. Give it a name and select the project folder (a parent containing multiple Git repositories also works). Opening an existing project refreshes its context automatically. The selected folder remains read-only.

Preparation reads bounded UTF-8 notes and source files, including CLAUDE.md, AGENTS.md and hidden AI handoff notes, plus local Git status, history and diffs. It creates a cited, immutable context packet. Check the source coverage list for excluded, unsupported, missing or capped material. Email, calendars, remote Git servers, Teams, SharePoint and live business systems are not automatically refreshed in this release. PDF/Office originals need existing text exports; unsupported files are listed.

Speech preparation runs locally in parallel. The default is bundled Parakeet Unified EN 0.6B int8, 640 ms, with Nemotron 3 fast32 speaker labels. Settings offers Apple SpeechAnalyzer; availability and fallback are reported. The streaming tier is not a promise of end-to-end advice latency.

Start recording when the audio status is ready. Recording can start while context finishes; advice shows limited coverage until the packet is ready. The continuous listener and research worker are separate from recording. They can fail or time out without stopping transcription.

The prompter marks FACT (cited source content), REPORTED (a claim or reported outcome), and PROPOSAL (a suggested action). Expand Evidence before relying on a consequential statement. Exact citation matching checks where the text came from; it does not independently prove the claim or guarantee that the model's interpretation is correct.

Topics stay in stable slots, with size indicating attention priority and a teal dot indicating the current discussion. Click a topic to inspect or pin it. More retains topic history. The dashboard holds background results and unresolved issues; bring a background result into the prompter explicitly.

New cues follow automatically. Scrolling takes control; hover alone does nothing. Scroll deliberately to the bottom or use Jump to latest to resume. The menu offers text size, an optional floating window and a separate prompter. Keep the prompter outside the application window you share; check the receiving view before the first real meeting.

Fast requests premium Opus Fast mode for technical research. It starts off for each meeting. It does not speed transcription, change the listener's debounce, or silently enable paid account usage. The receipt distinguishes requested mode from confirmed mode. Model IDs and effort are editable by role in Settings.

Stop drains the speech and speaker-label queues before closing the transcript. Quit during startup or stopping waits for this lifecycle to finish. Final transcripts keep the existing JSONL/plain-text formats under ~/Documents/MeetingScribe/sessions. Names require confirmation: R1/L1 are anonymous channel-local voices, not verified identities.

The five-minute opening target has a bounded preparation deadline. If access, input coverage or the provider prevents preparation, the app reports that rather than marking a stale packet ready. This release retains immutable packet history; incremental extraction caching and automatic history pruning are not yet implemented.

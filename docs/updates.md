# Installed updates and release publishing

MeetingScribe uses Sparkle 2, like iSmith and ImageSmith. The installed release checks the public feed daily and offers **Check for Updates…** in the application menu. This app also enables automatic downloads and installation on normal quit. Meeting capture/start/stop must finish before an updater-driven restart; the app's updater delegate enforces that boundary.

The feed is `https://raw.githubusercontent.com/newtro/MeetingScribe/main/appcast.xml`. Downloads are immutable ZIP assets in `newtro/MeetingScribe` GitHub releases. The app verifies archives with its embedded public Ed25519 key before extraction. The private key remains in the login Keychain under Sparkle account `meetingscribe`; the scripts neither generate nor export it. The feed itself is HTTPS but is not separately signed.

## First release and signing identity

The first updater release is **1.1.1**. Marketing versions use `major.minor.patch`; build numbers are the pinned source commit count and must exceed every build already in the appcast. Do not rewrite release history or reuse a version/tag.

Normal developer builds retain the stable **ImageSmith Dev** signature. Do not use ad-hoc signing. Production releases use **Developer ID Application, team 232A77467G**, hardened runtime, Apple notarization and a stapled ticket. Moving an existing ImageSmith Dev installation to Developer ID is a one-time signing-identity transition: check Screen Recording and microphone access on the installed release and, if macOS requests it, regrant access. Subsequent updates preserve the Developer ID identity. Never silently fall back to the development identity when updating an installed Developer ID app.

The cloud-signing helper requires the authorized Apple account in Xcode Settings → Accounts. It makes an archive copy, signs all nested code inside-out with the existing Apple Development identity and hardened runtime, then asks Xcode to export through its cloud-managed Developer ID certificate. This avoids a self-signed hardened executable trying to load an Apple-team Sparkle framework. Library validation stays enabled. The source build is unchanged; no certificate or private key is exported.

## Resumable release commands

Commit the intended source and scripts first. Untracked planning notes are allowed in the main checkout: releases use a separate detached worktree of the exact commit, so `.Codex/`, untracked `AGENTS.md`, local client planning, and runtime meeting data are not copied or pushed. Tracked changes must be committed. Before publication, the pinned commit must equal the checkout's HEAD **and** remote `main`.

```sh
scripts/release.sh prepare 1.1.1
scripts/release.sh submit 1.1.1
scripts/release.sh finish 1.1.1
scripts/release.sh publish 1.1.1
scripts/release.sh status 1.1.1
```

- **prepare** pins HEAD in `build/releases/<version>/src`, reuses `build/models` through `MEETINGSCRIBE_MODEL_CACHE`, builds with an Apple Development signature and hardened runtime, runs the offline workflow tests, validates version/build and verifies the existing Sparkle public key. Override the development identity with `MEETINGSCRIBE_DEVELOPMENT_SIGN_ID` only for another suitable identity on the same team.
- **submit** uploads the pinned archive for notarization using Xcode. It returns when submission finishes. A successful submission is not repeated. After an interrupted or failed attempt, try `finish` first; use `submit <version> --retry` only if a new upload is needed.
- **finish** makes one attempt to export the notarized app. Exit 75 means it is not ready: inspect the indicated log and run the command later. There is no sleeping/polling loop. Once accepted, it verifies the code signature, Gatekeeper and stapled ticket, packages ZIP/DMG, signs the ZIP with the dedicated Sparkle key and creates a candidate appcast atomically. It does not publish.
- **publish** requires the source/remote-main checks, verifies artifact hashes, creates a draft release, uploads missing artifacts without overwriting existing ones, publishes the release, then commits **only** `appcast.xml` in a separate feed worktree and pushes that commit to main. A release-specific marker permits retrying this run's draft/public release; a pre-existing unrelated version is rejected. If a feed push fails, the downloadable release can exist while the old feed remains live; resume `publish` after resolving the reported condition, never force-push. The source checkout is deliberately left at its original commit; fast-forward it separately when appropriate.

State, logs, pinned worktrees and packages remain in ignored `build/releases/<version>/`. Intermediate bundles can be registered by Xcode; unregister/remove those copies after installation and verification so LaunchServices has an unambiguous installed copy. Keep the signed ZIP/DMG and release receipts. No cleanup step touches `~/Documents/MeetingScribe`.

For a local Developer ID export without uploading/notarizing:

```sh
scripts/developer-id.sh build/MeetingScribe.app build/install-signing export
# Result: build/install-signing/export/MeetingScribe.app
```

The export result is a managed symlink to a fresh signed attempt. An export is not a notarization claim. For a published release, install the app under `build/releases/<version>/notarized/MeetingScribe.app` only after `finish` succeeds.

## Verification before declaring updates working

Check that the published appcast and ZIP are readable without GitHub authentication, the enclosure signature verifies, and its build/version match the installed bundle. Check the installed app's update menu against the live feed. A real update/relaunch rehearsal must verify that transcript/project data survive and that no update interrupts capture. The presence of Sparkle and a feed URL alone is not proof that an update installed successfully.

The updater also defers checks and installation while preparation or summary work is active. Settings exposes Sparkle's actual automatic-check/download preferences rather than resetting them on launch. Developer installs with `./build.sh --install` require the app to be quit normally first and preserve an existing Developer ID installation through a fresh Developer ID export.

An isolated Sparkle installation rehearsal is available as `scripts/update-smoke.sh`. It uses its own temporary bundle ID, loopback feed, throwaway archive-signing key and synthetic transcript files; it does not access the real meeting library. That rehearsal passed automatic download, install on quit, version replacement, signature verification and byte-identical transcript preservation on 2026-11-02. Production activity-policy and Objective-C delegate wiring checks run in `--workflowtest`.

Sparkle configuration follows the [official setup](https://sparkle-project.org/documentation/) and [automatic-update settings](https://sparkle-project.org/documentation/customization/).

# Isolated automatic-update smoke

Run `scripts/update-smoke.sh` after resolving Sparkle. The test requires an existing Apple Development signing identity (override with `SPARKLE_TEST_SIGN_ID`) and OpenSSL with Ed25519 support. Set `SPARKLE_DIST` only if the Sparkle artifact lives outside the normal SwiftPM cache.

The script builds a tiny native AppKit/Sparkle host twice. It signs both with hardened runtime, generates a fresh test-only Ed25519 seed, serves the signed update on loopback, lets Sparkle download it automatically, and quits version A through NSApplication. It then verifies that the installed bundle is version B, checks its complete signature, and confirms that B reads byte-identical synthetic transcript JSONL/plain-text files.

Every run has a unique test bundle ID and `build/update-smoke/<UUID>` directory. It never links MeetingScribe capture, provider or data-store code. It does not open the real meeting library, publish a release, export production signing keys or change production preferences. The loopback server/processes and throwaway signing seed are cleaned up. Evidence remains in `result.json`, `reports/`, `http.log` and `verify.log` under the ignored run directory.

This tests Sparkle packaging, signed download, installation on quit and file preservation. It does **not** test MeetingScribe's busy-state deferral, Developer ID notarization, the public update feed, or capture permission continuity. Those require their own integration checks.

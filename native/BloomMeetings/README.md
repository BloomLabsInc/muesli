# Bloom Meetings

A minimal, local-only Mac meeting recorder in Bloom's Muesli fork. This is a separate app target, not the upstream Muesli release with a new name.

## Current build

- Manually record microphone and system audio in 30-second CAF segments, then transcribe on the Mac with bundled Parakeet v3 models.
- Import audio, edit the transcript and export Markdown.
- Save transcripts automatically and restore the last transcript after reopening.
- Keep source audio and transcripts in the app's private local container. The Recordings folder button opens the archive.
- No account, analytics, iCloud, remote inference, upload endpoint or updater.

The signed macOS App Sandbox grants only audio input and user-selected file read/write. It has no network entitlement. Model loading uses `AsrModels.loadLocal`; the build requires existing model files and runtime cannot download them.

The target does not link the Muesli application shell, TelemetryDeck, Sparkle, CloudKit, remote providers, dictation, screen history or computer-use features. ScreenCaptureKit receives audio outputs only; no screen output is registered or saved.

## Build and verify

Requires macOS 15+, Xcode/Swift 6 and local Parakeet v3 Core ML weights. Dependency resolution happens during the build, not in the installed app.

```sh
BLOOM_MEETINGS_MODEL_DIR=/absolute/path/to/parakeet-tdt-0.6b-v3 \
BLOOM_MEETINGS_TEST_FIXTURE=/absolute/path/to/synthetic-fixture.wav \
./native/BloomMeetings/build-local.sh
python3 native/BloomMeetings/verify-package.py 'native/BloomMeetings/dist/Bloom Meetings.app'
```

The synthetic fixture must include the words “synthetic” and “Friday”. The verifier checks the exact signed entitlements, proves an otherwise reachable localhost server receives no request from the packaged app, and runs bundled-model transcription. It must not use a private meeting recording.

## Boundaries and remaining work

This is a local prototype. The installed build is signed with David’s Apple Development identity and hardened runtime; builds default to ad-hoc signing unless `BLOOM_MEETINGS_SIGNING_IDENTITY` is set. Automatic meeting detection, chronological speaker merging, an archive browser, notarized distribution and Bloom-owned updates are not implemented. Microphone and other-participant audio currently transcribe into separate sections. Crash recovery of the final open segment and device switching have not been validated. It is not yet a finished Granola replacement.

Upstream Muesli's app, preferences and data are not migrated, deleted or overwritten. This app uses bundle ID `diy.bloom.meetings` and a separate sandbox. Explicitly exported files can be placed in a cloud-synced folder by the user; the app itself does not sync them. macOS backup policies remain outside the app. Writing Tools are disabled in both text fields; user-initiated OS Services and exports are outside the app’s network boundary.

Muesli's MIT license remains in the repository. FluidAudio and the speech model retain their own licenses; include their notices and verify model redistribution terms before publishing a distributable bundle. No upstream signing key or update feed is used.

## Validation on 2026-11-10

Release build and exact-entitlement/network-denial/bundled-transcription checks passed. Native UI checks passed: synthetic import, edited title and transcript restored after quit/reopen, short microphone + system capture, local save and transcription. These were short functional checks, not a long-meeting reliability benchmark.

Independent Opus 5.5 review identified AAC finalization/backpressure risks, UI-only transcript storage, Writing Tools, stale package contents and capture lifecycle issues. The current build uses segmented PCM CAF, finalizes all tracks, preserves partial transcription, autosaves imports/edits, disables Writing Tools, prevents closing an active recording window, serializes buffer state and recreates the generated bundle. Further crash/device-switch recovery tests, recovery UI, model provenance/redistribution checks and release signing remain open.

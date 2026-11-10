# Bloom Meetings

Bloom's small Mac meeting recorder, built as a separate app in the Muesli fork. It uses macOS audio capture and local Parakeet transcription; it does not run the upstream Muesli account, telemetry, cloud sync or updater.

## Everyday use

Leave Bloom Meetings running (Open at login is available). After a supported call app or browser uses the microphone for four seconds, a prompt offers **Record meeting**. Recording starts only after that click. **Stop recording** saves the audio and transcribes on the Mac. Notes and transcript edits save automatically. Import, export, an archive and **Recover transcript** are available.

Detection observes audio-process activity, not calendars or browser pages. Browser dictation can also cause a prompt. It recognizes Dia/Arc's separate audio helper, Chrome, Safari, Edge, Firefox, Zoom, Teams, Slack, FaceTime, Webex and WhatsApp. Brief microphone mutes do not repeatedly prompt. Calendar reminders and joining meeting links are not implemented.

## Data and authentication

- Audio stays in this app's private Mac container. Capture writes microphone and system audio to separate 30-second PCM CAF segments, retaining audio and partial transcripts after an interrupted transcription. No screen video is captured.
- Optional **Back up transcripts** sends transcripts, notes and titles only to Bloom's `bloom-meetings` Convex project. Production: `reminiscent-buzzard-959`; development: `fleet-stingray-478`, both in Bloom Labs.
- Convex Auth email codes allow verified `@bloom.diy` accounts only. Every meeting query and mutation checks that identity and restricts records to their owner. Sessions stay in this app's Keychain entry. No credential is bundled in the app.
- Cloud restore retrieves the latest 20 meetings and does not overwrite existing local folders. Conflicting revisions are rejected; the local copy is retained. Audio itself is not backed up.
- Existing upstream Muesli data is not migrated, overwritten or deleted.

The app has the macOS sandbox, audio input, user-selected file access and outbound network entitlements. It bundles its speech model and has no runtime model download. Writing Tools are disabled in the editors. User-directed exports, macOS Services and OS backups remain outside the app's controls.

## Build and checks

macOS 15+, Swift 6 and local Parakeet v3 Core ML weights are required.

```sh
swift test --package-path native/BloomMeetings
BLOOM_MEETINGS_SIGNING_IDENTITY='your Apple Development identity' \
BLOOM_MEETINGS_MODEL_DIR=/absolute/path/to/parakeet-tdt-0.6b-v3 \
BLOOM_MEETINGS_TEST_FIXTURE=/absolute/path/to/synthetic-fixture.wav \
./native/BloomMeetings/build-local.sh
python3 native/BloomMeetings/verify-package.py 'native/BloomMeetings/dist/Bloom Meetings.app'
cd backend
bun install --frozen-lockfile
bun run typecheck
bun run test
```

The synthetic fixture must contain “synthetic” and “Friday”. The package verifier checks the exact signed entitlements and bundled-model transcription. `BloomMeetings --verify-capture` runs a 65-second capture check, reports only track durations/counts, and removes its temporary audio afterwards. Never use private recordings for fixtures.

## Current limits

This is an internal app, signed locally with David's Apple Development identity. It is not notarized and has no automatic update feed. The Bloom Project imports this repository, but its Environment definition does not yet bind the standalone Convex deployment. Gmail/Calendar through Bloom Connections is not wired up.

Transcripts group audio chunks by microphone/other-participant track; this is not word-level speaker diarization. A short capture is evidence of working capture, not proof of multi-hour or device-switch reliability. Keep original audio until you have checked important transcripts. Recovery preserves the previous edited transcript in a separate local file.

Muesli's MIT license, FluidAudio's Apache 2.0 license, and NVIDIA/FluidInference model attribution are included in the bundle. The model cards identify CC BY 4.0; see THIRD_PARTY_NOTICES.md. No upstream signing identity or update feed is used.

## Checks on David's Mac, 2026-11-10

- Verified Bloom email sign-in, Keychain persistence across relaunch, and private transcript backup.
- A live browser microphone check initially failed to prompt: Dia reports `company.thebrowser.browser.helper`. A regression test failed before adding that mapping and passed afterwards. Bloom's own prompt then opened, including after closing the main window, and its Record button started capture.
- A 65-second capture probe produced 68.94 seconds of system audio and 68.917 seconds of microphone audio across six files. Both tracks survived two segment rotations. Probe audio was removed.
- A synthetic call recorded through the popup transcribed both tracks and backed up successfully. A temporarily displaced synthetic meeting was restored from Convex with identical transcript, notes, owner and revision; original files were preserved.
- Native tests cover detection/mute suppression, the Dia helper, legacy migration, and corrupt-archive isolation. Backend tests cover domain/verification rejection, owner isolation, anonymous denial, idempotency and conflicting revisions. Type-check and packaged entitlement/transcription checks passed.

These are short functional checks. Multi-hour calls, Bluetooth device changes and real meeting transcript accuracy have not been validated.

### Independent review follow-through

Opus 5.5/high completed an independent source/dependency review. The final build pads sub-0.3-second tails without discarding their samples, retains warnings for unreadable audio, backs up partial transcripts as incomplete, keeps detection active against App Nap, presents the prompt across full-screen Spaces, and warns visibly if capture stops early. Backup processes each meeting independently and reloads it immediately before upload, preserving edits made during other uploads. Imported movie/MP3 files remain discoverable by recovery.

The backup regression was run against the former fail-fast loop and failed, then passed with per-meeting isolation. Seven native and three backend tests passed. Real sign-in and production destination were verified, dependencies pinned, and builds use David's stable signing identity.

Capture does not silently restart after macOS stops sharing: that may be an intentional privacy action. The app warns and preserves captured audio; start a new recording to continue. Full-screen presentation is configured but not yet exercised in a real full-screen meeting. Wear headphones to avoid capturing speaker audio again through the microphone; this small target has no echo cancellation.

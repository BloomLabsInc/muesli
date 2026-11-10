#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
MODEL="${BLOOM_MEETINGS_MODEL_DIR:?Point BLOOM_MEETINGS_MODEL_DIR at the local parakeet-tdt-0.6b-v3 model folder}"
OUT="${BLOOM_MEETINGS_OUTPUT_DIR:-$ROOT/dist}"
APP="$OUT/Bloom Meetings.app"
for part in Encoder.mlmodelc Decoder.mlmodelc JointDecisionv3.mlmodelc Preprocessor.mlmodelc parakeet_vocab.json; do
  test -e "$MODEL/$part" || { echo "Missing model component: $part" >&2; exit 1; }
done
swift build --package-path "$ROOT" -c release
BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)"
rm -rf "$APP" # This path is the generated bundle inside the chosen build output.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Models"
cp "$BIN/BloomMeetings" "$APP/Contents/MacOS/BloomMeetings"
ditto "$MODEL" "$APP/Contents/Resources/Models/parakeet-tdt-0.6b-v3"
if [ -n "${BLOOM_MEETINGS_TEST_FIXTURE:-}" ]; then cp "$BLOOM_MEETINGS_TEST_FIXTURE" "$APP/Contents/Resources/synthetic-fixture.wav"; fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>diy.bloom.meetings</string>
<key>CFBundleName</key><string>Bloom Meetings</string>
<key>CFBundleExecutable</key><string>BloomMeetings</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSMicrophoneUsageDescription</key><string>Record your side of a meeting. Audio stays on this Mac.</string>
<key>NSAudioCaptureUsageDescription</key><string>Record the other meeting participants. Audio stays on this Mac.</string>
<key>NSScreenCaptureUsageDescription</key><string>Capture system audio for meetings. No screen frames are saved.</string>
</dict></plist>
PLIST
codesign --force --options runtime --sign "${BLOOM_MEETINGS_SIGNING_IDENTITY:--}" --entitlements "$ROOT/BloomMeetings.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"

#!/usr/bin/env python3
"""Check the packaged entitlements and local transcription with a synthetic fixture."""
import pathlib, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1]).resolve()
raw = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL)
entitlements = plistlib.loads(raw)
assert entitlements == {
    'com.apple.security.app-sandbox': True,
    'com.apple.security.device.audio-input': True,
    'com.apple.security.files.user-selected.read-write': True,
    'com.apple.security.network.client': True,
}, entitlements
exe = str(app / 'Contents/MacOS/BloomMeetings')
transcript = subprocess.run([exe, '--verify-local-transcription'], capture_output=True, text=True, timeout=180)
assert transcript.returncode == 0, transcript.stdout + transcript.stderr
print('PASS: exact sandbox entitlements; bundled model transcribed the synthetic fixture')

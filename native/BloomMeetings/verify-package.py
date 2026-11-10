#!/usr/bin/env python3
"""Check the packaged boundary with a reachable local server, never an external host."""
import http.server, pathlib, plistlib, subprocess, sys, threading, urllib.request
app = pathlib.Path(sys.argv[1]).resolve()
raw = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL)
entitlements = plistlib.loads(raw)
assert entitlements == {
    'com.apple.security.app-sandbox': True,
    'com.apple.security.device.audio-input': True,
    'com.apple.security.files.user-selected.read-write': True,
}, entitlements
hits = []
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        hits.append(self.path)
        self.send_response(200); self.end_headers(); self.wfile.write(b'baseline')
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f'http://127.0.0.1:{server.server_port}/privacy-probe'
assert urllib.request.urlopen(url).status == 200
hits.clear()
exe = str(app / 'Contents/MacOS/BloomMeetings')
try:
    result = subprocess.run([exe, '--verify-network-denied', url], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not hits, 'The supposedly offline app reached the server'
    assert 'denied or failed' in result.stdout, result.stdout
    print('PASS: exact sandbox entitlements; reachable localhost received no request from packaged app')
    transcript = subprocess.run([exe, '--verify-local-transcription'], capture_output=True, text=True, timeout=180)
    assert transcript.returncode == 0, transcript.stdout + transcript.stderr
    print('PASS: bundled model transcribed the synthetic fixture offline')
finally:
    server.shutdown()

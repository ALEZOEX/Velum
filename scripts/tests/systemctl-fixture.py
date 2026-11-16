#!/usr/bin/python3
"""Inert systemd adapter for the isolated installer filesystem tests only."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

run = Path('/run')
if sys.argv[1:] == ['fixture-api']:
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class Status(BaseHTTPRequestHandler):
        def do_GET(self):
            token = Path('/etc/velum/token').read_text().strip()
            if self.headers.get('Authorization') != 'Bearer ' + token:
                self.send_error(401)
                return
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"tunAllowed":true,"state":"disconnected"}')

        def log_message(self, *args):
            pass

    HTTPServer.allow_reuse_address = True
    HTTPServer(('127.0.0.1', 27841), Status).serve_forever()
    sys.exit(0)

args = sys.argv[1:]
with (run / 'systemctl-calls').open('a') as log:
    log.write(json.dumps(args) + '\n')
action = args[0]
failure = run / ('fail-' + action)
if failure.exists():
    failure.unlink()
    if action == 'start' and (run / 'limit-on-failure').exists():
        (run / 'start-limit').touch()
    sys.exit('injected systemctl failure: ' + action)
if action == 'reset-failed':
    (run / 'start-limit').unlink(missing_ok=True)
if action in ('start', 'restart') and (run / 'start-limit').exists():
    sys.exit('injected systemd start-limit-hit')
if action == 'show':
    override = run / 'unit-fragment'
    print(override.read_text().strip() if override.exists() else
          ('/etc/systemd/system/velum.service' if Path('/etc/systemd/system/velum.service').exists() else ''))
    sys.exit(0)
if action == 'is-active':
    sys.exit(0 if (run / 'active').exists() else 3)
if action == 'is-enabled':
    sys.exit(0 if (run / 'enabled').exists() else 1)
if action in ('stop', 'restart') or (action == 'disable' and '--now' in args):
    if (run / 'api-pid').exists():
        try:
            child_pid = int((run / 'api-pid').read_text())
            os.kill(child_pid, signal.SIGTERM)
            for _ in range(200):
                process = Path(f'/proc/{child_pid}/stat')
                if not process.exists() or process.read_text().split()[2] == 'Z':
                    break
                time.sleep(.01)
            else:
                sys.exit('fixture API did not stop')
        except ProcessLookupError:
            pass
        (run / 'api-pid').unlink()
    (run / 'active').unlink(missing_ok=True)
if action == 'enable':
    (run / 'enabled').touch()
if action == 'disable':
    (run / 'enabled').unlink(missing_ok=True)
if action in ('start', 'restart') and not (run / 'active').exists():
    child = subprocess.Popen(['/usr/bin/python3', '-I', __file__, 'fixture-api'],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    (run / 'api-pid').write_text(str(child.pid))
    (run / 'active').touch()

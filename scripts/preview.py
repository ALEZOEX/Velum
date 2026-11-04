#!/usr/bin/env python3
"""Capture the Linux UI with isolated sample data, display and D-Bus session."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path)
parser.add_argument('--width', type=int, default=980)
parser.add_argument('--height', type=int, default=760)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
out = args.output or root / 'docs' / 'preview.png'
out.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='velum-preview-') as folder:
    data = Path(folder)
    document = {
        'version': 2,
        'profiles': [{'id': 'preview', 'uri': 'vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443?security=tls&type=tcp', 'name': 'Тестовый сервер · 192.0.2.1'}],
        'subscriptions': [], 'selected': 0, 'exclusions': '', 'settings': {},
    }
    (data / 'profiles.json').write_text(json.dumps(document), encoding='utf-8')
    os.chmod(data / 'profiles.json', 0o600)
    env = dict(os.environ, DISPLAY=':97', GDK_BACKEND='x11', LIBGL_ALWAYS_SOFTWARE='1', VELUM_CONFIG_DIR=str(data))
    xvfb = subprocess.Popen(['Xvfb', ':97', '-screen', '0', f'{args.width}x{args.height}x24', '-nolisten', 'tcp'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    app = None
    try:
        time.sleep(1)
        app = subprocess.Popen(['dbus-run-session', '--', str(root / 'app/build/linux/x64/release/bundle/velum')], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        time.sleep(4)
        if app.poll() is not None:
            raise RuntimeError('App exited before screenshot')
        subprocess.run(['import', '-display', ':97', '-window', 'root', str(out)], check=True, timeout=10)
        print(out)
    finally:
        if app is not None:
            import signal
            try:
                os.killpg(app.pid, signal.SIGTERM)
                app.wait(timeout=5)
            except ProcessLookupError:
                pass
            except subprocess.TimeoutExpired:
                os.killpg(app.pid, signal.SIGKILL)
                app.wait()
        xvfb.terminate()
        xvfb.wait(timeout=5)

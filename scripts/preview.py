#!/usr/bin/env python3
"""Capture the Linux app in an isolated Xvfb display without changing the desktop."""
import os
from pathlib import Path
import subprocess
import time
root = Path(__file__).resolve().parent.parent
out = root / 'docs' / 'preview.png'
env = dict(os.environ, DISPLAY=':97', GDK_BACKEND='x11', LIBGL_ALWAYS_SOFTWARE='1')
xvfb = subprocess.Popen(['Xvfb', ':97', '-screen', '0', '1280x1000x24', '-nolisten', 'tcp'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
app = None
try:
    time.sleep(1)
    app = subprocess.Popen([str(root / 'app/build/linux/x64/release/bundle/velum')], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(4)
    if app.poll() is not None:
        raise RuntimeError('App exited before screenshot')
    subprocess.run(['import', '-display', ':97', '-window', 'root', str(out)], check=True, timeout=10)
    print(out)
finally:
    for process in (app, xvfb):
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

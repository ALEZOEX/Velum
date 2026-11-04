#!/usr/bin/env python3
"""Fetch the pinned official Linux x64 Xray archive, verifying its SHA-256."""
import hashlib
import io
import os
from pathlib import Path
import platform
import tempfile
import urllib.request
import zipfile

VERSION = '26.10.31'
SHA256 = 'e4bd9119f50ae7c41658b1abd0679ae06f98bd864a2907ff33f2f2cf7081b214'
URL = f'https://github.com/XTLS/Xray-core/releases/download/v{VERSION}/Xray-linux-64.zip'

def main():
    if platform.system() != 'Linux' or platform.machine() not in ('x86_64', 'amd64'):
        raise SystemExit('This pinned download target supports Linux x64 only.')
    target = Path(__file__).resolve().parent.parent / 'bin'
    target.mkdir(exist_ok=True)
    existing = target / 'xray'
    # Download and verify before replacing any existing executable.
    request = urllib.request.Request(URL, headers={'User-Agent': 'Velum-Builder'})
    with urllib.request.urlopen(request, timeout=60) as response:
        archive = response.read(100 * 1024 * 1024 + 1)
    if len(archive) > 100 * 1024 * 1024 or hashlib.sha256(archive).hexdigest() != SHA256:
        raise SystemExit('Xray archive checksum verification failed; existing binary was not changed.')
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        binary = bundle.read('xray')
        license_text = bundle.read('LICENSE')
    descriptor, temporary = tempfile.mkstemp(prefix='.xray-', dir=target)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            output.write(binary)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), 0o755)
        (target / 'LICENSE.xray').write_bytes(license_text)
        os.replace(temporary, existing)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f'Xray {VERSION}: official archive checksum verified, installed {existing}')

if __name__ == '__main__':
    main()

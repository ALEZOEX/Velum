#!/usr/bin/env python3
"""Fetch the pinned official Linux x64 Xray archive, verifying its SHA-256."""
import hashlib
import io
import os
from pathlib import Path
import platform
import sys
import tempfile
import urllib.request
import zipfile

VERSION = '26.10.31'
SHA256_LINUX = 'e4bd9119f50ae7c41658b1abd0679ae06f98bd864a2907ff33f2f2cf7081b214'
SHA256_WINDOWS = '2e04a9995a6f2ad1b28c0bb25c708ecb2695e43a1c9c7889c4b6ac2b48cf7a6a'

def main():
    target = Path(__file__).resolve().parent.parent / 'bin'
    target.mkdir(exist_ok=True)
    is_windows = '--windows' in sys.argv or platform.system() == 'Windows'
    if is_windows:
        filename = 'xray.exe'
        expected_sha = SHA256_WINDOWS
        url = f'https://github.com/XTLS/Xray-core/releases/download/v{VERSION}/Xray-windows-64.zip'
    else:
        if platform.system() != 'Linux' or platform.machine() not in ('x86_64', 'amd64'):
            raise SystemExit('This pinned download target supports Linux x64 only.')
        filename = 'xray'
        expected_sha = SHA256_LINUX
        url = f'https://github.com/XTLS/Xray-core/releases/download/v{VERSION}/Xray-linux-64.zip'

    existing = target / filename
    request = urllib.request.Request(url, headers={'User-Agent': 'Velum-Builder'})
    with urllib.request.urlopen(request, timeout=60) as response:
        archive = response.read(100 * 1024 * 1024 + 1)
    if len(archive) > 100 * 1024 * 1024 or hashlib.sha256(archive).hexdigest() != expected_sha:
        raise SystemExit(f'Xray ({filename}) archive checksum verification failed; existing binary was not changed.')
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        binary = bundle.read(filename)
        license_text = bundle.read('LICENSE')
    descriptor, temporary = tempfile.mkstemp(prefix=f'.{filename}-', dir=target)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            output.write(binary)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), 0o755)
        (target / f'LICENSE.{filename}').write_bytes(license_text)
        os.replace(temporary, existing)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f'Xray {VERSION} ({filename}): official archive checksum verified, installed {existing}')

if __name__ == '__main__':
    main()

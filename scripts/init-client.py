#!/usr/bin/env python3
"""Create private client storage and an API token without replacing existing data."""
import os
from pathlib import Path
import secrets

folder = Path.home() / '.config' / 'velum'
folder.mkdir(parents=True, exist_ok=True, mode=0o700)
folder.chmod(0o700)
token = folder / 'token'
if not token.exists():
    fd = os.open(token, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        stream.write(secrets.token_hex(32) + '\n')
token.chmod(0o600)
print(f'Client directory: {folder}')
print('Token prepared; value is never printed.')

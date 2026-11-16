#!/usr/bin/env python3
"""Build pinned sing-box with the reviewed TUN FD adapter; never edit module cache."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', default=str(Path(__file__).resolve().parent.parent / 'bin/sing-box'))
args = parser.parse_args()
source = json.loads(subprocess.check_output(['go', 'mod', 'download', '-json', 'github.com/sagernet/sing-box@v1.12.12']))
if source.get('Version') != 'v1.12.12' or source.get('Sum') != 'h1:brSb4zdL5CfqXB0ss1jrT+srPUbKanyWhbswkte/z5Y=':
    raise SystemExit('Pinned, module-verified sing-box source required')
patch = Path(__file__).resolve().parent.parent / 'patches/sing-box-1.12.12-tun-fd.patch'
output = Path(args.output).absolute()
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='velum-core-build-') as temporary:
    checkout = Path(temporary) / 'sing-box'
    shutil.copytree(source['Dir'], checkout)
    for path in checkout.rglob('*'):
        if path.is_dir(): path.chmod(0o755)
    checkout.chmod(0o755)
    for name in ('option/tun.go', 'protocol/tun/inbound.go'):
        (checkout / name).chmod(0o644)
    # Zero-context hunks use exact offsets; verify the complete target files first.
    for name, expected in {'option/tun.go': 'f4000f4c57e1a133bf29c28f34220eda3668ac6aacce8f95b68db6e5010a5dcd', 'protocol/tun/inbound.go': '21ddadf1632148d376dfd54ffc3189483a5c9c2f19d9b6b5f96df22d6b6169cc'}.items():
        if hashlib.sha256((checkout / name).read_bytes()).hexdigest() != expected:
            raise SystemExit(f"Unexpected pinned source content: {name}")
    subprocess.run(['patch', '--batch', '--fuzz=0', '-p1', '-i', str(patch)], cwd=checkout, check=True)
    subprocess.run(['gofmt', '-w', 'option/tun.go', 'protocol/tun/inbound.go'], cwd=checkout, check=True)
    subprocess.run(['go', 'build', '-mod=readonly', '-trimpath', '-ldflags',
                    '-X github.com/sagernet/sing-box/constant.Version=1.12.12',
                    '-tags', 'with_utls,with_quic,with_clash_api', '-o', str(output), './cmd/sing-box'],
                   cwd=checkout, check=True)
print(f'Built sing-box 1.12.12 + Velum TUN-FD adapter: {output}')

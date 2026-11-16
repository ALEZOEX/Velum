#!/usr/bin/python3
"""Real systemd lifecycle on a clean GitHub-hosted disposable Linux VM ONLY."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import secrets
import shutil
import socket
import stat
import subprocess
import tempfile
import urllib.request


def run(*args, success=True):
    result = subprocess.run(args, env={**os.environ, 'PATH': '/usr/sbin:/usr/bin:/sbin:/bin'},
                            cwd='/', capture_output=True, text=True)
    if (result.returncode == 0) != success:
        raise RuntimeError(f'{args[0]} exit {result.returncode}: {result.stdout} {result.stderr}')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--disposable-ci', action='store_true', required=True)
    parser.add_argument('--daemon', required=True)
    parser.add_argument('--source', required=True)
    parser.add_argument('--result', required=True)
    args = parser.parse_args()
    if (os.geteuid() != 0 or os.environ.get('GITHUB_ACTIONS') != 'true'
            or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted'):
        raise RuntimeError('Only an explicitly authorized disposable GitHub-hosted VM is supported')
    run('/usr/bin/systemd-detect-virt', '--vm', '--quiet')
    base = Path('/usr/local/lib/velum')
    unit = Path('/etc/systemd/system/velum.service')
    config = Path('/etc/velum')
    policy = Path('/usr/share/polkit-1/actions/app.velum.service.policy')
    for path in (base, unit, config, policy):
        if path.exists() or path.is_symlink():
            raise RuntimeError(f'Existing state must not be touched: {path}')
    if run('/usr/bin/systemctl', 'list-unit-files', 'velum.service').stdout.count('velum.service'):
        raise RuntimeError('An existing vendor service must not be touched')
    uid = int(os.environ['SUDO_UID'])
    if uid == 0:
        raise RuntimeError('An actual unprivileged runner identity is required')
    user = pwd.getpwuid(uid)
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 27841))
    def network_snapshot():
        # Exclude kernel countdowns, retain actual route and rule attributes.
        def stable(value):
            if isinstance(value, dict):
                return {k: stable(v) for k, v in value.items() if k != 'expires'}
            if isinstance(value, list):
                return sorted((stable(x) for x in value), key=lambda x: json.dumps(x, sort_keys=True))
            return value
        return [stable(json.loads(run('/usr/sbin/ip', family, '-j', *command).stdout))
                for family in ('-4', '-6')
                for command in (('route', 'show', 'table', 'all'), ('rule', 'show'))]
    network_before = network_snapshot()
    checks = []
    temporary = Path(tempfile.mkdtemp(prefix='velum-f15-systemd-'))
    os.chmod(temporary, 0o755)
    repo = temporary / 'reviewed-release'
    shutil.copytree(Path(args.source) / 'scripts', repo / 'scripts')
    shutil.copytree(Path(args.source) / 'packaging/linux', repo / 'packaging/linux')
    (repo / 'bin').mkdir()
    shutil.copyfile(args.daemon, repo / 'bin/velumd')
    os.chmod(repo / 'bin/velumd', 0o755)
    for name, version in (('sing-box', 'sing-box version 1.12.12'), ('xray', 'Xray 26.10.31 F15 inert fixture')):
        file = repo / 'bin' / name
        file.write_text(f'#!/bin/bash\nif [[ $# == 1 && $1 == version ]]; then printf "%s\\n" "{version}"; exit 0; fi\nprintf "Refusing engine execution\\n" >&2\nexit 97\n')
        os.chmod(file, 0o755)
    gui = temporary / 'gui-token'
    gui.mkdir(mode=0o700)
    os.chown(gui, uid, user.pw_gid)
    token_file = gui / 'token'
    token_file.write_text(secrets.token_hex(32) + '\n')
    os.chown(token_file, uid, user.pw_gid)
    os.chmod(token_file, 0o600)
    installer = repo / 'scripts/install-linux-service.sh'
    uninstaller = repo / 'scripts/uninstall-linux-service.sh'
    def invoke(script, *options, success=True):
        return run('/bin/bash', str(script), *options, success=success)
    def install(script=installer):
        invoke(script, '--user', str(uid), '--token-file', str(token_file))
    def status():
        token = token_file.read_text().strip()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(urllib.request.Request('http://127.0.0.1:27841/v1/status',
                         headers={'Authorization': 'Bearer ' + token}), timeout=2) as response:
            data = json.load(response)
        assert data['state'] == 'disconnected' and data['serviceMode'] == 'systemd'
        assert data['tunAllowed'] is True and data['xrayAvailable'] is True
        return data
    def snapshot():
        return {str(p): (hashlib.sha256(p.read_bytes()).hexdigest(), stat.S_IMODE(p.stat().st_mode))
                for p in [*base.iterdir(), unit, config / 'token', policy]}
    try:
        install()
        status()
        assert run('/usr/bin/systemctl', 'is-active', 'velum.service').stdout.strip() == 'active'
        checks.append('real systemd install/start with authenticated API; VPN disconnected')
        before = snapshot()
        install(base / 'install-service.sh')
        status()
        assert snapshot() == before
        checks.append('installed-layout reinstall without bin-dir preserves all files')
        token_file.write_text(secrets.token_hex(32) + '\n')
        install(base / 'install-service.sh')
        status()
        assert (config / 'token').read_bytes() == token_file.read_bytes()
        checks.append('custom GUI token synchronized on reinstall')
        before = snapshot()
        old_binary = (repo / 'bin/velumd').read_bytes()
        (repo / 'bin/velumd').write_text('#!/bin/bash\nexit 97\n')
        invoke(installer, '--user', str(uid), '--token-file', str(token_file), success=False)
        assert snapshot() == before
        status()
        checks.append('failed daemon readiness restores files/token/policy and restarts previous service')
        (repo / 'bin/velumd').write_bytes(old_binary)
        with (repo / 'bin/velumd').open('ab') as stream:
            stream.write(b'F15-upgrade-fixture')
        install()
        status()
        assert (base / 'velumd').read_bytes().endswith(b'F15-upgrade-fixture')
        checks.append('repository upgrade starts updated executable')
        invoke(base / 'velum-service-control', 'stop')
        run('/usr/bin/systemctl', 'is-active', 'velum.service', success=False)
        invoke(base / 'velum-service-control', 'start')
        status()
        checks.append('installed control helper stop/start')
        os.chmod(base / 'velumd', 0o777)
        invoke(installer, '--user', str(uid), '--token-file', str(token_file), success=False)
        invoke(uninstaller, success=False)
        assert stat.S_IMODE((base / 'velumd').stat().st_mode) == 0o777
        os.chmod(base / 'velumd', 0o755)  # Test fixture only, not installer repair.
        checks.append('unsafe installed binary is neither overwritten nor removed')
        invoke(base / 'velum-service-control', 'uninstall')
        assert not any(p.exists() for p in (base, unit, config, policy))
        assert token_file.exists()
        assert not run('/usr/bin/systemctl', 'list-unit-files', 'velum.service').stdout.count('velum.service')
        checks.append('real systemd uninstall removes only service resources; GUI token survives')
        base.symlink_to(repo, target_is_directory=True)
        try:
            invoke(installer, '--user', str(uid), '--token-file', str(token_file), success=False)
            invoke(uninstaller, success=False)
            assert (repo / 'bin/velumd').exists()
        finally:
            base.unlink()
        checks.append('symlink destination refuses install and uninstall; outside files unchanged')
        assert network_snapshot() == network_before
        checks.append('IPv4/IPv6 routes and policy rules unchanged; no connect requests sent')
        print(json.dumps({'passed': True, 'checks': checks, 'vpnConnected': False}, indent=2))
        Path(args.result).write_text(json.dumps({'passed': True, 'checks': checks, 'vpnConnected': False}, indent=2))
    finally:
        # Use the reviewed production uninstaller. Never broaden cleanup if it
        # refuses an unsafe tree; hosted VM destruction is the final boundary.
        if base.exists() and not base.is_symlink():
            result = subprocess.run(['/bin/bash', str(uninstaller)], capture_output=True, text=True)
            if result.returncode:
                print('Cleanup refused; retain VM diagnostics: ' + result.stderr)
        if not base.exists():
            shutil.rmtree(temporary)


if __name__ == '__main__':
    main()

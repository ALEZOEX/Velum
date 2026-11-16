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


def unit_files():
    result = subprocess.run(['/usr/bin/systemctl', 'list-unit-files', '--output=json',
                             '--no-legend', 'velum.service'], capture_output=True, text=True)
    # New systemd returns 1 for an empty match. An actual command/bus failure
    # must still fail the test; require clean stderr and a valid JSON array.
    if result.returncode not in (0, 1) or result.stderr.strip():
        raise RuntimeError(f'Could not enumerate units: {result.stderr}')
    records = json.loads(result.stdout)
    if not isinstance(records, list):
        raise RuntimeError('Expected a unit-file JSON array')
    return records


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
    if unit_files():
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
    prepared_parents = []
    parent_metadata = []
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
        # Hosted runner images may make shared development directories writable
        # by the runner account. Test refusal first; prepare trusted ancestors
        # explicitly ONLY in this disposable VM, then restore their attributes.
        parents = sorted({p for target in (base.parent, unit.parent, policy.parent, config.parent)
                          for p in (target, *target.parents) if str(p) != '/'},
                         key=lambda p: len(p.parts))
        for parent in parents:
            info = parent.lstat()
            if not stat.S_ISDIR(info.st_mode):
                raise RuntimeError(f'VM fixture refuses non-directory ancestor: {parent}')
            acl_names = [name for name in os.listxattr(parent)
                         if name in ('system.posix_acl_access', 'system.posix_acl_default')]
            parent_metadata.append({'path': str(parent), 'uid': info.st_uid, 'gid': info.st_gid,
                                    'mode': oct(stat.S_IMODE(info.st_mode)), 'aclNames': acl_names})
        print('Hosted VM ancestor metadata: ' + json.dumps(parent_metadata), flush=True)
        unsafe = [p for p in parents if p.stat().st_uid != 0 or p.stat().st_mode & 0o022
                  or any(n in os.listxattr(p) for n in ('system.posix_acl_access', 'system.posix_acl_default'))]
        if unsafe:
            refusal = invoke(installer, '--user', str(uid), '--token-file', str(token_file), success=False)
            assert 'Untrusted' in refusal.stderr or 'Extended ACL' in refusal.stderr
            assert not any(p.exists() for p in (base, unit, config, policy))
            print('Expected refusal before fixture preparation: ' + refusal.stderr.strip(), flush=True)
            checks.append('unsafe hosted-image ancestors refused before any service installation')
        for parent in unsafe:
            info = parent.stat()
            acl = {name: os.getxattr(parent, name) for name in os.listxattr(parent)
                   if name in ('system.posix_acl_access', 'system.posix_acl_default')}
            prepared_parents.append((parent, info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), acl))
            for name in acl:
                os.removexattr(parent, name)
            os.chown(parent, 0, 0)
            os.chmod(parent, stat.S_IMODE(info.st_mode) & ~0o022)
        # Only our disposable input bundle: remove inherited/copied ACLs so the
        # positive fixture meets the installer's documented trust preconditions.
        for file in (temporary, *temporary.rglob('*')):
            if file.is_symlink():
                raise RuntimeError(f'Unexpected link in generated fixture: {file}')
            for name in os.listxattr(file):
                if name in ('system.posix_acl_access', 'system.posix_acl_default'):
                    os.removexattr(file, name)
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
        assert not unit_files()
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
        print(json.dumps({'passed': True, 'checks': checks, 'vpnConnected': False, 'hostedImageAncestors': parent_metadata}, indent=2))
        Path(args.result).write_text(json.dumps({'passed': True, 'checks': checks, 'vpnConnected': False, 'hostedImageAncestors': parent_metadata}, indent=2))
    finally:
        # Use the reviewed production uninstaller. Never broaden cleanup if it
        # refuses an unsafe tree; hosted VM destruction is the final boundary.
        if base.exists() and not base.is_symlink():
            result = subprocess.run(['/bin/bash', str(uninstaller)], capture_output=True, text=True)
            if result.returncode:
                print('Cleanup refused; retain VM diagnostics: ' + result.stderr)
        if not base.exists():
            shutil.rmtree(temporary)
            for parent, old_uid, old_gid, old_mode, old_acl in reversed(prepared_parents):
                os.chown(parent, old_uid, old_gid)
                os.chmod(parent, old_mode)
                for name, value in old_acl.items():
                    os.setxattr(parent, name, value)
                restored = parent.stat()
                assert (restored.st_uid, restored.st_gid, stat.S_IMODE(restored.st_mode)) == (old_uid, old_gid, old_mode)
                assert all(os.getxattr(parent, name) == value for name, value in old_acl.items())


if __name__ == '__main__':
    main()

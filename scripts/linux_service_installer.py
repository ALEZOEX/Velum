#!/usr/bin/python3
"""Privileged Linux service file transaction. No networking is configured here."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import secrets
import socket
import signal
import stat
import subprocess
import sys
import time
import urllib.request

BASE = Path('/usr/local/lib/velum')
CONFIG = Path('/etc/velum')
UNIT = Path('/etc/systemd/system/velum.service')
POLICY = Path('/usr/share/polkit-1/actions/app.velum.service.policy')
NAMES = {'velumd', 'sing-box', 'xray', 'install-service.sh',
         'uninstall-service.sh', 'velum-service-control',
         'linux_service_installer.py', 'app.velum.service.policy', 'manifest.json'}
ENV = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C', 'LC_ALL': 'C'}
NOFOLLOW = os.O_NOFOLLOW | os.O_CLOEXEC


class InstallError(Exception):
    pass


def check_info(info, path, owners, directory=False, private=False):
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if (not expected(info.st_mode) or info.st_uid not in owners
            or info.st_mode & (0o077 if private else 0o022)
            or (not directory and info.st_nlink != 1)):
        raise InstallError(f'Untrusted owner, permissions, type or hard links: {path}')


def check_acl(fd, path):
    # Reject extended/default ACLs instead of trying to interpret or repair them.
    if any(x in os.listxattr(fd) for x in ('system.posix_acl_access', 'system.posix_acl_default')):
        raise InstallError(f'Extended ACL requires manual review: {path}')


def open_dir(path, owners=(0,), source=False):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise InstallError(f'Absolute path without .. required: {path}')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW)
    try:
        for part in path.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
            info = os.fstat(fd)
            # A sticky ancestor (e.g. /tmp) cannot replace an owned child.
            sticky = source and info.st_uid == 0 and info.st_mode & stat.S_ISVTX
            if not sticky:
                check_info(info, path, (0, *owners) if source else owners, directory=True)
                check_acl(fd, path)
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_file(path, owners=(0,), executable=False, private=False, source=False, limit=None):
    parent = open_dir(Path(path).parent, owners, source)
    try:
        fd = os.open(Path(path).name, os.O_RDONLY | os.O_NONBLOCK | NOFOLLOW, dir_fd=parent)
        try:
            info = os.fstat(fd)
            check_info(info, path, owners, private=private)
            check_acl(fd, path)
            if executable and not info.st_mode & 0o111:
                raise InstallError(f'Not executable: {path}')
            if limit is not None and info.st_size > limit:
                raise InstallError(f'File too large: {path}')
            with os.fdopen(os.dup(fd), 'rb') as stream:
                data = stream.read() if limit is None else stream.read(limit + 1)
            if limit is not None and len(data) > limit:
                raise InstallError(f'File too large: {path}')
            # Read into an immutable snapshot before any privileged publication.
            after = os.fstat(fd)
            if (info.st_size, info.st_mtime_ns, info.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                raise InstallError(f'Source changed while being read: {path}')
            return data, stat.S_IMODE(info.st_mode)
        finally:
            os.close(fd)
    finally:
        os.close(parent)


class Directory:
    """Pinned, root-owned directory; all writes are relative to this handle."""
    def __init__(self, path):
        self.path = Path(path)
        self.fd = open_dir(path)

    def close(self):
        os.close(self.fd)

    def exists(self, name):
        try:
            os.stat(name, dir_fd=self.fd, follow_symlinks=False)
            return True
        except FileNotFoundError:
            return False

    def snapshot(self, name):
        if not self.exists(name):
            return None
        fd = os.open(name, os.O_RDONLY | os.O_NONBLOCK | NOFOLLOW, dir_fd=self.fd)
        try:
            info = os.fstat(fd)
            check_info(info, self.path / name, (0,))
            check_acl(fd, self.path / name)
            with os.fdopen(os.dup(fd), 'rb') as stream:
                return stream.read(), stat.S_IMODE(info.st_mode)
        finally:
            os.close(fd)

    def write(self, name, data, mode):
        temporary = '.velum-write-' + secrets.token_hex(12)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, mode, dir_fd=self.fd)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(data)
                stream.flush()
                os.fchmod(stream.fileno(), mode)
                os.fsync(stream.fileno())
                check_info(os.fstat(stream.fileno()), self.path / name, (0,))
                check_acl(stream.fileno(), self.path / name)
            os.replace(temporary, name, src_dir_fd=self.fd, dst_dir_fd=self.fd)
            os.fsync(self.fd)
        finally:
            if self.exists(temporary):
                os.unlink(temporary, dir_fd=self.fd)

    def restore(self, name, snapshot):
        if self.snapshot(name) == snapshot:
            return
        if snapshot is None:
            if self.exists(name):
                os.unlink(name, dir_fd=self.fd)
        else:
            self.write(name, *snapshot)


class RecoveryBackup:
    """Private originals survive even if restoring them fails. No auto replay."""
    def __init__(self, parent, snapshots, state):
        self.parent = parent
        self.name = '.velum-recovery-' + secrets.token_hex(12)
        os.mkdir(self.name, 0o700, dir_fd=parent.fd)
        self.directory = Directory(parent.path / self.name)
        self.names = {'unit', 'policy', 'token', 'state.json'}
        try:
            state['modes'] = {}
            for name, snapshot in snapshots.items():
                state['modes'][name] = snapshot[1] if snapshot else None
                if snapshot:
                    self.directory.write(name, snapshot[0], 0o600)
            self.directory.write('state.json', json.dumps(state, sort_keys=True).encode() + b'\n', 0o600)
            os.fsync(parent.fd)
        except BaseException:
            try:
                self.discard()
            finally:
                self.directory.close()
            raise

    def discard(self):
        check_info(os.fstat(self.directory.fd), self.directory.path, (0,), directory=True, private=True)
        names = set(os.listdir(self.directory.fd))
        if not names <= self.names:
            raise InstallError(f'Unknown files in recovery backup: {self.directory.path}')
        for name in names:
            self.directory.snapshot(name)  # Refuse unsafe objects, including links.
        for name in names:
            os.unlink(name, dir_fd=self.directory.fd)
        os.rmdir(self.name, dir_fd=self.parent.fd)


def clear_recovery(recovery):
    if recovery is not None:
        try:
            recovery.discard()
        except (OSError, InstallError) as error:
            print(f'Velum: completed transaction; private recovery backup retained at {recovery.directory.path}: {error}', file=sys.stderr)


def tree(path):
    """Validate every object; never walk/delete unknown descendants."""
    directory = Directory(path)
    try:
        names = set(os.listdir(directory.fd))
        if not names <= NAMES:
            raise InstallError(f'Unrecognized files in {path}: {sorted(names - NAMES)}; nothing will be removed')
        snapshots = {name: directory.snapshot(name) for name in names}
        for name, (_, mode) in snapshots.items():
            if name not in ('manifest.json', 'app.velum.service.policy') and not mode & 0o111:
                raise InstallError(f'Installed executable has no execute permission: {path / name}')
        if 'manifest.json' in snapshots:
            manifest = json.loads(snapshots['manifest.json'][0])
            hashes = manifest['files']
            if manifest.get('format') != 1 or set(hashes) != names - {'manifest.json'}:
                raise InstallError(f'Invalid ownership manifest: {path}')
            for name, digest in hashes.items():
                if hashlib.sha256(snapshots[name][0]).hexdigest() != digest:
                    raise InstallError(f'Installed file differs from ownership manifest: {path / name}')
        return directory, snapshots
    except BaseException:
        directory.close()
        raise


def remove_tree(parent, name):
    directory, _ = tree(parent.path / name)
    try:
        for child in os.listdir(directory.fd):
            os.unlink(child, dir_fd=directory.fd)
    finally:
        directory.close()
    os.rmdir(name, dir_fd=parent.fd)


def systemctl(*args, check=True):
    result = subprocess.run(['/usr/bin/systemctl', *args], env=ENV, capture_output=True, text=True)
    if check and result.returncode:
        raise InstallError(f'systemctl {" ".join(args)} failed: {result.stderr.strip()}')
    return result.returncode == 0


def layout(script):
    # Deliberately do not resolve symlinks or use cwd/HOME/PATH.
    folder = Path(script).parent
    if folder == BASE:
        return {name: folder / name for name in NAMES - {'manifest.json'}}
    if folder.name != 'scripts':
        raise InstallError('Expected repository/scripts or /usr/local/lib/velum installer layout')
    root = folder.parent
    return {
        'velumd': root / 'bin/velumd', 'sing-box': root / 'bin/sing-box', 'xray': root / 'bin/xray',
        'install-service.sh': folder / 'install-linux-service.sh',
        'uninstall-service.sh': folder / 'uninstall-linux-service.sh',
        'linux_service_installer.py': folder / 'linux_service_installer.py',
        'velum-service-control': root / 'packaging/linux/velum-service-control',
        'app.velum.service.policy': root / 'packaging/linux/app.velum.service.policy',
    }


def unit_bytes(xray, interface):
    extra = (' --xray /usr/local/lib/velum/xray' if xray else '')
    if interface:
        extra += ' --interface ' + interface
    return f'''[Unit]
Description=Velum network service
After=network-online.target
Wants=network-online.target
ConditionPathExists=/dev/net/tun

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/lib/velum/velumd --tun --core /usr/local/lib/velum/sing-box --token-file /etc/velum/token{extra}
Restart=on-failure
RestartSec=2
TimeoutStopSec=12
KillMode=control-group
RuntimeDirectory=velum
RuntimeDirectoryMode=0700
Environment=TMPDIR=/run/velum
UMask=0077
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
DevicePolicy=closed
DeviceAllow=/dev/net/tun rw
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
'''.encode()


def owned_unit(snapshot):
    if snapshot is None:
        return False
    # Allow only unit configurations this installer (including the old shell one)
    # produces. A matching ExecStart substring alone does not establish ownership.
    import re
    text = snapshot[0].decode()
    match = re.search(r'^ExecStart=.* --interface ([a-zA-Z0-9_.:-]{1,64})$', text, re.M)
    interface = match[1] if match else ''
    return snapshot[0] == unit_bytes(' --xray /usr/local/lib/velum/xray' in text, interface)


def ready():
    token, _ = read_file(CONFIG / 'token', private=True, limit=257)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for _ in range(50):
        try:
            request = urllib.request.Request('http://127.0.0.1:27841/v1/status',
                                             headers={'Authorization': 'Bearer ' + token.decode().strip()})
            with opener.open(request, timeout=1) as response:
                if response.status == 200 and json.load(response).get('tunAllowed') is True:
                    return
        except (OSError, ValueError):
            pass
        time.sleep(.1)
    raise InstallError('Service did not expose its authenticated API; installation will be rolled back')


def transact(args, script):
    # All target directories and objects must be checked before stopping a service.
    handles = []
    def pin(path):
        handle = Directory(path)
        handles.append(handle)
        return handle
    try:
        parent, units, policies = pin(BASE.parent), pin(UNIT.parent), pin(POLICY.parent)
        config_parent = pin(CONFIG.parent)
        old_tree = None
        if parent.exists(BASE.name):
            handle, old_tree = tree(BASE)
            handles.append(handle)
        config = pin(CONFIG) if config_parent.exists(CONFIG.name) else None
        old_unit, old_policy = units.snapshot(UNIT.name), policies.snapshot(POLICY.name)
        old_token = config.snapshot('token') if config else None
        if old_unit and not owned_unit(old_unit):
            raise InstallError('Existing velum.service is not managed by this installer')
        if old_tree is not None and (not old_unit or not {'velumd', 'sing-box', 'install-service.sh', 'uninstall-service.sh'} <= set(old_tree)):
            raise InstallError('Existing service directory has no verifiable Velum installation; review manually')
        if old_token and (not old_unit or old_token[1] != 0o600):
            raise InstallError('Existing system token is not a private Velum service token')
        if old_policy:
            expected_policy = (old_tree or {}).get('app.velum.service.policy')
            if expected_policy is None:
                # Legacy installer stored the original policy only in /usr/share.
                expected_policy = read_file(layout(script)['app.velum.service.policy'],
                                            owners=(0, args.uid), source=True)
            if old_policy[0] != expected_policy[0]:
                raise InstallError('Existing Polkit policy is not managed by this installer')

        if args.action in ('start', 'stop', 'restart', 'status'):
            if old_tree is None or not old_unit or not old_token:
                raise InstallError('Not a verified, complete Velum service installation')
            systemctl(args.action, 'velum.service', *(['--no-pager'] if args.action == 'status' else []))
            return

        if args.action == 'uninstall':
            if not old_unit and old_tree is None and not old_token and not old_policy:
                print('Velum service is already absent.')
                return
            if old_tree is None or not old_unit:
                raise InstallError('Incomplete installation: refusing automatic removal of unowned files')
            was_active = systemctl('is-active', '--quiet', 'velum.service', check=False)
            was_enabled = systemctl('is-enabled', '--quiet', 'velum.service', check=False)
            saved_name = '.velum-remove-' + secrets.token_hex(12)
            moved = False
            recovery = RecoveryBackup(config_parent, {'unit': old_unit, 'policy': old_policy, 'token': old_token},
                                      {'action': 'uninstall', 'active': was_active, 'enabled': was_enabled,
                                       'binary_backup': str(parent.path / saved_name)})
            handles.append(recovery.directory)
            try:
                systemctl('disable', '--now', 'velum.service')
                os.rename(BASE.name, saved_name, src_dir_fd=parent.fd, dst_dir_fd=parent.fd)
                moved = True
                units.restore(UNIT.name, None)
                policies.restore(POLICY.name, None)
                if config:
                    config.restore('token', None)
                systemctl('daemon-reload')
            except BaseException as error:
                try:
                    if moved:
                        os.rename(saved_name, BASE.name, src_dir_fd=parent.fd, dst_dir_fd=parent.fd)
                    units.restore(UNIT.name, old_unit)
                    policies.restore(POLICY.name, old_policy)
                    if config:
                        config.restore('token', old_token)
                    systemctl('daemon-reload')
                    systemctl('enable' if was_enabled else 'disable', 'velum.service')
                    if was_active:
                        systemctl('start', 'velum.service')
                        ready()
                except BaseException as rollback_error:
                    raise InstallError(f'{error}; UNINSTALL ROLLBACK INCOMPLETE: {rollback_error}. Review {BASE}, {parent.path / saved_name} and private originals {recovery.directory.path}') from error
                clear_recovery(recovery)
                raise
            clear_recovery(recovery)
            # Commit precedes deleting any binary. Delete only the validated
            # leaf set, never rm -rf or unrelated files under /etc/velum.
            try:
                remove_tree(parent, saved_name)
            except (OSError, InstallError) as error:
                print(f'Velum: service removed; old binary backup retained at {parent.path / saved_name}: {error}', file=sys.stderr)
            if config:
                try:
                    os.rmdir(CONFIG.name, dir_fd=config_parent.fd)
                except OSError:
                    pass  # Preserve extra data, without expanding removal scope.
            systemctl('reset-failed', 'velum.service', check=False)
            print('Velum service removed. GUI files and token are preserved.')
            return

        if args.interface is None and old_unit:
            import re
            previous = re.search(r'^ExecStart=.* --interface ([a-zA-Z0-9_.:-]{1,64})$', old_unit[0].decode(), re.M)
            args.interface = previous[1] if previous else ''
        sources = layout(script)
        if args.bin_dir:
            for name in ('velumd', 'sing-box', 'xray'):
                sources[name] = Path(args.bin_dir) / name
        payload = {}
        installed_source = Path(script).parent == BASE
        for name, path in sources.items():
            try:
                payload[name] = read_file(path, owners=(0,) if installed_source else (0, args.uid),
                                          executable=name != 'app.velum.service.policy', source=not installed_source)
            except FileNotFoundError:
                if name != 'xray':
                    raise
        if old_tree and 'xray' in old_tree and 'xray' not in payload:
            raise InstallError('Xray companion is installed but absent from update; refusing to silently remove XHTTP support')
        token, _ = read_file(args.token_file, owners=(args.uid,), private=True, source=True, limit=257)
        token = token.strip()
        if not 32 <= len(token) <= 255 or any(c < 33 or c > 126 for c in token):
            raise InstallError('GUI token must contain 32..255 printable non-space bytes')
        was_active = systemctl('is-active', '--quiet', 'velum.service', check=False)
        was_enabled = systemctl('is-enabled', '--quiet', 'velum.service', check=False)
        if not args.no_start and not was_active:
            with socket.socket() as listener:
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    listener.bind(('127.0.0.1', 27841))
                except OSError as error:
                    raise InstallError('Port 27841 is occupied; no other process will be stopped') from error
        stage_name = '.velum-install-' + secrets.token_hex(12)
        saved_name = '.velum-backup-' + secrets.token_hex(12)
        os.mkdir(stage_name, 0o700, dir_fd=parent.fd)
        stage = pin(parent.path / stage_name)
        moved_old = published = config_created = touched = False
        recovery = None
        try:
            hashes = {}
            for name, (data, _) in payload.items():
                stage.write(name, data, 0o644 if name == 'app.velum.service.policy' else 0o755)
                hashes[name] = hashlib.sha256(data).hexdigest()
            manifest = {'format': 1, 'files': hashes, 'gui_uid': args.uid}
            stage.write('manifest.json', json.dumps(manifest, sort_keys=True).encode() + b'\n', 0o644)
            os.fchmod(stage.fd, 0o755)
            recovery = RecoveryBackup(config_parent, {'unit': old_unit, 'policy': old_policy, 'token': old_token},
                                      {'action': 'install', 'active': was_active, 'enabled': was_enabled,
                                       'config_existed': config is not None, 'stage': str(stage.path),
                                       'binary_backup': str(parent.path / saved_name)})
            handles.append(recovery.directory)
            if was_active:
                systemctl('stop', 'velum.service')
            touched = True
            if old_tree is not None:
                os.rename(BASE.name, saved_name, src_dir_fd=parent.fd, dst_dir_fd=parent.fd)
                moved_old = True
            os.rename(stage_name, BASE.name, src_dir_fd=parent.fd, dst_dir_fd=parent.fd)
            published = True
            if config is None:
                os.mkdir(CONFIG.name, 0o700, dir_fd=config_parent.fd)
                config_created = True
                config = pin(CONFIG)
            config.write('token', token + b'\n', 0o600)
            units.write(UNIT.name, unit_bytes('xray' in payload, args.interface), 0o644)
            policies.write(POLICY.name, payload['app.velum.service.policy'][0], 0o644)
            systemctl('daemon-reload')
            if not args.no_start:
                systemctl('enable', 'velum.service')
                systemctl('start', 'velum.service')
                ready()
        except BaseException as error:
            rollback_errors = []
            if touched:
                # Do not replace/delete files under a process we failed to stop.
                try:
                    systemctl('stop', 'velum.service')
                    if published:
                        remove_tree(parent, BASE.name)
                    if moved_old:
                        os.rename(saved_name, BASE.name, src_dir_fd=parent.fd, dst_dir_fd=parent.fd)
                    units.restore(UNIT.name, old_unit)
                    policies.restore(POLICY.name, old_policy)
                    if config:
                        config.restore('token', old_token)
                    if config_created:
                        os.rmdir(CONFIG.name, dir_fd=config_parent.fd)
                    systemctl('daemon-reload')
                    systemctl('enable' if was_enabled else 'disable', 'velum.service')
                    if was_active:
                        systemctl('start', 'velum.service')
                        ready()
                except BaseException as rollback_error:
                    rollback_errors.append(str(rollback_error))
            if parent.exists(stage_name):
                remove_tree(parent, stage_name)
            if rollback_errors:
                raise InstallError(f'{error}; ROLLBACK INCOMPLETE: {rollback_errors}. Review {BASE} and retained backups at {parent.path / saved_name}; private originals at {recovery.directory.path} for manual recovery') from error
            clear_recovery(recovery)
            raise
        clear_recovery(recovery)
        if moved_old:
            try:
                remove_tree(parent, saved_name)
            except (OSError, InstallError) as error:
                print(f'Velum: installation committed, but old backup retained at {parent.path / saved_name}: {error}', file=sys.stderr)
        print(f'Velum system service installed for UID {args.uid}.' +
              (' Service not started.' if args.no_start else ' Authenticated API ready; VPN not connected.'))
    finally:
        for handle in reversed(handles):
            handle.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('install', 'uninstall', 'start', 'stop', 'restart', 'status'))
    parser.add_argument('--user', default=os.environ.get('PKEXEC_UID') or os.environ.get('SUDO_USER'))
    parser.add_argument('--config-dir')
    parser.add_argument('--token-file')
    parser.add_argument('--bin-dir')
    parser.add_argument('--interface')
    parser.add_argument('--no-start', action='store_true')
    args = parser.parse_args()
    os.umask(0o077)
    def interrupted(signum, _frame):
        signal.signal(signum, signal.SIG_IGN)
        raise InstallError('Installation interrupted; rolling back completed changes')
    signal.signal(signal.SIGTERM, interrupted)
    if sys.platform != 'linux' or os.geteuid() != 0:
        raise InstallError('Run as root through the reviewed installer / Polkit')
    if not Path('/run/systemd/system').is_dir():
        raise InstallError('An active systemd system manager is required')
    if args.action == 'install':
        if not args.user:
            raise InstallError('Specify the unprivileged GUI user with --user')
        user = pwd.getpwuid(int(args.user)) if args.user.isdigit() else pwd.getpwnam(args.user)
        args.uid = user.pw_uid
        if not args.uid or not user.pw_dir.startswith('/') or user.pw_dir == '/':
            raise InstallError('An unprivileged GUI user with an absolute home is required')
        args.token_file = args.token_file or str(Path(args.config_dir or (Path(user.pw_dir) / '.config/velum')) / 'token')
        for path in (args.token_file, args.bin_dir, args.config_dir):
            if path and (not Path(path).is_absolute() or '..' in Path(path).parts):
                raise InstallError('All supplied paths must be absolute without ..')
        if not stat.S_ISCHR(os.stat('/dev/net/tun').st_mode):
            raise InstallError('/dev/net/tun is unavailable')
        if args.interface and (len(args.interface) > 64 or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-' for c in args.interface)):
            raise InstallError('Invalid interface name')
        if args.interface:
            socket.if_nametoindex(args.interface)
    else:
        args.uid = 0
        if any((args.user, args.config_dir, args.token_file, args.bin_dir, args.interface, args.no_start)):
            # PKEXEC_UID/SUDO_USER are normal on control invocations.
            if any((args.config_dir, args.token_file, args.bin_dir, args.interface, args.no_start)):
                raise InstallError('Install options are not accepted for service control')
    run = Directory('/run')
    try:
        lock = os.open('velum-install.lock', os.O_WRONLY | os.O_CREAT | os.O_NONBLOCK | NOFOLLOW, 0o600, dir_fd=run.fd)
        try:
            check_info(os.fstat(lock), '/run/velum-install.lock', (0,), private=True)
            check_acl(lock, '/run/velum-install.lock')
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise InstallError('Another Velum install/removal/control operation is running') from error
            transact(args, os.path.abspath(__file__))
        finally:
            os.close(lock)
    finally:
        run.close()


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, InstallError) as error:
        print(f'Velum: {error}', file=sys.stderr)
        sys.exit(1)

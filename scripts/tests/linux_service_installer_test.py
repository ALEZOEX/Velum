#!/usr/bin/python3
"""Run ONLY through test-linux-service-installer.sh in its disposable namespaces."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('installer', '/run/source/scripts/linux_service_installer.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
BASE = installer.BASE
UNIT = installer.UNIT
POLICY = installer.POLICY


class InstallerTest(unittest.TestCase):
    def setUp(self):
        # The launcher masks these paths with a private tmpfs chroot. Never offer an
        # environment switch to redirect the privileged production installer.
        self.assertEqual(os.geteuid(), 0)
        status = Path('/proc/self/status').read_text()
        capabilities = int(status.split('CapEff:')[1].splitlines()[0], 16)
        self.assertTrue(capabilities & 1, 'Fixture needs CAP_CHOWN: ' + status + Path('/proc/self/uid_map').read_text())
        self.assertTrue(Path('/run/source/scripts/tests/linux_service_installer_test.py').is_file())
        self.assertFalse(Path('/etc/os-release').exists())
        # Private namespace parents may inherit a restrictive umask. Make only
        # tmpfs ancestors searchable so refusal is tested inside the installer.
        for folder in ('/', '/usr', '/tmp', '/home', '/run', '/etc'):
            self.assertEqual(Path(folder).stat().st_dev, Path('/').stat().st_dev)
            os.chmod(folder, 0o755)
        for folder in ('/etc/systemd/system', '/run/systemd/system', '/home/gui/.config/velum'):
            Path(folder).mkdir(parents=True, exist_ok=True)
        Path('/etc/passwd').write_text('root:x:0:0:root:/root:/bin/bash\ngui:x:1000:1000:GUI:/home/gui:/bin/bash\n')
        Path('/etc/group').write_text('root:x:0:\ngui:x:1000:\n')
        for folder in ('/home/gui', '/home/gui/.config', '/home/gui/.config/velum'):
            os.chown(folder, 1000, 1000)
            os.chmod(folder, 0o700)
        self.token = Path('/home/gui/.config/velum/token')
        self.token.write_text('a' * 64 + '\n')
        os.chown(self.token, 1000, 1000)
        os.chmod(self.token, 0o600)
        self.repo = Path('/tmp/repository with spaces')
        shutil.copytree('/run/source/scripts', self.repo / 'scripts')
        shutil.copytree('/run/source/packaging/linux', self.repo / 'packaging/linux')
        (self.repo / 'bin').mkdir()
        for name in ('velumd', 'sing-box', 'xray'):
            (self.repo / 'bin' / name).write_bytes(b'#!/bin/false\nINERT ' + name.encode())
            os.chmod(self.repo / 'bin' / name, 0o755)
        self.script = self.repo / 'scripts/install-linux-service.sh'
        self.environment = dict(os.environ, PKEXEC_UID='1000', HOME='/untrusted-root-home', PATH='/does-not-exist', PYTHONPATH='/untrusted')
        self.environment.pop('SUDO_USER', None)
        self.environment.pop('BASH_ENV', None)

    def tearDown(self):
        subprocess.run(['/usr/bin/systemctl', 'stop', 'velum.service'], check=True)
        # Test-only cleanup of the private filesystem, never production cleanup.
        for path in (BASE, Path('/etc/velum'), self.repo):
            if path.is_symlink():
                path.unlink()
            elif path.exists():
                shutil.rmtree(path)
        for path in (UNIT, POLICY):
            path.unlink(missing_ok=True)
        shutil.rmtree('/home/gui')
        for path in Path('/etc').glob('.velum-recovery-*'):
            shutil.rmtree(path)
        for path in Path('/run').glob('*'):
            if path.is_file():
                path.unlink()
        for path in Path('/usr/local/lib').iterdir():
            if path.is_dir():
                shutil.rmtree(path)
        for path in Path('/tmp').iterdir():
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()

    def invoke(self, *args, success=True, script=None):
        result = subprocess.run(['/bin/bash', str(script or self.script), *args], env=self.environment,
                                cwd='/', capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def snapshot(self):
        result = {}
        for root in (BASE, Path('/etc/velum')):
            if root.exists():
                for file in root.rglob('*'):
                    info = file.lstat()
                    result[str(file)] = (hashlib.sha256(file.read_bytes()).hexdigest(), info.st_uid, stat.S_IMODE(info.st_mode))
        for file in (UNIT, POLICY):
            if file.exists():
                info = file.stat()
                result[str(file)] = (hashlib.sha256(file.read_bytes()).hexdigest(), info.st_uid, stat.S_IMODE(info.st_mode))
        return result

    def calls(self):
        file = Path('/run/systemctl-calls')
        return [json.loads(x) for x in file.read_text().splitlines()] if file.exists() else []

    def test_repository_install_and_installed_reinstall_without_bin_dir(self):
        self.invoke()
        before = self.snapshot()
        self.invoke(script=BASE / 'install-service.sh')
        self.assertEqual(before, self.snapshot())
        self.assertEqual((BASE / 'xray').read_bytes(), (self.repo / 'bin/xray').read_bytes())
        self.assertIn('--xray /usr/local/lib/velum/xray', UNIT.read_text())
        self.assertEqual((Path('/etc/velum/token')).read_bytes(), self.token.read_bytes())
        self.assertTrue(Path('/run/active').exists())
        self.assertTrue(Path('/run/enabled').exists())
        self.assertEqual(stat.S_IMODE(Path('/etc/velum').stat().st_mode), 0o700)
        self.assertFalse(list(BASE.parent.glob('.velum-*')))
        self.assertFalse(list(Path('/etc').glob('.velum-recovery-*')))

    def test_control_install_token_override_and_reinstall(self):
        self.invoke('--no-start')
        custom = self.token.parent / 'custom-token'
        custom.write_text('b' * 64)
        os.chown(custom, 1000, 1000)
        os.chmod(custom, 0o600)
        self.invoke('install', '--token-file', str(custom), script=BASE / 'velum-service-control')
        self.assertEqual(Path('/etc/velum/token').read_text(), 'b' * 64 + '\n')

    def test_repository_upgrade_and_remove(self):
        self.invoke()
        (self.repo / 'bin/sing-box').write_bytes(b'UPGRADED inert core')
        self.invoke()
        self.assertEqual((BASE / 'sing-box').read_bytes(), b'UPGRADED inert core')
        extra = Path('/etc/velum/user-notes')
        extra.write_text('keep me')
        self.invoke('uninstall', script=BASE / 'velum-service-control')
        self.assertFalse(BASE.exists())
        self.assertFalse(UNIT.exists())
        self.assertFalse(POLICY.exists())
        self.assertEqual(extra.read_text(), 'keep me')
        self.assertEqual(self.token.read_text(), 'a' * 64 + '\n')
        self.assertFalse(Path('/run/active').exists())
        self.assertFalse(Path('/run/enabled').exists())
        self.invoke(script=self.repo / 'scripts/uninstall-linux-service.sh')

    def test_missing_required_payload_fails_before_stopping_old_service(self):
        self.invoke()
        before = self.snapshot()
        calls = self.calls()
        (self.repo / 'packaging/linux/velum-service-control').unlink()
        self.invoke(success=False)
        self.assertEqual(before, self.snapshot())
        self.assertEqual(calls, self.calls())

    def test_failed_start_rolls_back_files_policy_token_and_enabled_state(self):
        self.invoke()
        before = self.snapshot()
        (self.repo / 'bin/velumd').write_bytes(b'new inert daemon')
        with (self.repo / 'packaging/linux/app.velum.service.policy').open('a') as policy:
            policy.write('\n<!-- updated reviewed policy -->\n')
        self.token.write_text('b' * 64)
        Path('/run/fail-start').touch()
        self.invoke(success=False)
        self.assertEqual(before, self.snapshot())
        self.assertTrue(Path('/run/active').exists())
        self.assertTrue(Path('/run/enabled').exists())
        self.invoke()
        self.assertEqual((BASE / 'velumd').read_bytes(), b'new inert daemon')

    def test_first_install_reload_failure_rolls_back_everything(self):
        Path('/run/fail-daemon-reload').touch()
        self.invoke(success=False)
        self.assertEqual({}, self.snapshot())
        self.assertFalse(Path('/etc/velum').exists())
        self.assertFalse(Path('/run/active').exists())
        self.assertFalse(Path('/run/enabled').exists())
        self.assertFalse(list(BASE.parent.glob('.velum-*')))
        self.assertFalse(list(Path('/etc').glob('.velum-recovery-*')))
        self.invoke('--no-start')

    def test_no_start_does_not_start_a_service(self):
        self.invoke('--no-start')
        self.assertFalse(any(x[0] == 'start' for x in self.calls()))
        self.assertFalse(Path('/run/active').exists())

    def test_refuses_symlink_or_hardlink_source_before_systemctl(self):
        binary = self.repo / 'bin/sing-box'
        outside = Path('/tmp/outside')
        binary.rename(outside)
        binary.symlink_to(outside)
        self.invoke(success=False)
        binary.unlink()
        os.link(outside, binary)
        self.invoke(success=False)
        self.assertEqual(self.calls(), [])
        self.assertFalse(BASE.exists())
        self.assertIn(b'INERT', outside.read_bytes())

    def test_refuses_symlink_component(self):
        binaries = self.repo / 'bin'
        binaries.rename(self.repo / 'real-bin')
        binaries.symlink_to(self.repo / 'real-bin', target_is_directory=True)
        self.invoke(success=False)
        self.assertEqual(self.calls(), [])

    def test_refuses_unsafe_existing_binary_without_repair(self):
        self.invoke('--no-start')
        os.chmod(BASE / 'velumd', 0o777)
        before = self.snapshot()
        calls = self.calls()
        self.invoke(success=False)
        self.invoke('uninstall', script=BASE / 'velum-service-control', success=False)
        self.assertEqual(before, self.snapshot())
        self.assertEqual(calls, self.calls())

    def test_refuses_foreign_file_in_tree_without_deletion(self):
        self.invoke('--no-start')
        (BASE / 'foreign-file').write_text('foreign')
        before = self.snapshot()
        calls = self.calls()
        self.invoke(script=self.repo / 'scripts/uninstall-linux-service.sh', success=False)
        self.invoke(success=False)
        self.assertEqual(before, self.snapshot())
        self.assertEqual(calls, self.calls())

    def test_refuses_untrusted_tree_owner_and_symlink_target(self):
        BASE.mkdir()
        os.chown(BASE, 1000, 1000)
        self.invoke(success=False)
        self.assertEqual(BASE.stat().st_uid, 1000)
        BASE.rmdir()
        BASE.symlink_to(self.repo, target_is_directory=True)
        self.invoke(success=False)
        self.assertTrue(BASE.is_symlink())
        self.assertTrue(self.script.exists())
        self.assertEqual(self.calls(), [])

    def test_refuses_token_symlink_without_touching_target(self):
        self.token.unlink()
        outside = Path('/tmp/secret')
        outside.write_text('private external data')
        self.token.symlink_to(outside)
        self.invoke(success=False)
        self.assertEqual(outside.read_text(), 'private external data')
        self.assertFalse(BASE.exists())
        self.assertEqual(self.calls(), [])

    def test_refuses_foreign_unit_and_policy(self):
        UNIT.write_text('[Service]\nExecStart=/bin/false\n')
        self.invoke(success=False)
        self.assertIn('/bin/false', UNIT.read_text())
        UNIT.unlink()
        POLICY.write_text('foreign policy')
        self.invoke(success=False)
        self.assertEqual(POLICY.read_text(), 'foreign policy')
        self.assertEqual(self.calls(), [])

    def test_partial_staging_write_failure_leaves_running_install_unchanged(self):
        self.invoke()
        before = self.snapshot()
        calls = self.calls()
        args = installer.argparse.Namespace(action='install', uid=1000, token_file=str(self.token),
                                            bin_dir=None, interface='', no_start=False)
        original = installer.Directory.write
        def fail_second(directory, name, *values):
            if directory.path.name.startswith('.velum-install-') and name == 'sing-box':
                raise OSError('injected second binary write failure')
            return original(directory, name, *values)
        with mock.patch.object(installer.Directory, 'write', fail_second):
            with self.assertRaisesRegex(OSError, 'second binary'):
                installer.transact(args, str(self.repo / 'scripts/linux_service_installer.py'))
        self.assertEqual(before, self.snapshot())
        self.assertEqual(calls, self.calls()[:-2])  # Only read-only state queries.
        self.assertTrue(Path('/run/active').exists())
        self.assertFalse(list(BASE.parent.glob('.velum-*')))
        self.assertFalse(list(Path('/etc').glob('.velum-recovery-*')))

    def test_uninstall_reload_failure_restores_service_and_all_files(self):
        self.invoke()
        before = self.snapshot()
        Path('/run/fail-daemon-reload').touch()
        self.invoke('uninstall', script=BASE / 'velum-service-control', success=False)
        self.assertEqual(before, self.snapshot())
        self.assertTrue(Path('/run/active').exists())
        self.assertTrue(Path('/run/enabled').exists())
        self.assertFalse(list(BASE.parent.glob('.velum-*')))
        self.assertFalse(list(Path('/etc').glob('.velum-recovery-*')))
        self.invoke('uninstall', script=BASE / 'velum-service-control')

    def test_token_publication_failure_restores_previous_installation(self):
        self.invoke()
        before = self.snapshot()
        args = installer.argparse.Namespace(action='install', uid=1000, token_file=str(self.token),
                                            bin_dir=None, interface='', no_start=False)
        original = installer.Directory.write
        failed = False
        def fail_token(directory, name, *values):
            nonlocal failed
            if not failed and directory.path == installer.CONFIG and name == 'token':
                failed = True
                raise OSError('injected token publication failure')
            return original(directory, name, *values)
        with mock.patch.object(installer.Directory, 'write', fail_token):
            with self.assertRaisesRegex(OSError, 'token publication'):
                installer.transact(args, str(self.repo / 'scripts/linux_service_installer.py'))
        self.assertEqual(before, self.snapshot())
        self.assertTrue(Path('/run/active').exists())
        self.assertFalse(list(BASE.parent.glob('.velum-*')))
        self.assertFalse(list(Path('/etc').glob('.velum-recovery-*')))

    def test_extended_acl_rejected_without_repair(self):
        self.invoke('--no-start')
        import struct
        # POSIX ACL: owner rwx, named GUI rwx, group r-x, mask rwx, other r-x.
        acl = struct.pack('<I', 2)
        for tag, perm, uid in ((1, 7, 0xffffffff), (2, 7, 1000), (4, 5, 0xffffffff),
                               (16, 7, 0xffffffff), (32, 5, 0xffffffff)):
            acl += struct.pack('<HHI', tag, perm, uid)
        os.setxattr(BASE / 'velumd', 'system.posix_acl_access', acl)
        before = os.getxattr(BASE / 'velumd', 'system.posix_acl_access')
        self.invoke(success=False)
        self.assertEqual(os.getxattr(BASE / 'velumd', 'system.posix_acl_access'), before)

    def test_installed_token_hardlink_is_rejected_without_touching_outside(self):
        self.invoke('--no-start')
        outside = Path('/tmp/token-hardlink')
        os.link('/etc/velum/token', outside)
        before = outside.read_bytes()
        calls = self.calls()
        self.invoke(success=False)
        self.invoke('uninstall', script=BASE / 'velum-service-control', success=False)
        self.assertEqual(outside.read_bytes(), before)
        self.assertEqual(calls, self.calls())

    def test_reinstall_preserves_outbound_interface(self):
        self.invoke('--interface', 'lo', '--no-start')
        before = UNIT.read_bytes()
        self.invoke('--no-start', script=BASE / 'install-service.sh')
        self.assertEqual(UNIT.read_bytes(), before)

    def test_missing_xray_in_upgrade_is_not_silently_removed(self):
        self.invoke('--no-start')
        before = self.snapshot()
        (self.repo / 'bin/xray').unlink()
        self.invoke('--no-start', success=False)
        self.assertEqual(before, self.snapshot())

    def test_non_root_invocation_changes_nothing(self):
        result = subprocess.run(['/bin/bash', str(self.script)], user=1000, group=1000,
                                env=self.environment, cwd='/', capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('root', result.stderr)
        self.assertEqual(self.snapshot(), {})
        self.assertEqual(self.calls(), [])

    def test_occupied_api_port_does_not_stop_other_process(self):
        import socket
        with socket.socket() as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(('127.0.0.1', 27841))
            listener.listen()
            result = self.invoke(success=False)
            self.assertIn('occupied', result.stderr)
            self.assertEqual(self.snapshot(), {})
            self.assertFalse(any(x[0] in ('stop', 'disable', 'start') for x in self.calls()))
            self.assertEqual(listener.getsockname(), ('127.0.0.1', 27841))

    def test_incomplete_rollback_preserves_private_original_token_and_files(self):
        self.invoke()
        original_token = Path('/etc/velum/token').read_bytes()
        original_unit = UNIT.read_bytes()
        self.token.write_text('b' * 64)
        args = installer.argparse.Namespace(action='install', uid=1000, token_file=str(self.token),
                                            bin_dir=None, interface='', no_start=False)
        original = installer.Directory.write
        publication_failed = False
        def fail_publication_and_rollback(directory, name, *values):
            nonlocal publication_failed
            if directory.path == UNIT.parent and name == UNIT.name and not publication_failed:
                publication_failed = True
                raise OSError('injected unit publication error')
            if publication_failed and directory.path == installer.CONFIG and name == 'token':
                raise OSError('injected persistent token restore failure')
            return original(directory, name, *values)
        with mock.patch.object(installer.Directory, 'write', fail_publication_and_rollback):
            with self.assertRaisesRegex(installer.InstallError, 'ROLLBACK INCOMPLETE') as error:
                installer.transact(args, str(self.repo / 'scripts/linux_service_installer.py'))
        backups = list(Path('/etc').glob('.velum-recovery-*'))
        self.assertEqual(len(backups), 1)
        backup = backups[0]
        self.assertIn(str(backup), str(error.exception))
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o700)
        self.assertEqual((backup / 'token').read_bytes(), original_token)
        self.assertEqual((backup / 'unit').read_bytes(), original_unit)
        self.assertEqual(stat.S_IMODE((backup / 'token').stat().st_mode), 0o600)
        self.assertEqual(backup.stat().st_uid, 0)
        self.assertFalse(Path('/run/active').exists())
        self.assertEqual(json.loads((backup / 'state.json').read_text())['active'], True)

    def test_legacy_installation_can_be_upgraded_without_manifest(self):
        self.invoke('--no-start')
        (BASE / 'manifest.json').unlink()
        (BASE / 'app.velum.service.policy').unlink()
        self.invoke('--no-start')
        self.assertTrue((BASE / 'manifest.json').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2, failfast=True)

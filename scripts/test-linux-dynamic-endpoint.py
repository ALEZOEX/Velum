"""Real DNS and VPN endpoint tests; user/net/mount/PID namespaces only."""

import importlib.util
import ipaddress
import json
import os
import secrets
import signal
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('velum_network', ROOT / 'scripts/test-linux-network.py')
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)


class DNS(socketserver.ThreadingUDPServer):
    daemon_threads = True

    def __init__(self):
        self.lock = threading.Lock()
        self.records = ['198.18.0.2']
        self.mode = 'ok'
        self.ttl = 1
        self.queries = []
        super().__init__(('127.0.0.53', 53), DNSHandler)

    def set(self, records=None, mode='ok'):
        with self.lock:
            if records is not None:
                self.records = records
            self.mode = mode


class DNSHandler(socketserver.BaseRequestHandler):
    def handle(self):
        query, sock = self.request
        if len(query) < 17:
            return
        pos = 12
        while pos < len(query) and query[pos]:
            pos += query[pos] + 1
        end = pos + 5
        if end > len(query):
            return
        kind = struct.unpack('!H', query[pos + 1 : pos + 3])[0]
        with self.server.lock:
            records = self.server.records.copy()
            mode = self.server.mode
            ttl = self.server.ttl
            self.server.queries.append((time.monotonic(), kind, mode))
        if mode == 'timeout':
            return
        rcode = {'ok': 0, 'servfail': 2, 'nxdomain': 3}[mode]
        addresses = []
        if rcode == 0:
            for record in records:
                addr = ipaddress.ip_address(record)
                if (addr.version, kind) in [(4, 1), (6, 28)]:
                    addresses.append(addr.packed)
        answer = query[:2] + struct.pack('!HHHHH', 0x8180 | rcode, 1, len(addresses), 0, 0) + query[12:end]
        for addr in addresses:
            answer += bytes([192, 12]) + struct.pack('!HHIH', kind, 1, ttl, len(addr)) + addr
        sock.sendto(answer, self.client_address)


def wait(check, timeout=12):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            result = check()
            if result:
                return result
        except (OSError, ValueError):
            pass
        time.sleep(0.05)
    raise AssertionError('F10 controlled state transition timed out')


def isolated(baseline):
    if (
        os.geteuid() != 0
        or any(
            os.readlink('/proc/self/ns/' + kind) == os.environ['VELUM_F10_HOST_' + kind.upper() + 'NS']
            for kind in ['net', 'mnt', 'pid']
        )
        or {r['ifname'] for r in json.loads(lab.run('ip', '-j', 'link'))} != {'lo'}
    ):
        raise RuntimeError('F10 fixture requires fresh network, mount and PID namespaces')
    resolver = Path('/etc/resolv.conf').resolve()
    lab.run('mount', '--make-rprivate', '/')
    lab.run('mount', '-t', 'tmpfs', '-o', 'mode=0755', 'tmpfs', '/run')
    if str(resolver).startswith('/run/'):
        resolver.parent.mkdir(parents=True, exist_ok=True)
        resolver.touch()
    assert resolver.is_file()
    with tempfile.TemporaryDirectory(prefix='velum-f10-') as tmp:
        folder = Path(tmp)
        resolv = folder / 'resolv.conf'
        resolv.write_text('nameserver 127.0.0.53\noptions attempts:1 timeout:1\n')
        lab.run('mount', '--bind', str(resolv), str(resolver))
        lab.run('ip', 'link', 'set', 'lo', 'up')
        dns = DNS()
        threading.Thread(target=dns.serve_forever, daemon=True).start()
        subprocess.run(
            [
                'openssl',
                'req',
                '-x509',
                '-newkey',
                'ec',
                '-pkeyopt',
                'ec_paramgen_curve:P-256',
                '-nodes',
                '-keyout',
                str(folder / 'key.pem'),
                '-out',
                str(folder / 'cert.pem'),
                '-days',
                '1',
                '-subj',
                '/CN=Velum F10',
                '-addext',
                'subjectAltName=DNS:localhost,IP:198.18.0.2,IP:1.1.1.1',
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        keys = lab.run(str(lab.CORE), 'generate', 'reality-keypair').splitlines()
        private = next(x.split(':', 1)[1].strip() for x in keys if x.startswith('PrivateKey:'))
        public = next(x.split(':', 1)[1].strip() for x in keys if x.startswith('PublicKey:'))
        (folder / 'reality-private').write_text(private)
        env = dict(
            os.environ,
            VELUM_TEST_ENDPOINT_LISTEN='::',
            SSL_CERT_FILE=str(folder / 'cert.pem'),
            DBUS_SYSTEM_BUS_ADDRESS='unix:path=/nonexistent-velum-f10-bus',
        )
        peer = subprocess.Popen(
            ['unshare', '--net', sys.executable, str(ROOT / 'scripts/test-linux-network.py'), '--peer', tmp],
            env=env,
        )
        daemon = None
        try:
            wait(lambda: os.readlink(f'/proc/{peer.pid}/ns/net') != os.readlink('/proc/self/ns/net'))
            lab.run('ip', 'link', 'set', 'lo', 'up')
            lab.run('ip', 'link', 'add', 'lab0', 'type', 'veth', 'peer', 'name', 'lab1')
            lab.run('ip', 'link', 'set', 'lab1', 'netns', str(peer.pid))

            def remote(*args):
                return lab.run('nsenter', '-t', str(peer.pid), '-n', '--', *args)

            remote('ip', 'link', 'set', 'lo', 'up')
            remote('ip', 'link', 'set', 'lab1', 'up')
            for addr, dev in [
                ('198.18.0.3/24', 'lab1'),
                ('198.18.0.2/24', 'lab1'),
                ('198.19.0.2/32', 'lo'),
                ('198.20.0.2/32', 'lo'),
                ('1.1.1.1/32', 'lo'),
            ]:
                remote('ip', 'addr', 'add', addr, 'dev', dev)
            for addr, dev in [
                ('fd00:18::2/64', 'lab1'),
                ('fd00:18::3/64', 'lab1'),
                ('fd00:19::2/128', 'lo'),
                ('fd00:20::2/128', 'lo'),
            ]:
                remote('ip', '-6', 'addr', 'add', addr, 'dev', dev, 'nodad')
            lab.run('ip', 'link', 'set', 'lab0', 'up')
            lab.run('ip', 'addr', 'add', '198.18.0.1/24', 'dev', 'lab0')
            lab.run('ip', '-6', 'addr', 'add', 'fd00:18::1/64', 'dev', 'lab0', 'nodad')
            lab.run('ip', 'route', 'add', 'default', 'via', '198.18.0.2')
            lab.run('ip', '-6', 'route', 'add', 'default', 'via', 'fd00:18::2')
            for family in ['-4', '-6']:
                lab.run('ip', family, 'rule', 'add', 'pref', '9000', 'table', '2022')
            (folder / 'network-ready').touch()
            wait(lambda: (folder / 'peer-ready').exists())
            wait(lambda: 'tentative' not in lab.run('ip', '-6', 'addr', 'show', 'dev', 'lab0'))
            original = lab.routing_snapshot()
            token = secrets.token_hex(32)
            tokenfile = folder / 'token'
            tokenfile.write_text(token)
            tokenfile.chmod(0o600)
            log = (folder / 'daemon.log').open('w')

            def start_daemon():
                process = subprocess.Popen(
                    [
                        str(lab.DAEMON),
                        '--tun',
                        '--core',
                        str(lab.CORE),
                        '--xray',
                        str(lab.XRAY),
                        '--token-file',
                        str(tokenfile),
                    ],
                    env=env,
                    stdout=log,
                    stderr=log,
                )
                try:
                    lab.wait_for(lambda: api('status'), process)
                    return process
                except BaseException:
                    lab.stop(process)
                    raise

            def api(path, body=None, expected=200):
                request = urllib.request.Request(
                    'http://127.0.0.1:27841/v1/' + path,
                    data=None if body is None else json.dumps(body).encode(),
                    headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
                )
                try:
                    with lab.HTTP.open(request, timeout=25) as response:
                        code, payload = response.status, json.load(response)
                except urllib.error.HTTPError as e:
                    code, payload = e.code, json.load(e)
                assert code == expected, (path, code, payload)
                return payload

            def connect(protocol='hy2', host='endpoint.velum.test', **settings):
                if protocol == 'hy2':
                    uri = f'hy2://velum-local-test@{host}:8443?sni=localhost'
                else:
                    port, transport = (8444, 'tcp') if protocol == 'vision' else (8445, 'xhttp')
                    uri = (
                        f'vless://00000000-0000-4000-8000-000000000001@{host}:{port}?'
                        f'security=reality&type={transport}&sni=localhost&pbk={public}&sid=abcd'
                    )
                    uri += (
                        '&flow=xtls-rprx-vision' if protocol == 'vision' else '&path=%2Fxhttp-test&mode=auto'
                    )
                result = api('connect', {'uri': uri, 'settings': settings})
                assert result['state'] == 'running', result
                return result

            def disconnect(snapshot=original):
                assert api('disconnect', {})['state'] == 'disconnected'
                assert lab.routing_snapshot() == snapshot, 'Disconnect did not restore fixture rules/routes'

            def data(label, family=4):
                origin = '198.19.0.2' if family == 4 else 'fd00:19::2'
                response = lab.http_proof(origin, label)
                assert response == {'peer': origin, 'path': '/' + label}, response

            def endpoint():
                return api('status')['endpoint']

            def route_device(target, uid=0):
                return json.loads(lab.run('ip', '-j', 'route', 'get', target, 'uid', str(uid)))[0]['dev']

            daemon = start_daemon()
            for family, ipv6 in [(4, True)] if baseline else [(4, True), (6, True), (6, False)]:
                old, new = ('198.18.0.2', '198.18.0.3') if family == 4 else ('fd00:18::2', 'fd00:18::3')
                old_cidr = old + ('/24' if family == 4 else '/64')
                for protocol in ['hy2', 'vision', 'xhttp'] if ipv6 else ['hy2']:
                    label = f'{protocol}-v{family}-appv6-{ipv6}'
                    dns.set([old])
                    connect(protocol, ipv6=ipv6)
                    data(label)
                    before = lab.routing_snapshot()
                    queries = len(dns.queries)
                    dns.set([new])
                    if baseline:
                        time.sleep(2.2)
                        data(label + '-pinned')
                        assert len(dns.queries) == queries
                        assert lab.routing_snapshot() == before
                        print('BASELINE', label, 'TTL expired; numeric pin and routes unchanged', flush=True)
                    else:
                        state = wait(lambda: (s := endpoint())['needsReconnect'] and s)
                        assert state['ip'] == old and state['answers'] == [new], state
                        assert lab.routing_snapshot() == before, 'DNS refresh mutated live routes'
                        data(label + '-protected')
                        remote('ip', 'addr', 'del', old_cidr, 'dev', 'lab1')
                        try:
                            switched = api('reconnect', {})
                            assert switched['endpoint']['ip'] == new, switched
                            assert route_device(new) == 'lab0'
                            if ipv6:
                                assert route_device(new, uid=65534) == 'velum0'
                                assert route_device(old) == 'velum0'
                                data(label + '-new-v6', family=6)
                            else:
                                denied = subprocess.run(
                                    ['ip', '-6', 'route', 'get', new, 'uid', '65534'],
                                    env=dict(os.environ, LC_ALL='C'),
                                    check=False,
                                    capture_output=True,
                                    text=True,
                                )
                                assert denied.returncode != 0 and 'unreachable' in denied.stderr.lower(), (
                                    denied
                                )
                                try:
                                    lab.http_proof('fd00:19::2', 'blocked', timeout=2)
                                except OSError:
                                    pass
                                else:
                                    raise AssertionError('Application IPv6 escaped disabled TUN')
                            data(label + '-new')
                        finally:
                            remote(
                                'ip',
                                'addr',
                                'add',
                                old_cidr,
                                'dev',
                                'lab1',
                                *(['nodad'] if family == 6 else []),
                            )
                        print('PASS', label, 'new endpoint only, data and kernel path verified', flush=True)
                    disconnect()

            if baseline:
                return

            old, new, v6 = '198.18.0.2', '198.18.0.3', 'fd00:18::2'
            dns.set([old])
            connect()
            before = lab.routing_snapshot()
            dns.set([new, v6, old])
            state = wait(lambda: (s := endpoint())['answers'] == [old, new, v6] and s)
            assert state['ip'] == old and not state['needsReconnect'], state
            assert lab.routing_snapshot() == before
            query_times = [t for t, kind, _ in dns.queries if kind == 1]
            assert query_times[-1] - query_times[-2] >= 4.9, query_times[-2:]
            data('multiple-answers')
            withdrawn = []
            try:
                for previous, target in [(old, new), (new, v6)]:
                    remote('ip', 'addr', 'del', previous + '/24', 'dev', 'lab1')
                    withdrawn.append(previous)
                    switched = api('reconnect', {})['endpoint']
                    assert switched['ip'] == target and switched['answers'] == [old, new, v6], switched
                    assert route_device(target) == 'lab0'
                    assert route_device(target, uid=65534) == 'velum0'
                    data('multiple-answers-' + target.replace(':', '-'))
            finally:
                for address in reversed(withdrawn):
                    remote('ip', 'addr', 'add', address + '/24', 'dev', 'lab1')
            disconnect()
            print('PASS multiple A/AAAA, TTL polling floor, rotation to live IPv4 then IPv6', flush=True)

            for failure in ['timeout', 'servfail', 'nxdomain']:
                dns.set([old])
                connect()
                before = lab.routing_snapshot()
                dns.set(mode=failure)
                state = wait(lambda: (s := endpoint())['dnsErrors'] > 0 and s)
                assert state['ip'] == old and state['message'], state
                assert lab.routing_snapshot() == before
                data(failure + '-keeps-transport')
                dns.set([old])
                wait(lambda: endpoint()['dnsErrors'] == 0, timeout=25)
                assert not endpoint()['message'] and lab.routing_snapshot() == before
                data(failure + '-recovered')
                disconnect()
                print('PASS active connection and DNS recovery after', failure, flush=True)

            dns.set(mode='nxdomain')
            queries = len(dns.queries)
            connect(host=old)
            time.sleep(6)
            assert endpoint()['ip'] == old and endpoint()['expiresAt'] is None
            assert len(dns.queries) == queries
            data('literal-without-dns')
            disconnect()
            print('PASS literal endpoint uses no DNS', flush=True)

            dns.set([old])
            connect(reconnect=True)
            dns.set(mode='timeout')
            queries = len(dns.queries)
            with ThreadPoolExecutor(max_workers=1) as pool:
                request = pool.submit(api, 'reconnect', {}, 409)
                wait(lambda start=queries: len(dns.queries) > start)
                assert api('status')['endpoint']['ip'] == old
                disconnect()
                assert request.result(timeout=5)['error']
            assert api('status')['state'] == 'disconnected' and lab.routing_snapshot() == original
            print('PASS disconnect cancels outstanding reconnect DNS', flush=True)

            dns.set([old])
            connect()
            for family in ['-4', '-6']:
                lab.run('ip', family, 'rule', 'add', 'pref', '27841', 'protocol', '250', 'table', '12022')
            before = lab.routing_snapshot()
            dns.set([new])
            wait(lambda: endpoint()['needsReconnect'])
            assert lab.routing_snapshot() == before
            refused = api('reconnect', {}, expected=400)
            assert refused['error'] and refused['state'] != 'running', refused
            after = lab.routing_snapshot()
            for family in ['-4', '-6']:
                assert any(row.startswith(family + 'rule') and '12022' in row for row in after)
                lab.run('ip', family, 'rule', 'del', 'pref', '27841', 'protocol', '250', 'table', '12022')
            assert lab.routing_snapshot() == original
            connect()
            data('recovered-after-conflict')
            disconnect()
            print('PASS both families preserve foreign rules and recover after refusal', flush=True)

            lab.run('ip', 'link', 'add', 'lab2', 'type', 'veth', 'peer', 'name', 'lab3')
            try:
                lab.run('ip', 'link', 'set', 'lab3', 'netns', str(peer.pid))
                lab.run('ip', 'link', 'set', 'lab2', 'up')
                remote('ip', 'link', 'set', 'lab3', 'up')
                lab.run('ip', 'addr', 'add', '198.21.0.1/24', 'dev', 'lab2')
                remote('ip', 'addr', 'add', '198.21.0.2/24', 'dev', 'lab3')
                wait(lambda: 'tentative' not in lab.run('ip', '-6', 'addr', 'show', 'dev', 'lab2'))
                dns.set([old])
                assert connect()['endpoint']['interface'] == 'lab0'
                lab.run('ip', 'route', 'add', old + '/32', 'via', '198.21.0.2', 'dev', 'lab2')
                before = lab.routing_snapshot()
                wait(lambda: endpoint()['needsReconnect'])
                assert lab.routing_snapshot() == before
                assert api('reconnect', {})['endpoint']['interface'] == 'lab2'
                assert route_device(old) == 'lab2'
                data('new-uplink')
                assert api('disconnect', {})['state'] == 'disconnected'
                assert route_device(old) == 'lab2', 'Velum removed a foreign main-table host route'
            finally:
                lab.run('ip', 'link', 'del', 'lab2')
            assert lab.routing_snapshot() == original
            print(
                'PASS interface change detected, data across new veth, external route preserved', flush=True
            )

            for sig in [signal.SIGTERM, signal.SIGKILL]:
                dns.set([old])
                connect()
                dns.set(mode='timeout')
                queries = len(dns.queries)
                wait(lambda start=queries: len(dns.queries) > start)
                daemon.send_signal(sig)
                rc = daemon.wait(timeout=12)
                assert rc == (0 if sig == signal.SIGTERM else -signal.SIGKILL), rc
                wait(lambda: lab.routing_snapshot() == original)
                dns.set([new])
                daemon = start_daemon()
                assert connect()['endpoint']['ip'] == new
                data('restart-' + sig.name)
                disconnect()
                print(
                    'PASS',
                    sig.name,
                    'during DNS refresh; routes restored, fresh process sends data',
                    flush=True,
                )
        except BaseException:
            print(
                'DNS fixture queries:',
                dns.queries,
                'resolver:',
                Path('/etc/resolv.conf').read_text(),
                file=sys.stderr,
            )
            if (folder / 'daemon.log').exists():
                print((folder / 'daemon.log').read_text()[-7000:], file=sys.stderr)
            raise
        finally:
            lab.stop(daemon)
            lab.stop(peer)
            dns.shutdown()
            dns.server_close()


if __name__ == '__main__':
    if '--isolated' in sys.argv:
        isolated('--baseline' in sys.argv)
    else:
        if os.geteuid() == 0 or not __debug__:
            sys.exit('F10 fixture requires an unprivileged user and enabled assertions')
        env = dict(
            os.environ,
            VELUM_F10_HOST_NETNS=os.readlink('/proc/self/ns/net'),
            VELUM_F10_HOST_MNTNS=os.readlink('/proc/self/ns/mnt'),
            VELUM_F10_HOST_PIDNS=os.readlink('/proc/self/ns/pid'),
        )
        subprocess.run(
            [
                'unshare',
                '--user',
                '--map-root-user',
                '--mount',
                '--net',
                '--pid',
                '--fork',
                '--mount-proc',
                '--kill-child=KILL',
                sys.executable,
                str(Path(__file__).resolve()),
                '--isolated',
            ]
            + (['--baseline'] if '--baseline' in sys.argv else []),
            env=env,
            check=True,
            timeout=360,
        )

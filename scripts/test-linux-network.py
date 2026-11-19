#!/usr/bin/env python3
"""Exercise the real daemon and Hysteria2 in disposable Linux network namespaces."""
import base64
import contextlib
import http.server
import ipaddress
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
CORE = Path(os.environ.get('VELUM_TEST_CORE', ROOT / 'bin/sing-box'))
DAEMON = Path(os.environ.get('VELUM_TEST_DAEMON', ROOT / 'bin/velumd'))
XRAY = ROOT / 'bin/xray'
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def wait_for(check, process=None):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if process is not None and process.poll() is not None:
            raise RuntimeError('Test process exited early')
        try:
            result = check()
            if result:
                return result
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(.1)
    raise TimeoutError('Timed out waiting for test service')


def routing_snapshot():
    result=[]
    for version in ['-4', '-6']:
        for kind in ['rule', 'route']:
            args=['ip', '-j', '-N', version, kind, 'show']
            if kind == 'route': args+=['table', 'all']
            result += [version+kind+json.dumps(x, sort_keys=True) for x in json.loads(run(*args))]
    return sorted(result)


def reverse_path_drops():
    rows=Path('/proc/net/netstat').read_text().splitlines()
    for names, values in zip(rows[::2], rows[1::2]):
        names, values=names.split(), values.split()
        if 'IPReversePathFilter' in names:
            return int(values[names.index('IPReversePathFilter')])
    raise RuntimeError('Kernel lacks reverse path diagnostic counter')


def read_exact(sock, count):
    data=b''
    while len(data)<count:
        part=sock.recv(count-len(data))
        if not part: raise EOFError('Short DNS response')
        data+=part
    return data


def http_proof(address, path, timeout=5):
    host=f'[{address}]' if ':' in address else address
    with HTTP.open(f'http://{host}:8080/{path}', timeout=timeout) as response:
        return json.load(response)


def record_routing(peer_pid, label):
    print('DIAG', label, json.dumps(routing_snapshot()), flush=True)
    for version, target, source in [('-4', '198.19.0.2', '198.18.0.1'), ('-6', 'fd00:19::2', 'fd00:18::1')]:
        for extra in [[], ['oif', 'lab0'], ['from', source]]:
            print('DIAG client route', version, extra, run('ip', version, 'route', 'get', target, *extra), flush=True)
        print('DIAG server return', source, run('nsenter', '-t', str(peer_pid), '-n', '--', 'ip', version, 'route', 'get', source), flush=True)


@contextlib.contextmanager
def capture_packets(folder, peer_pid):
    captures=[]
    try:
        # Ubuntu tcpdump defaults to an unmapped service UID. Keep namespace UID0;
        # the wrapper already isolates user/net/mount/PID and maps no host root.
        for name, prefix in [('client', []), ('peer', ['nsenter', '-t', str(peer_pid), '-n', '--'])]:
            path=folder/(name+'-packets.log')
            with path.open('w') as f:
                process=subprocess.Popen(prefix+['tcpdump', '-Z', 'root', '-l', '-n', '-tt', '-i', 'any', 'tcp port 8080'], stdout=f, stderr=subprocess.STDOUT)
            captures.append((name, process, path))
        time.sleep(.2)
        for _, process, _ in captures:
            if process.poll() is not None: raise RuntimeError('Packet capture failed')
        yield
    finally:
        for name, process, path in captures:
            stop(process)
            print('DIAG packets', name, path.read_text(), flush=True)


class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = json.dumps({'peer': self.client_address[0], 'path': self.path}).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


class DoH(Origin):
    def do_POST(self):
        query = self.rfile.read(int(self.headers['Content-Length']))
        self.reply(query)

    def do_GET(self):
        encoded = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)['dns'][0]
        self.reply(base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4)))

    def reply(self, query):
        end = 12
        while query[end]:
            end += query[end] + 1
        end += 1
        qtype = struct.unpack('!H', query[end:end + 2])[0]
        question = query[12:end + 4]
        address = {'A': '198.19.0.2', 'AAAA': 'fd00:19::2'}['AAAA' if qtype == 28 else 'A']
        packed = ipaddress.ip_address(address).packed
        answer = b'\xc0\x0c' + struct.pack('!HHIH', qtype, 1, 30, len(packed)) + packed
        data = query[:2] + struct.pack('!HHHHH', 0x8180, 1, 1, 0, 0) + question + answer
        self.send_response(200)
        self.send_header('Content-Type', 'application/dns-message')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def peer(folder):
    wait_for(lambda: (folder / 'network-ready').exists())
    processes = []
    servers = []
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        class IPv6Server(http.server.ThreadingHTTPServer):
            address_family = socket.AF_INET6
        for cls, address in [(http.server.ThreadingHTTPServer, (ip, 8080)) for ip in ['198.19.0.2', '198.20.0.2']] + [(IPv6Server, (ip, 8080)) for ip in ['fd00:19::2', 'fd00:20::2']]:
            server = cls(address, Origin)
            servers.append(server)
            threading.Thread(target=server.serve_forever, daemon=True).start()
        dns = http.server.ThreadingHTTPServer(('1.1.1.1', 443), DoH)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(folder / 'cert.pem', folder / 'key.pem')
        dns.socket = context.wrap_socket(dns.socket, server_side=True)
        servers.append(dns)
        threading.Thread(target=dns.serve_forever, daemon=True).start()
        cfg = {'log': {'level': 'info'}, 'inbounds': [
            {'type': 'hysteria2', 'listen': os.environ.get('VELUM_TEST_ENDPOINT_LISTEN', '198.18.0.2'), 'listen_port': 8443, 'users': [{'password': 'velum-local-test'}], 'tls': {'enabled': True, 'certificate_path': str(folder / 'cert.pem'), 'key_path': str(folder / 'key.pem')}},
            {'type': 'http', 'listen': '127.0.0.1', 'listen_port': 9443, 'tls': {'enabled': True, 'certificate_path': str(folder / 'cert.pem'), 'key_path': str(folder / 'key.pem')}}
        ], 'outbounds': [{'type': 'direct'}]}
        cfg['inbounds'].append({'type': 'vless', 'listen': os.environ.get('VELUM_TEST_ENDPOINT_LISTEN', '198.18.0.2'), 'listen_port': 8444, 'users': [{'uuid': '00000000-0000-4000-8000-000000000001', 'flow': 'xtls-rprx-vision'}], 'tls': {'enabled': True, 'server_name': 'localhost', 'reality': {'enabled': True, 'private_key': (folder / 'reality-private').read_text(), 'short_id': ['abcd'], 'handshake': {'server': '127.0.0.1', 'server_port': 9443}}}})
        path = folder / 'server.json'
        path.write_text(json.dumps(cfg))
        with (folder / 'server.log').open('w') as log:
            process = subprocess.Popen([str(CORE), 'run', '-c', str(path)], stdout=log, stderr=log)
            processes.append(process)
            time.sleep(.3)
            if process.poll() is not None:
                raise RuntimeError((folder / 'server.log').read_text())
            xray_cfg = {
                'log': {'loglevel': 'debug'},
                'inbounds': [{'listen': os.environ.get('VELUM_TEST_ENDPOINT_LISTEN', '198.18.0.2'), 'port': 8445, 'protocol': 'vless',
                    'settings': {'clients': [{'id': '00000000-0000-4000-8000-000000000001'}], 'decryption': 'none'},
                    'streamSettings': {'network': 'xhttp', 'security': 'reality',
                        'realitySettings': {'show': True, 'dest': '127.0.0.1:9443', 'serverNames': ['localhost'],
                            'privateKey': (folder / 'reality-private').read_text(), 'shortIds': ['abcd']},
                        'xhttpSettings': {'path': '/xhttp-test', 'mode': 'auto'}}}],
                'outbounds': [{'protocol': 'freedom', 'tag': 'direct', 'settings': {'finalRules': [{'action': 'allow', 'ip': ['198.19.0.0/24', 'fd00:19::/64', '1.1.1.1/32']}]}}],
            }
            xray_path = folder / 'xray-server.json'
            xray_path.write_text(json.dumps(xray_cfg))
            with (folder / 'xray-server.log').open('w') as xray_log:
                xray_server = subprocess.Popen([str(XRAY), 'run', '-c', str(xray_path)], stdout=xray_log, stderr=xray_log)
                processes.append(xray_server)
                time.sleep(.3)
                if xray_server.poll() is not None:
                    raise RuntimeError((folder / 'xray-server.log').read_text())
            (folder / 'peer-ready').touch()
            process.wait()
    finally:
        for process in processes:
            stop(process)
        for server in servers:
            server.server_close()


def isolated():
    assert os.geteuid() == 0, 'Run through user namespace wrapper'
    assert os.readlink('/proc/self/ns/net') != os.environ['VELUM_NETWORK_HOST_NETNS']
    assert os.readlink('/proc/self/ns/mnt') != os.environ['VELUM_NETWORK_HOST_MNTNS']
    run('mount', '--make-rprivate', '/')
    run('mount', '-t', 'tmpfs', '-o', 'mode=0755', 'tmpfs', '/run')
    assert {link['ifname'] for link in json.loads(run('ip', '-j', 'link'))} == {'lo'}, 'Refusing to change a nonempty network namespace'
    with tempfile.TemporaryDirectory(prefix='velum-network-') as tmp:
        folder = Path(tmp)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes', '-keyout', str(folder / 'key.pem'), '-out', str(folder / 'cert.pem'), '-days', '1', '-subj', '/CN=Velum network test', '-addext', 'subjectAltName=DNS:localhost,IP:198.18.0.2,IP:1.1.1.1'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        keys = run(str(CORE), 'generate', 'reality-keypair').splitlines()
        private = next(line.split(':', 1)[1].strip() for line in keys if line.startswith('PrivateKey:'))
        public = next(line.split(':', 1)[1].strip() for line in keys if line.startswith('PublicKey:'))
        (folder / 'reality-private').write_text(private)
        peer_process = subprocess.Popen(['unshare', '--net', sys.executable, str(Path(__file__).resolve()), '--peer', tmp])
        daemon = None
        try:
            # Wait for unshare to enter its network namespace before moving the link.
            wait_for(lambda: os.readlink(f'/proc/{peer_process.pid}/ns/net') != os.readlink('/proc/self/ns/net'), peer_process)
            run('ip', 'link', 'set', 'lo', 'up')
            run('ip', 'link', 'add', 'lab0', 'type', 'veth', 'peer', 'name', 'lab1')
            run('ip', 'link', 'set', 'lab1', 'netns', str(peer_process.pid))
            def remote(*args):
                return run('nsenter', '-t', str(peer_process.pid), '-n', '--', *args)
            for command in [('ip', 'link', 'set', 'lo', 'up'), ('ip', 'link', 'set', 'lab1', 'up'), ('ip', 'addr', 'add', '198.18.0.2/24', 'dev', 'lab1'), ('ip', 'addr', 'add', '198.19.0.2/32', 'dev', 'lo'), ('ip', 'addr', 'add', '1.1.1.1/32', 'dev', 'lo'), ('ip', '-6', 'addr', 'add', 'fd00:18::2/64', 'dev', 'lab1', 'nodad'), ('ip', '-6', 'addr', 'add', 'fd00:19::2/128', 'dev', 'lo', 'nodad')]:
                remote(*command)
            remote('ip', 'addr', 'add', '198.20.0.2/32', 'dev', 'lo')
            remote('ip', '-6', 'addr', 'add', 'fd00:20::2/128', 'dev', 'lo', 'nodad')
            run('ip', 'link', 'set', 'lab0', 'up')
            for n in ['all', 'lab0']:
                Path('/proc/sys/net/ipv4/conf/' + n + '/rp_filter').write_text('1')
            run('ip', 'addr', 'add', '198.18.0.1/24', 'dev', 'lab0')
            run('ip', '-6', 'addr', 'add', 'fd00:18::1/64', 'dev', 'lab0', 'nodad')
            run('ip', 'route', 'add', 'default', 'via', '198.18.0.2')
            run('ip', '-6', 'route', 'add', 'default', 'via', 'fd00:18::2')
            (folder / 'network-ready').touch()
            wait_for(lambda: (folder / 'peer-ready').exists(), peer_process)
            # Auto-created IPv6 link-local addresses finish DAD asynchronously.
            # Snapshot only stable fixture state; do not mistake kernel DAD for a TUN leak.
            wait_for(lambda: 'tentative' not in run('ip', '-6', 'addr', 'show', 'dev', 'lab0'))
            wait_for(lambda: 'tentative' not in remote('ip', '-6', 'addr', 'show', 'dev', 'lab1'))
            baseline = routing_snapshot()
            token = secrets.token_hex(32)
            token_path = folder / 'token'
            token_path.write_text(token)
            token_path.chmod(0o600)
            env = dict(os.environ, SSL_CERT_FILE=str(folder / 'cert.pem'), DBUS_SYSTEM_BUS_ADDRESS='unix:path=/nonexistent-velum-lab-bus')
            with (folder / 'daemon.log').open('w') as log:
                daemon = subprocess.Popen([str(DAEMON), '--tun', '--interface', 'lab0', '--core', str(CORE), '--xray', str(XRAY), '--token-file', str(token_path)], env=env, stdout=log, stderr=log)
            def api(path, body=None):
                req = urllib.request.Request('http://127.0.0.1:27841/v1/' + path, data=None if body is None else json.dumps(body).encode(), headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
                with HTTP.open(req, timeout=20) as response:
                    return json.load(response)
            wait_for(lambda: api('status'), daemon)
            result = api('connect', {'uri': 'hy2://velum-local-test@198.18.0.2:8443?sni=localhost'})
            assert result['state'] == 'running', result
            for address in ('198.19.0.2', 'fd00:19::2'):
                route = run('ip', '-6' if ':' in address else '-4', 'route', 'get', address)
                assert 'velum0' in route, route
                url = f'http://[{address}]:8080/proof' if ':' in address else f'http://{address}:8080/proof'
                with HTTP.open(url, timeout=8) as response:
                    data = json.load(response)
                assert data['peer'] not in ('198.18.0.1', 'fd00:18::1'), data
                print(f'PASS TUN HTTP {address}: tunnel egress {data["peer"]}', flush=True)
            for qtype, address in [(1, '198.19.0.2'), (28, 'fd00:19::2')]:
                query = b'VT' + struct.pack('!HHHHH', 0x100, 1, 0, 0, 0) + b'\x06origin\x05velum\x04test\0' + struct.pack('!HH', qtype, 1)
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as dns:
                    dns.settimeout(8)
                    dns.sendto(query, ('192.0.2.53', 53))
                    answer, _ = dns.recvfrom(4096)
                assert answer[:2] == b'VT' and struct.unpack('!H', answer[6:8])[0] == 1, answer.hex()
                assert ipaddress.ip_address(address).packed in answer, answer.hex()
                print(f'PASS TUN DNS type {qtype}: hijack -> proxy DoH -> {address}', flush=True)
            assert api('disconnect', {})['state'] == 'disconnected'
            wait_for(lambda: 'velum0' not in run('ip', '-j', 'link'))
            assert routing_snapshot() == baseline, 'Policy rules/routes not restored: extra=' + str(set(routing_snapshot())-set(baseline)) + '; missing=' + str(set(baseline)-set(routing_snapshot()))
            print('PASS disconnect: TUN removed, IPv4/IPv6 policy rules restored', flush=True)
            assert api('connect', {'uri': 'hy2://velum-local-test@198.18.0.2:8443?sni=localhost', 'exclusions': ['198.19.0.0/24', '198.19.0.0/25', '198.19.0.2/32', 'fd00:19::/64', 'fd00:19::/96', 'fd00:19::2/128']})['state'] == 'running'
            print('DIAG strict rp_filter:', {n: Path('/proc/sys/net/ipv4/conf/' + n + '/rp_filter').read_text().strip() for n in ['all', 'lab0']}, flush=True)
            before_rpf = reverse_path_drops()
            record_routing(peer_process.pid, 'direct CIDR active')
            with capture_packets(folder, peer_process.pid):
                for address, expected in [('198.19.0.2', '198.18.0.1'), ('fd00:19::2', 'fd00:18::1')]:
                    proof = http_proof(address, 'direct')
                    assert proof['peer'] == expected, proof
                    print(f'PASS CIDR direct {address}: physical egress {expected}', flush=True)
            assert reverse_path_drops() == before_rpf, 'Strict reverse-path validation dropped direct replies'
            for address in ['198.20.0.2', 'fd00:20::2']:
                proof = http_proof(address, 'nonexcluded')
                assert proof['peer'] == address, proof
                print(f'PASS nonexcluded {address}: VPN egress', flush=True)
            # Even DNS addresses inside excluded CIDRs must retain hijack precedence.
            for family, dns_host in [(socket.AF_INET, '198.19.0.53'), (socket.AF_INET6, 'fd00:19::53')]:
                for stream in [False, True]:
                    query = b'DR' + struct.pack('!HHHHH', 0x100, 1, 0, 0, 0) + b'\x06origin\x05velum\x04test\0' + struct.pack('!HH', 1, 1)
                    with socket.socket(family, socket.SOCK_STREAM if stream else socket.SOCK_DGRAM) as dns:
                        dns.settimeout(5)
                        dns.connect((dns_host, 53))
                        dns.sendall(struct.pack('!H', len(query)) + query if stream else query)
                        if stream:
                            n = struct.unpack('!H', read_exact(dns, 2))[0]
                            answer = read_exact(dns, n)
                        else:
                            answer = dns.recv(4096)
                    assert answer[:2] == b'DR' and ipaddress.ip_address('198.19.0.2').packed in answer, answer.hex()
                    print(f'PASS excluded DNS {dns_host} {"TCP" if stream else "UDP"}: hijack retained', flush=True)
            # Removing only our fixture's physical defaults must fail direct, never loop/fallback to VPN.
            for version, gateway, target, source in [('-4', '198.18.0.2', '198.19.0.2', '198.18.0.1'), ('-6', 'fd00:18::2', 'fd00:19::2', 'fd00:18::1')]:
                run('ip', version, 'route', 'del', 'default', 'via', gateway, 'dev', 'lab0')
                try:
                    route = subprocess.run(['ip', version, 'route', 'get', target, 'from', source], capture_output=True, text=True)
                    assert route.returncode != 0 and 'unreachable' in route.stderr.lower(), route
                    started = time.monotonic()
                    with capture_packets(folder, peer_process.pid):
                        try:
                            http_proof(target, 'unreachable', timeout=8)
                        except TimeoutError:
                            raise AssertionError('Core did not report direct route failure')
                        except OSError:
                            pass
                        else:
                            raise AssertionError('Missing direct route fell back to proxy')
                    assert time.monotonic() - started < 7, 'Direct route failure exceeded bounded core dial timeout'
                    proof = http_proof('198.20.0.2' if version == '-4' else 'fd00:20::2', 'still-vpn')
                    assert proof['peer'] in ['198.20.0.2', 'fd00:20::2'], proof
                    print(f'PASS unavailable direct route {version}: bounded failure, VPN retained', flush=True)
                finally:
                    run('ip', version, 'route', 'add', 'default', 'via', gateway, 'dev', 'lab0')
            assert api('disconnect', {})['state'] == 'disconnected'
            wait_for(lambda: 'velum0' not in run('ip', '-j', 'link'))
            assert routing_snapshot() == baseline, 'extra=' + str(set(routing_snapshot())-set(baseline)) + '; missing=' + str(set(baseline)-set(routing_snapshot()))
            assert api('connect', {'uri': 'hy2://velum-local-test@198.18.0.2:8443?sni=localhost',
                'exclusions': ['198.19.0.0/24', 'fd00:19::/64'], 'settings': {'routeMode': 'rules', 'rules': [
                    {'action': 'block', 'type': 'cidr', 'value': '198.19.0.2/32'},
                    {'action': 'block', 'type': 'cidr', 'value': 'fd00:19::2/128'}]}})['state'] == 'running'
            for address in ['198.19.0.2', 'fd00:19::2']:
                try:
                    http_proof(address, 'must-block', timeout=3)
                except OSError:
                    pass
                else:
                    raise AssertionError('Kernel direct rules bypassed higher-priority block')
            print('PASS block rules retain precedence over CIDR exclusions', flush=True)
            assert api('disconnect', {})['state'] == 'disconnected'
            assert routing_snapshot() == baseline, 'extra=' + str(set(routing_snapshot())-set(baseline)) + '; missing=' + str(set(baseline)-set(routing_snapshot()))
            vless = f'vless://00000000-0000-4000-8000-000000000001@198.18.0.2:8444?security=reality&type=tcp&sni=localhost&pbk={public}&sid=abcd&flow=xtls-rprx-vision'
            assert api('connect', {'uri': vless})['state'] == 'running'
            with HTTP.open('http://198.19.0.2:8080/vless', timeout=8) as response:
                proof = json.load(response)
                assert proof['peer'] == '198.19.0.2', proof
            print('PASS VLESS Reality + Vision: actual TUN HTTP egress verified', flush=True)

            assert api('disconnect', {})['state'] == 'disconnected'
            wait_for(lambda: 'velum0' not in run('ip', '-j', 'link'))
            xhttp = f'vless://00000000-0000-4000-8000-000000000001@198.18.0.2:8445?security=reality&type=xhttp&sni=localhost&pbk={public}&sid=abcd&path=%2Fxhttp-test&mode=auto&fp=chrome'
            assert api('connect', {'uri': xhttp})['state'] == 'running'
            with HTTP.open('http://198.19.0.2:8080/xhttp', timeout=12) as response:
                proof = json.load(response)
                assert proof['peer'] == '198.19.0.2', proof
            print('PASS VLESS XHTTP + Reality: real Xray bridge and TUN HTTP egress verified', flush=True)

            daemon.terminate()
            daemon.wait(timeout=10)
            wait_for(lambda: 'velum0' not in run('ip', '-j', 'link'))
            assert routing_snapshot() == baseline, 'Policy rules/routes not restored: extra=' + str(set(routing_snapshot())-set(baseline)) + '; missing=' + str(set(baseline)-set(routing_snapshot()))
            print('PASS SIGTERM: child stopped, TUN and policy rules removed', flush=True)
        except Exception:
            try:
                print('Core diagnostic entries:', json.dumps(api('logs')), file=sys.stderr)
            except Exception:
                pass
            for proc in Path('/proc').iterdir():
                if not proc.name.isdigit(): continue
                try:
                    if os.readlink(proc / 'ns/net') == os.readlink('/proc/self/ns/net'):
                        held = [str(fd) for fd in (proc / 'fd').iterdir() if os.readlink(fd) == '/dev/net/tun']
                        if held: print('TUN holder:', proc.name, (proc / 'comm').read_text().strip(), held, file=sys.stderr)
                except (OSError, PermissionError): pass
            print('Links at failure:', run('ip', '-j', 'link'), file=sys.stderr)
            print('Rules at failure:', run('ip', 'rule'), file=sys.stderr)
            for name in ('daemon.log', 'server.log', 'xray-server.log'):
                path = folder / name
                if path.exists():
                    print(f'{name}:\n{path.read_text()[-6000:]}', file=sys.stderr)
            raise
        finally:
            stop(daemon)
            stop(peer_process)


if __name__ == '__main__':
    if sys.argv[1:] == ['--isolated']:
        isolated()
    elif len(sys.argv) == 3 and sys.argv[1] == '--peer':
        peer(Path(sys.argv[2]))
    else:
        if not XRAY.is_file():
            raise SystemExit('Build the pinned Xray companion first: make xray')
        if sys.platform != 'linux':
            raise SystemExit('This test requires Linux')
        os.environ['VELUM_NETWORK_HOST_NETNS'] = os.readlink('/proc/self/ns/net')
        os.environ['VELUM_NETWORK_HOST_MNTNS'] = os.readlink('/proc/self/ns/mnt')
        subprocess.run(['unshare', '--user', '--map-root-user', '--mount', '--net', '--pid', '--fork', '--mount-proc', '--kill-child=KILL', sys.executable, str(Path(__file__).resolve()), '--isolated'], check=True, timeout=90)

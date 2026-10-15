#!/usr/bin/env python3
"""Native camera service and authenticated gateway, isolated TLS camera peer.
Public test certificates and synthetic codes only. No printer/device access.
"""
import argparse
import contextlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import select
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests/fixtures/tls'
sys.path.insert(0, str(ROOT / 'tests/legacy'))
sys.path.insert(0, str(ROOT / 'tests'))
from check_printer_dashboard import test_auth, authenticate
spec = importlib.util.spec_from_file_location('printer_dashboard_camera', ROOT / 'tests/legacy/printer_dashboard.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
GATE = 'synthetic-local-camera-capability-for-tests'
JPEG = (ROOT / 'examples/printer-dashboard/demo-camera.jpg').read_bytes()


def exact(conn, size):
    data = bytearray()
    while len(data) < size:
        part = conn.recv(size - len(data))
        if not part:
            raise EOFError()
        data.extend(part)
    return bytes(data)


def wait(predicate, seconds=8):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        if predicate():
            return
        time.sleep(.04)
    raise AssertionError('camera condition did not arrive')


class Peer:
    def __init__(self, mode='normal'):
        self.mode = mode
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen()
        self.listener.settimeout(.2)
        self.port = self.listener.getsockname()[1]
        self.stopping = threading.Event()
        self.starts = self.active = 0
        self.errors, self.connections, self.threads = [], [], []
        self.lock = threading.Lock()
        self.acceptor = threading.Thread(target=self.accept, daemon=True)
        self.acceptor.start()

    def accept(self):
        while not self.stopping.is_set():
            try:
                raw, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            worker = threading.Thread(target=self.serve, args=(raw,), daemon=True)
            self.threads.append(worker)
            worker.start()

    def serve(self, raw):
        counted = False
        try:
            raw.settimeout(3)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(FIXTURES / 'servercert.pem', FIXTURES / 'serverkey.pem')
            with context.wrap_socket(raw, server_side=True) as conn:
                self.connections.append(conn)
                assert exact(conn, 80) == (struct.pack('<IIII', 64, 12288, 0, 0) + b'bblp'.ljust(32, b'\0') + b'test-only'.ljust(32, b'\0'))
                with self.lock:
                    self.starts += 1
                    self.active += 1
                    generation = self.starts
                    counted = True
                if self.mode == 'oversize':
                    conn.sendall(struct.pack('<IIII', 4194305, 0, 0, 0))
                    return
                if self.mode == 'badjpeg':
                    conn.sendall(struct.pack('<IIII', 4, 0, 0, 0) + b'bad!')
                    return
                if self.mode == 'short':
                    conn.sendall(struct.pack('<IIII', 100, 0, 0, 0) + b'\xff\xd8short')
                    return
                if self.mode == 'stall':
                    conn.sendall(b'\x00\x01')
                    while not self.stopping.is_set():
                        if select.select([conn], [], [], .1)[0] and not conn.recv(1):
                            return
                    return
                label = f'native-generation-{generation}'.encode()
                image = JPEG[:-2] + b'\xff\xfe' + struct.pack('!H', len(label) + 2) + label + JPEG[-2:]
                if self.mode == 'large':
                    image = b'\xff\xd8' + b'x' * (4194304 - 4) + b'\xff\xd9'
                wire = struct.pack('<IIII', len(image), 7, 9, 11) + image
                while not self.stopping.is_set():
                    if self.mode == 'normal':
                        for byte in wire[:16]:
                            conn.sendall(bytes([byte]))
                        for at in range(16, len(wire), 4093):
                            conn.sendall(wire[at:at + 4093])
                    else:
                        conn.sendall(wire)
                    if select.select([conn], [], [], .1)[0]:
                        assert conn.recv(1) == b'', 'camera received unexpected control data'
                        return
        except (ssl.SSLError, ConnectionError, EOFError, OSError):
            raw.close()
        except BaseException as exc:
            self.errors.append(repr(exc))
        finally:
            if counted:
                with self.lock:
                    self.active -= 1

    def close(self):
        self.stopping.set()
        self.listener.close()
        for conn in self.connections:
            with contextlib.suppress(OSError):
                conn.shutdown(socket.SHUT_RDWR)
        self.acceptor.join(3)
        for worker in self.threads:
            worker.join(4)
            assert not worker.is_alive()
        assert not self.errors, self.errors


class Service:
    def __init__(self, binary, peer, harts, identity='server.example'):
        self.process = subprocess.Popen([str(binary), '127.0.0.1', str(peer.port), identity, str(FIXTURES / 'rootcert.pem')],
            env={**os.environ, 'FPR_HARTS': harts, 'FPR_CAMERA_GATE': GATE, 'FPR_PRINTER_CODE': 'test-only'},
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert select.select([self.process.stdout], [], [], 8)[0], 'native camera startup timeout'
        line = self.process.stdout.readline().decode()
        assert line.startswith('camera-ready '), line
        self.port = int(line.split()[1])

    def request(self, path='/stream', gate=GATE, small=False):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=14)
        conn.connect()
        if small:
            conn.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        conn.request('GET', path, headers={'X-Fpr-Camera': gate})
        return conn, conn.getresponse()

    def stats(self):
        conn, response = self.request('/stats')
        try:
            assert response.status == 200
            return json.loads(response.read(2048))
        finally:
            response.close()
            conn.close()

    def close(self):
        self.process.terminate()
        self.process.wait(5)
        errors = self.process.stderr.read().decode()
        assert 'PANIC' not in errors, errors
        self.process.stdout.close()
        self.process.stderr.close()


def part(response):
    assert response.status == 200
    assert response.fp.readline() == b'--frame\r\n'
    assert response.fp.readline() == b'Content-Type: image/jpeg\r\n'
    line = response.fp.readline()
    size = int(line.split(b':', 1)[1])
    assert 4 <= size <= 4194304 and response.fp.readline() == b'\r\n'
    image = response.fp.read(size)
    assert len(image) == size and image.startswith(b'\xff\xd8') and image.endswith(b'\xff\xd9')
    assert response.fp.read(2) == b'\r\n'
    return image


def header_limits(binary, harts):
    peer = Peer()
    service = Service(binary, peer, harts)
    held = []
    try:
        for suffix in (f'X-Fpr-Camera: {GATE}\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n',
                       f'X-Fpr-Camera: {GATE}\r\nContent-Length: 1\r\n\r\nx',
                       f'X-Fpr-Camera: {GATE}\r\nBroken header\r\n\r\n',
                       'X-Large: ' + 'x' * 9000 + '\r\n\r\n'):
            conn = socket.create_connection(('127.0.0.1', service.port), timeout=4)
            conn.sendall(('GET /stream HTTP/1.1\r\nHost: localhost\r\n' + suffix).encode())
            assert conn.recv(1024).startswith(b'HTTP/1.1 400 ')
            conn.close()
        assert peer.starts == 0
        # Admission happens before handlers spawn, including stalled headers.
        for _ in range(16):
            held.append(socket.create_connection(('127.0.0.1', service.port), timeout=4))
        time.sleep(.3)
        extra = socket.create_connection(('127.0.0.1', service.port), timeout=1)
        assert extra.recv(1) == b'', 'seventeenth handler was admitted'
        extra.close()
        for conn in held:
            conn.close()
        held.clear()
        time.sleep(.2)
        assert service.stats()['camera_state'] == 'OFF' and peer.starts == 0
    finally:
        for conn in held:
            conn.close()
        service.close()
        peer.close()
    print(f'{harts} hart(s): HTTP header/body validation and 16-handler admission bound PASS', flush=True)


def shared(binary, harts):
    peer = Peer()
    service = Service(binary, peer, harts)
    streams = []
    try:
        assert service.stats()['camera_state'] == 'OFF' and peer.starts == 0
        c, r = service.request(gate='wrong')
        assert r.status == 403
        r.read(); c.close()
        assert peer.starts == 0, 'unauthorized request started upstream camera'
        for _ in range(2):
            c, r = service.request()
            streams.append((c, r))
            assert b'native-generation-1' in part(r)
            part(r)
        assert service.stats()['camera_viewers'] == 2 and peer.starts == 1
        c, r = streams.pop(0)
        r.close(); c.close()
        wait(lambda: service.stats()['camera_viewers'] == 1)
        for _ in range(7):
            streams.append(service.request())
        assert service.stats()['camera_viewers'] == 8
        c, r = service.request()
        assert r.status == 503
        r.read(); c.close()
        for c, r in streams:
            r.close(); c.close()
        streams.clear()
        wait(lambda: service.stats()['camera_state'] == 'OFF' and peer.active == 0)
        assert service.stats()['camera_last_frame'] == 0, 'idle generation retained its frame'
        c, r = service.request()
        streams.append((c, r))
        assert b'native-generation-2' in part(r) and peer.starts == 2
    finally:
        for c, r in streams:
            r.close(); c.close()
        service.close()
        peer.close()
    print(f'{harts} hart(s): native TLS camera sharing, 8-viewer bound, capability gate, final-viewer cleanup and fresh generation PASS', flush=True)


def failure(binary, harts, mode, identity='server.example'):
    peer = Peer(mode)
    service = Service(binary, peer, harts, identity)
    try:
        c, r = service.request()
        assert r.status == 503
        r.read(); c.close()
        wait(lambda: peer.active == 0 and service.stats()['camera_viewers'] == 0)
    finally:
        service.close()
        peer.close()
    print(f'{harts} hart(s): native camera {mode}/{identity} refusal PASS', flush=True)


def slow(binary, harts):
    peer = Peer('large')
    service = Service(binary, peer, harts)
    try:
        c, r = service.request(small=True)
        assert r.status == 200
        wait(lambda: service.stats()['camera_viewers'] == 0 and peer.active == 0)
        r.close(); c.close()
    finally:
        service.close()
        peer.close()
    print(f'{harts} hart(s): slow viewer bounded by write deadline; upstream released PASS', flush=True)


def cancel_stalled(binary, harts):
    peer = Peer('stall')
    service = Service(binary, peer, harts)
    client = None
    try:
        client = socket.create_connection(('127.0.0.1', service.port))
        client.sendall(f'GET /stream HTTP/1.1\r\nHost: localhost\r\nX-Fpr-Camera: {GATE}\r\n\r\n'.encode())
        wait(lambda: peer.active == 1)
        started = time.monotonic()
        client.close(); client = None
        wait(lambda: peer.active == 0 and service.stats()['camera_viewers'] == 0, seconds=2)
        assert time.monotonic() - started < 2, 'final viewer waited for the 10s upstream read deadline'
        peer.mode = 'normal'
        conn, response = service.request()
        assert b'native-generation-2' in part(response)
        response.close(); conn.close()
    finally:
        if client:
            client.close()
        service.close()
        peer.close()
    print(f'{harts} hart(s): stalled-frame final-viewer cancellation and immediate fresh generation PASS', flush=True)


def gateway(binary, harts, identity='server.example'):
    peer = Peer()
    cfg = {'id': 'test', 'name': 'Test', 'model': 'P1S', 'host': '127.0.0.1', 'serial': 'TEST',
           'access_code_env': 'FPR_TEST_CODE', 'tls_peer': 'server.example', 'camera_tls_peer': identity, 'tls_ca': str(FIXTURES / 'rootcert.pem'), 'camera_port': peer.port}
    printer = bridge.Printer(cfg, native_camera_binary=str(binary))
    server = bridge.Gateway(('127.0.0.1', 0), bridge.Handler)
    server.printers, server.stopping = {'test': printer}, threading.Event()
    key, server.auth = test_auth()
    server.origin = f'http://localhost:{server.server_port}'
    server.snapshot = lambda: {'printers': [printer.snapshot()]}
    server.fpr_port = 1
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    c = None
    try:
        c = http.client.HTTPConnection('localhost', server.server_port, timeout=10)
        c.request('GET', '/camera/test.mjpg')
        r = c.getresponse()
        assert r.status == 401 and printer.camera.process is None
        r.read(); c.close()
        cookie = authenticate(server.origin, key)
        with patch.dict(os.environ, {'FPR_TEST_CODE': 'test-only', 'FPR_HARTS': harts}):
            printer.native_environment = bridge.view_environment({'test': printer}, os.environ)
            c = http.client.HTTPConnection('localhost', server.server_port, timeout=10)
            c.request('GET', '/camera/test.mjpg', headers={'Cookie': cookie})
            r = c.getresponse()
        if identity != 'server.example':
            assert r.status == 503, 'native TLS refusal did not become a gateway 503'
            r.read()
            assert peer.starts == 0
        else:
            part(r); part(r)
            assert peer.starts == 1
            server.auth.logout(cookie.split('=', 1)[1])
            wait(lambda: peer.active == 0)
        # A fresh anonymous request cannot reconnect the upstream.
        other = http.client.HTTPConnection('127.0.0.1', server.server_port)
        other.request('GET', '/camera/test.mjpg')
        denied = other.getresponse()
        assert denied.status == 401
        denied.read(); other.close()
        assert 'test-only' not in json.dumps(printer.snapshot())
    finally:
        if c:
            c.close()
        server.stopping.set()
        server.shutdown(); server.server_close(); thread.join(3)
        printer.close()
        peer.close()
    print(f'{harts} hart(s): gateway {"TLS refusal returns 503" if identity != "server.example" else "native multipart, logout and anonymous access gates"} PASS', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    for harts in ('1', '4'):
        header_limits(args.binary.resolve(), harts)
        shared(args.binary.resolve(), harts)
        for mode in ('oversize', 'badjpeg', 'short', 'stall'):
            failure(args.binary.resolve(), harts, mode)
        failure(args.binary.resolve(), harts, 'normal', identity='wrong.example')
        slow(args.binary.resolve(), harts)
        cancel_stalled(args.binary.resolve(), harts)
        gateway(args.binary.resolve(), harts)
        gateway(args.binary.resolve(), harts, identity='wrong.example')

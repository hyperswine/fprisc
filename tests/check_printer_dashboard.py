#!/usr/bin/env python3
"""No physical printers or credentials: transport and real FP-RISC wire checks.
Usage: python3 tests/check_printer_dashboard.py [--binary build/printers]
"""
import argparse
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from cryptography.hazmat.primitives import serialization
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
spec = importlib.util.spec_from_file_location('printer_dashboard', ROOT / 'tools/printer_dashboard.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
from check_live_wire import Client, has
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def test_auth():
    private = Ed25519PrivateKey.generate()
    keys = [{'name':'Test only', 'algorithm':'Ed25519', 'public_key':private.public_key().public_bytes_raw().hex()}]
    return private, bridge.Auth(keys)


def authenticate(base, key):
    def post(path, value, cookie=''):
        request = Request(base + path, data=json.dumps(value).encode(), headers={'Origin':base, 'Content-Type':'application/json', 'Cookie':cookie})
        return urlopen(request)
    with post('/auth/challenge', {}) as response:
        challenge = json.load(response)
        binding = response.headers['Set-Cookie'].split(';')[0]
    signature = base64.b64encode(key.sign(challenge['message'].encode())).decode()
    with post('/auth/verify', {'id':challenge['id'], 'signature':signature}, binding) as response:
        return response.headers['Set-Cookie'].split(';')[0]


def wait_for(pred, seconds=10):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if pred():
            return
        time.sleep(.03)
    raise AssertionError('condition did not arrive')


class Transport(unittest.TestCase):
    def test_auth_replay_binding_expiry_unknown_key_and_logout(self):
        key, auth = test_auth()
        origin = 'https://print.example'
        def proof():
            challenge, binding = auth.challenge(origin, 'test')
            return {'id':challenge['id'], 'signature':base64.b64encode(key.sign(challenge['message'].encode())).decode()}, binding
        value, binding = proof()
        token = auth.verify(value, origin, binding)
        self.assertTrue(auth.valid(token, origin))
        self.assertFalse(auth.valid(token, 'https://other.example'))
        self.assertFalse(auth.valid('forged', origin))
        with self.assertRaises(ValueError): auth.verify(value, origin, binding)
        auth.logout(token)
        self.assertFalse(auth.valid(token, origin))
        value, binding = proof()
        with self.assertRaises(ValueError): auth.verify(value, origin, 'wrong-browser')
        with self.assertRaises(ValueError): auth.verify(value, origin, binding)
        value, binding = proof()
        with self.assertRaises(ValueError): auth.verify(value, 'https://other.example', binding)
        value, binding = proof()
        row = auth.pending[value['id']]
        auth.pending[value['id']] = (0, *row[1:])
        with self.assertRaises(ValueError): auth.verify(value, origin, binding)
        value, binding = proof()
        value['signature'] = base64.b64encode(Ed25519PrivateKey.generate().sign(b'wrong')).decode()
        with self.assertRaises(ValueError): auth.verify(value, origin, binding)
        value, binding = proof()
        token = auth.verify(value, origin, binding)
        digest = next(iter(auth.sessions))
        row = auth.sessions[digest]
        auth.sessions[digest] = (0, *row[1:])
        self.assertFalse(auth.valid(token, origin))
        for _ in range(20): auth.challenge(origin, 'rate-limit-test')
        with self.assertRaises(ValueError): auth.challenge(origin, 'rate-limit-test')

    def printer(self):
        return bridge.Printer({'id': 'a1', 'name': 'A1', 'model': 'A1'}, demo=True)

    def test_merge_delta_and_freshness(self):
        p = self.printer()
        p.start()
        p.report({'print': {'gcode_state': 'RUNNING', 'mc_percent': 24, 'nozzle_temper': 215, 'ams': {'ams': []}, 'print_error': 0}})
        p.report({'print': {'bed_temper': 60}})
        s = p.snapshot()
        self.assertEqual(s['state'], 'RUNNING')
        self.assertEqual(s['nozzle'], 215)
        self.assertEqual(s['bed'], 60)
        self.assertEqual(s['progress'], 24)
        self.assertEqual(s['reports'], 2)
        p.last -= 20
        self.assertEqual(p.snapshot()['connection'], 'STALE')
        p.connected = False
        self.assertEqual(p.snapshot()['connection'], 'OFFLINE')
        self.assertEqual(p.snapshot()['progress'], 24)

    def test_no_ams_bad_numbers_and_unknown_fields(self):
        p = self.printer()
        p.report({'print': {'nozzle_temper': float('nan'), 'bed_temper': float('inf'), 'mc_percent': 999, 'ams': None, 'vt_tray': None, 'access_code': 'must-not-be-public', 'arbitrary': {'private': 'ignore'}}})
        s = p.snapshot()
        self.assertIsNone(s['nozzle'])
        self.assertIsNone(s['bed'])
        self.assertEqual(s['progress'], 100)
        text = json.dumps(s, allow_nan=False)
        self.assertNotIn('must-not-be-public', text)
        self.assertNotIn('arbitrary', text)
        p.report({'print': {'ams': {'ams': [None, 'broken', {'tray': [None, 'bad', {'tray_type': 'PLA'}]}]}, 'bed_temper': 26}})
        self.assertEqual(p.snapshot()['filament'], 'PLA')
        p.report({'print': {'command': 'gcode_line', 'result': 'success'}})
        self.assertEqual(p.reports, 2, 'ack is not telemetry')
        self.assertEqual(bridge.numeric(True), None)

    def test_view_process_gets_no_transport_environment(self):
        p = self.printer()
        p.config["access_code_env"] = "LOCAL_PRINTER_CODE"
        public = bridge.view_environment({"a1": p}, {"PATH": "/bin", "FPR_HARTS": "4", "LOCAL_PRINTER_CODE": "test-only", "BAMBU_ACCESS_CODE": "test-only", "FPR_PRINTER_CODE": "test-only", "FPR_CAMERA_GATE": "synthetic-capability"})
        self.assertEqual(public, {"PATH": "/bin", "FPR_HARTS": "4"})
        other = self.printer()
        other.config["access_code_env"] = "OTHER_PRINTER_CODE"
        self.assertEqual(bridge.view_environment({"a1": p, "other": other}, {"LOCAL_PRINTER_CODE": "first-test-only", "OTHER_PRINTER_CODE": "second-test-only", "FPR_PRINTER_CODE": "selected-test-only", "PATH": "/bin"}), {"PATH": "/bin"})

    def test_dotenv_selects_only_a1_without_executing_or_echoing_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = Path(tmp) / "printers.env"
            env.write_text('export BAMBU_A1_HOST="192.168.0.63" # LAN\nBAMBU_A1_ACCESS_CODE="test-only"\nUNRELATED_SECRET="ignore-me"\n')
            with patch.dict(os.environ, {}, clear=True), patch.object(bridge, 'discover_serials', return_value={'192.168.0.63':'03919D4A1103804'}) as discovery:
                rows = bridge.env_configs(env, selected=('a1',))
                self.assertEqual([row['id'] for row in rows], ['a1'])
                self.assertNotIn('test-only', json.dumps(rows))
                self.assertEqual(os.environ['BAMBU_A1_ACCESS_CODE'], 'test-only')
                self.assertNotIn('UNRELATED_SECRET', os.environ)
                self.assertNotIn('BAMBU_P1S_ACCESS_CODE', os.environ)
                discovery.assert_called_once_with({'192.168.0.63'}, 20)
                self.assertNotIn('BAMBU_A1_ACCESS_CODE', bridge.view_environment({'a1': bridge.Printer(rows[0])}, os.environ))
            env.write_text('BAMBU_A1_ACCESS_CODE="unterminated\n')
            with self.assertRaisesRegex(ValueError, '^invalid quoted printer configuration$'):
                bridge.printer_env(env)

    def test_discovery_requires_bambu_headers_and_valid_serial(self):
        data = b'NOTIFY * HTTP/1.1\r\nUSN: 03919D4A1103804\r\nDevModel.bambu.com: N2S\r\n'
        self.assertEqual(bridge.serial_from_advertisement(data), '03919D4A1103804')
        self.assertIsNone(bridge.serial_from_advertisement(b'USN: injected\r\n'))
        self.assertIsNone(bridge.serial_from_advertisement(b'USN: ../path\r\nDevModel.bambu.com: N2S\r\n'))

    def test_camera_demand_shared_and_released(self):
        p = self.printer()
        self.assertIsNone(p.camera.thread, 'off camera must never connect')
        seq = p.camera.acquire()
        seq, jpg = p.camera.next(seq)
        self.assertTrue(jpg.startswith(b'\xff\xd8'))
        self.assertEqual(p.snapshot()['camera_state'], 'LIVE')
        thread = p.camera.thread
        second = p.camera.acquire()
        self.assertIs(thread, p.camera.thread)
        p.camera.release()
        self.assertEqual(p.camera.users, 1)
        p.camera.release()
        wait_for(lambda: not thread.is_alive())
        self.assertEqual(p.camera.users, 0)
        self.assertEqual(p.snapshot()['camera_state'], 'OFF')
        self.assertIsNone(p.camera.frame)
        seq = p.camera.acquire()
        _, jpg = p.camera.next(seq)
        self.assertTrue(jpg.startswith(b'\xff\xd8'))
        p.close()
        p.camera.release()

    def test_camera_bounds_and_short_stream(self):
        class Short:
            def recv(self, n): return b''
        with self.assertRaises(ConnectionError): bridge.recv_exact(Short(), 16)
        p = self.printer()
        p.camera.users = 8
        with self.assertRaises(RuntimeError): p.camera.acquire()
        p.close()

    def test_atomic_snapshot_and_config_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'status.json'
            bridge.atomic_snapshot(path, {'schema': 1, 'printers': []})
            self.assertEqual(json.loads(path.read_text())['schema'], 1)
            self.assertEqual(len(list(Path(tmp).iterdir())), 1)
            path.write_text('[{"id":"../x"}]')
            with self.assertRaises(ValueError): bridge.configs(path, False)
            path.write_text('[]')
            with self.assertRaises(ValueError): bridge.configs(path, False)

    def test_http_read_only_and_camera_teardown(self):
        p = self.printer()
        server = bridge.Gateway(('127.0.0.1', 0), bridge.Handler)
        server.printers, server.stopping = {'a1': p}, threading.Event()
        server.snapshot = lambda: {'printers': [p.snapshot()]}
        server.fpr_port = 1
        private, server.auth = test_auth()
        server.origin = f'http://localhost:{server.server_port}'
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = server.origin
        try:
            with urlopen(base + '/') as response:
                body = response.read()
                self.assertIn(b'Sign in to Print room', body)
                self.assertNotIn(b'Bambu A1', body)
                self.assertIn("form-action 'none'", response.headers['Content-Security-Policy'])
            for path in ('/api/status', '/ws', '/camera/a1.mjpg', '/auth/session'):
                with self.assertRaises(HTTPError) as cm: urlopen(base + path)
                self.assertEqual(cm.exception.code, 401)
            self.assertEqual(p.camera.users, 0)
            for data in (b'{"private_key":"must-not-echo"}', b'null', b'{', b'x' * 1025):
                with self.assertRaises(HTTPError) as cm:
                    urlopen(Request(base + '/auth/verify', data=data, headers={'Origin':base, 'Content-Type':'application/json'}))
                self.assertEqual(cm.exception.code, 400)
                self.assertNotIn(b'must-not-echo', cm.exception.read())
            with self.assertRaises(HTTPError) as cm:
                urlopen(Request(base + '/auth/challenge', data=b'{}', headers={'Origin':'https://other.invalid', 'Content-Type':'application/json'}))
            self.assertEqual(cm.exception.code, 403)
            cookie = authenticate(base, private)
            def request(path, method='GET', headers=None):
                return Request(base + path, method=method, headers={'Cookie':cookie, 'Origin':base, **(headers or {})})
            with urlopen(request('/api/status')) as r:
                self.assertEqual(r.status, 200)
                self.assertEqual(r.headers['Cache-Control'], 'no-store')
            for path, method, status in [('/api/stop', 'POST', 405), ('/camera/nope.mjpg', 'GET', 404), ('/api/print', 'GET', 404)]:
                with self.assertRaises(HTTPError) as cm: urlopen(request(path, method))
                self.assertEqual(cm.exception.code, status)
            with self.assertRaises(HTTPError) as cm: urlopen(request('/camera/a1.mjpg', headers={'Origin': 'https://elsewhere.invalid'}))
            self.assertEqual(cm.exception.code, 403)
            with urlopen(request('/camera/a1.mjpg'), timeout=5) as r:
                self.assertIn('multipart', r.headers['Content-Type'])
                self.assertEqual(r.readline(), b'--frame\r\n')
                self.assertIn(b'image/jpeg', r.readline())
                size = int(r.readline().split(b':')[1])
                r.readline()
                self.assertTrue(r.read(size).startswith(b'\xff\xd8'))
            wait_for(lambda: p.camera.users == 0, 5)
            # Revocation also stops a feed that is already open.
            with urlopen(request('/camera/a1.mjpg'), timeout=5) as stream:
                self.assertEqual(stream.readline(), b'--frame\r\n')
                with urlopen(Request(base + '/auth/logout', data=b'{}', headers={'Cookie':cookie, 'Origin':base, 'Content-Type':'application/json'})) as response:
                    self.assertEqual(response.status, 200)
                stream.read()  # EOF, rather than an indefinitely authorized feed
                wait_for(lambda: p.camera.users == 0, 5)
            with self.assertRaises(HTTPError) as cm: urlopen(request('/api/status'))
            self.assertEqual(cm.exception.code, 401)
        finally:
            server.shutdown()
            server.server_close()
            p.close()


def html(client):
    return ''.join(s + (client.state['d'][i] if i < len(client.state['d']) else '') for i, s in enumerate(client.state['s']))


def run_wire(binary, harts):
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp)
        path = d / 'status.json'
        printer = bridge.Printer({'id': 'a1', 'name': 'Bambu A1', 'model': 'A1'}, demo=True)
        printer.start()
        printer.report({'print': {'gcode_state': 'RUNNING', 'mc_percent': 42, 'nozzle_temper': 220, 'bed_temper': 60}})
        def snapshot():
            bridge.atomic_snapshot(path, {'schema': 1, 'demo': True, 'generated_at': int(time.time()), 'printers': [printer.snapshot()]})
        snapshot()
        clients = []
        with (d / 'log').open('w+') as log:
            proc = subprocess.Popen([binary, '--port=0', f'--store={d}/store', f'--status={path}', '--poll-ms=250'], stdout=log, stderr=log, env={**os.environ, 'FPR_HARTS': harts})
            try:
                wait_for(lambda: 'ready ' in (d / 'log').read_text())
                port = int(re.search(r'ready (\d+)', (d / 'log').read_text())[1])
                a, b = Client(port, 3), Client(port, False)
                clients = [a, b]
                a.until(lambda s: has(s, 'Bambu A1'))
                b.until(lambda s: has(s, 'Bambu A1'))
                assert 'data-camera-on="false"' in html(a)
                a.send('Expand', 'a1')
                a.until(lambda s: has(s, 'Hide details'))
                b.recv()
                assert 'Hide details' not in html(b), 'expanded state leaked across tabs'
                a.send('Camera', 'a1')
                a.until(lambda s: has(s, 'Camera on'))
                assert 'data-camera-on="true"' in html(a)
                b.recv()
                assert 'Camera on' not in html(b), 'camera selection leaked across tabs'
                a.send('Camera', 'unknown')
                a.recv()
                assert 'unknown.mjpg' not in html(a)
                a.send('Expand', 'a1')
                a.until(lambda s: has(s, 'View details'))
                assert 'data-camera-on="false"' in html(a), 'collapse must suspend camera'
                # Dynamic text, not HTML; browser's View client puts this in textContent.
                printer.report({'print': {'subtask_name': '<img src=x onerror=alert(1)>', 'mc_percent': 57}})
                snapshot()
                for c in clients: c.until(lambda s: has(s, '57%'))
                assert '<img src=x onerror=alert(1)>' in a.state['d']
                assert '<img src=x onerror=alert(1)>' not in ''.join(a.state['s'])
                # Stale bridge must not present retained RUNNING state as fresh.
                doc = json.loads(path.read_text()); doc['generated_at'] -= 10
                bridge.atomic_snapshot(path, doc)
                for c in clients: c.until(lambda s: has(s, 'Bridge stale / unavailable'))
                bridge.atomic_snapshot(path, {'schema': 1, 'generated_at': int(time.time()), 'printers': 'wrong type'})
                a.until(lambda s: has(s, 'Unsupported printer snapshot'))
                assert '57%' in html(a)
                path.write_text('{broken')
                a.until(lambda s: has(s, 'Could not read the printer snapshot'))
                assert '57%' in html(a), 'parse failure lost last known values'
                snapshot()
                a.until(lambda s: not has(s, 'Could not read the printer snapshot') and has(s, 'Bridge connected'))
                path.unlink()
                a.until(lambda s: has(s, 'Waiting for the local printer bridge'))
                snapshot()
                a.until(lambda s: has(s, 'Bridge connected'))
                fresh = Client(port, 3); clients.append(fresh)
                assert 'Camera on' not in html(fresh), 'reconnect should start with camera off'
                print(f'PASS FP-RISC ({harts} harts): live patches, isolated tabs, collapse, stale/malformed/missing snapshot, recovery, text escaping, reconnect')
            finally:
                for c in clients:
                    with contextlib.suppress(OSError): c.close()
                proc.terminate()
                try: proc.wait(timeout=5)
                except subprocess.TimeoutExpired: proc.kill(); proc.wait()


def run_gateway(binary):
    with tempfile.TemporaryDirectory() as tmp:
        key, auth = test_auth()
        auth_path = Path(tmp) / 'auth.json'
        auth_path.write_text(json.dumps(auth.keys))
        pem_path = Path(tmp) / 'test-private.pem'
        pem_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        pem_path.chmod(0o600)
        log_path = Path(tmp) / 'log'
        with log_path.open('w') as log:
            proc = subprocess.Popen([sys.executable, str(ROOT / 'tools/printer_dashboard.py'), '--demo', '--port=0', f'--binary={binary}', f'--auth={auth_path}'], stdout=log, stderr=log)
            client = None
            try:
                wait_for(lambda: 'Print room:' in log_path.read_text())
                port = int(re.search(r'Print room: http://127.0.0.1:(\d+)', log_path.read_text())[1])
                base = f'http://localhost:{port}'
                subprocess.run(['node', str(ROOT / 'tests/check_printer_login.cjs'), base, str(pem_path)], check=True, timeout=20)
                cookie = authenticate(base, key)
                with urlopen(Request(base + '/', headers={'Cookie':cookie})) as r:
                    body = r.read()
                    assert b'Print room' in body and b'/auth/session.js' in body
                client = Client(port, 3, headers={'Cookie':cookie, 'Origin':base})
                client.until(lambda s: has(s, 'Bambu A1'))
                client.send('Camera', 'a1')
                client.until(lambda s: has(s, 'Camera on'))
                with urlopen(Request(base + '/api/status', headers={'Cookie':cookie})) as r:
                    assert len(json.load(r)['printers']) == 2
                with urlopen(Request(base + '/auth/logout', data=b'{}', headers={'Cookie':cookie, 'Origin':base, 'Content-Type':'application/json'})) as r:
                    assert r.status == 200
                # An already-established WebSocket must close after logout.
                client.s.settimeout(5)
                with contextlib.suppress(EOFError, ConnectionResetError):
                    while True: client.recv()
                print('PASS gateway: same-origin HTML, WebSocket upgrade/patches, status API, clean shutdown')
            finally:
                if client:
                    with contextlib.suppress(OSError): client.close()
                proc.terminate()
                try: proc.wait(timeout=8)
                except subprocess.TimeoutExpired: proc.kill(); proc.wait(); raise AssertionError('shutdown hung')
                assert proc.returncode == 0, log_path.read_text()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', default=str(ROOT / 'build/printers'))
    args = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Transport))
    if not result.wasSuccessful(): sys.exit(1)
    for harts in ('1', '4'): run_wire(str(Path(args.binary).resolve()), harts)
    run_gateway(str(Path(args.binary).resolve()))

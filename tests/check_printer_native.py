#!/usr/bin/env python3
"""Native collector + actual gateway handoff against an isolated TLS printer.

No real printers or credentials. Python implements only the test peer.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import socket
import ssl
import struct
import sys
import threading
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests/legacy'))
spec = importlib.util.spec_from_file_location('printer_dashboard', ROOT / 'tests/legacy/printer_dashboard.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
FIXTURES = ROOT / 'tests/fixtures/tls'


def field(text):
    text = text.encode() if isinstance(text, str) else text
    return struct.pack('!H', len(text)) + text


def frame(header, body):
    length, encoded = len(body), bytearray()
    while length >= 128:
        encoded.append(length % 128 + 128)
        length //= 128
    encoded.append(length)
    return bytes([header]) + encoded + body


def exact(conn, size):
    result = bytearray()
    while len(result) < size:
        chunk = conn.recv(size - len(result))
        if not chunk:
            raise EOFError()
        result.extend(chunk)
    return bytes(result)


def packet(conn):
    header = exact(conn, 1)[0]
    length, multiplier = 0, 1
    for _ in range(4):
        byte = exact(conn, 1)[0]
        length += (byte & 127) * multiplier
        if byte < 128:
            assert length <= 262144
            return header, exact(conn, length)
        multiplier *= 128
    raise AssertionError('invalid Remaining Length')


def take_field(body):
    size = struct.unpack('!H', body[:2])[0]
    assert size <= len(body) - 2
    return body[2:2 + size], body[2 + size:]


class PrinterPeer:
    def __init__(self, refuse=False, reconnect=False):
        self.refuse, self.reconnect = refuse, reconnect
        self.stopping = threading.Event()
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen()
        self.listener.settimeout(.2)
        self.port = self.listener.getsockname()[1]
        self.errors, self.connects, self.requests = [], 0, 0
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(FIXTURES / 'servercert.pem', FIXTURES / 'serverkey.pem')
        while not self.stopping.is_set():
            try:
                raw, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            try:
                raw.settimeout(.5)
                with context.wrap_socket(raw, server_side=True) as conn:
                    header, body = packet(conn)
                    protocol, rest = take_field(body)
                    assert header == 16 and protocol == b'MQTT' and rest[:2] == bytes([4, 194])
                    client, rest = take_field(rest[4:])
                    user, rest = take_field(rest)
                    password, rest = take_field(rest)
                    assert client in (b'fpr-read-TESTSERIAL', b'fpr-native-TESTSERIAL') and user == b'bblp' and password == b'test-only' and not rest
                    self.connects += 1
                    conn.sendall(frame(32, bytes([0, 4 if self.refuse else 0])))
                    if self.refuse:
                        continue
                    header, body = packet(conn)
                    topic, rest = take_field(body[2:])
                    assert header == 130 and topic == b'device/TESTSERIAL/report' and rest == b'\0'
                    conn.sendall(frame(144, body[:2] + b'\0'))
                    header, body = packet(conn)
                    topic, payload = take_field(body)
                    value = json.loads(payload)
                    assert header == 48 and topic == b'device/TESTSERIAL/request'
                    assert value == {'pushing': {'sequence_id': '1', 'command': 'pushall', 'version': 1, 'push_target': 1}}
                    self.requests += 1
                    def publication(topic, value):
                        return frame(48, field(topic) + (value if isinstance(value, bytes) else json.dumps(value).encode()))
                    if self.connects == 1:
                        wire = b''.join([
                            publication('device/TESTSERIAL/report', {'print': {'gcode_state': 'RUNNING', 'mc_percent': 24, 'nozzle_temper': 215.5, 'access_code': 'must-not-be-public'}}),
                            publication('device/OTHER/report', {'print': {'mc_percent': 99}}),
                            publication('device/TESTSERIAL/report', b'not JSON'),
                            publication('device/TESTSERIAL/report', {'print': {'bed_temper': 60}}),
                            publication('device/TESTSERIAL/report', {'print': {'command': 'pushall', 'result': 'success'}})])
                        for at in range(0, len(wire), 11):
                            conn.sendall(wire[at:at + 11])
                        if self.reconnect:
                            time.sleep(.6)
                            continue
                    else:
                        conn.sendall(publication('device/TESTSERIAL/report', {'print': {'bed_temper': 61}}))
                    while not self.stopping.is_set():
                        try:
                            header, body = packet(conn)
                        except socket.timeout:
                            continue
                        if header == 192:
                            conn.sendall(frame(208, b''))
                        else:
                            raise AssertionError('collector sent an unexpected printer command')
            except (ssl.SSLError, EOFError, ConnectionError, socket.timeout):
                # Certificate/name rejection and orderly collector termination.
                raw.close()
            except BaseException as exc:
                self.errors.append(repr(exc))

    def close(self):
        self.stopping.set()
        self.listener.close()
        self.thread.join(4)
        assert not self.thread.is_alive()
        assert not self.errors, self.errors


def wait(predicate, seconds=12):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        if predicate():
            return
        time.sleep(.04)
    raise AssertionError('native telemetry condition timed out')


def exercise(binary, harts, reject=False, wrong_peer=False):
    peer = PrinterPeer(refuse=reject, reconnect=not reject and not wrong_peer)
    config = {'id': 'test', 'name': 'Test printer', 'model': 'P1S', 'host': '127.0.0.1', 'mqtt_port': peer.port,
              'serial': 'TESTSERIAL', 'access_code_env': 'FPR_TEST_CODE', 'tls_peer': 'wrong.example' if wrong_peer else 'server.example',
              'tls_ca': str(FIXTURES / 'rootcert.pem'), 'camera': 'none'}
    p = bridge.Printer(config, native_binary=str(binary))
    try:
        with patch.dict(os.environ, {'FPR_TEST_CODE': 'test-only', 'FPR_HARTS': harts}):
            p.native_environment = bridge.view_environment({'test': p}, os.environ)
            with patch.object(bridge.subprocess, 'Popen', wraps=bridge.subprocess.Popen) as popen:
                p.start()
                child_env = popen.call_args.kwargs['env']
                assert child_env['FPR_PRINTER_CODE'] == 'test-only' and 'FPR_TEST_CODE' not in child_env
        wait(lambda: p.native_state is not None)
        if reject:
            wait(lambda: peer.connects >= 1 and p.snapshot()['connection'] == 'OFFLINE')
            assert p.snapshot()['reports'] == 0
        elif wrong_peer:
            time.sleep(1.5)
            assert peer.connects == 0 and p.snapshot()['connection'] == 'OFFLINE'
        else:
            wait(lambda: p.snapshot().get('bed') == 61)
            value = p.snapshot()
            assert value['nozzle'] == 215.5 and value['progress'] == 24 and value['reports'] == 3, value
            assert value['connection'] == 'ONLINE' and peer.requests == 2
            assert value['id'] == 'test' and not value['camera_available']
            with p.lock:
                before = p.native_received
                p.native_received = time.monotonic() - 3
                assert p.snapshot()['connection'] == 'STALE'
                p.native_received = before
        assert 'test-only' not in json.dumps(p.snapshot()) and 'must-not-be-public' not in json.dumps(p.snapshot())
        assert all('test-only' not in a for a in p.native.process.args)
        assert p.client is None, 'native telemetry must not create a Paho client'
    finally:
        p.close()
        assert p.native.process.poll() is not None
        assert not p.native.thread.is_alive()
        peer.close()
    print(f'{harts} hart(s): native printer {"TLS refusal" if wrong_peer else "auth refusal" if reject else "authenticated TLS, delta/freshness projection, reconnect/resubscribe/pushall and gateway handoff"} PASS', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    for harts in ('1', '4'):
        exercise(args.binary.resolve(), harts)
        exercise(args.binary.resolve(), harts, reject=True)
        exercise(args.binary.resolve(), harts, wrong_peer=True)

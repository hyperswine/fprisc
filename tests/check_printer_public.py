#!/usr/bin/env python3
"""Explicit real-device, read-only deployment acceptance over verified HTTPS/WSS.

The existing authorized key is read only inside this process. No key, bearer,
proof, image or complete telemetry document is logged or saved. This driver
changes only its own UI session/camera subscriptions, never printer controls.
"""
import argparse
import base64
import contextlib
import hashlib
import http.client
import http.cookiejar
import json
import os
from pathlib import Path
import socket
import ssl
import time
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPCookieProcessor, Request, build_opener
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from check_live_wire import Client, has


class Login:
    def __init__(self, origin, key):
        self.origin = origin
        self.jar = http.cookiejar.CookieJar()
        self.opener = build_opener(HTTPCookieProcessor(self.jar))
        status, headers, raw = self.request('/auth/challenge', {})
        assert status == 200, 'public challenge refused'
        challenge = json.loads(raw)
        assert challenge['message'].startswith('Print room login v1\n' + origin + '\n')
        proof = {'id': challenge['id'], 'signature': base64.b64encode(key.sign(challenge['message'].encode())).decode()}
        assert self.request('/auth/verify', proof)[0] == 200, 'public proof refused'
        bearer = [c for c in self.jar if c.name == 'print_room_session']
        assert len(bearer) == 1 and bearer[0].secure and bearer[0].has_nonstandard_attr('HttpOnly')
        assert bearer[0].get_nonstandard_attr('SameSite') == 'Strict'

    def request(self, path, body=None):
        headers = {} if body is None else {'Origin': self.origin, 'Content-Type': 'application/json'}
        req = Request(self.origin + path, data=None if body is None else json.dumps(body).encode(), headers=headers)
        try:
            response = self.opener.open(req, timeout=15)
        except HTTPError as error:
            response = error
        with response:
            raw = response.read(2097153)
            assert len(raw) <= 2097152, 'oversized public document'
            return response.status, response.headers, raw

    def cookie(self):
        return '; '.join(c.name + '=' + c.value for c in self.jar)

    def snapshot(self):
        status, _, raw = self.request('/api/status')
        assert status == 200, 'authenticated status refused'
        assert b'access_code' not in raw and b'PRIVATE KEY' not in raw
        value = json.loads(raw)
        assert value['schema'] == 1 and value['demo'] is False
        return {row['id']: row for row in value['printers']}


class PublicClient(Client):
    def __init__(self, origin, cookie):
        url = urlsplit(origin)
        self.s = ssl.create_default_context().wrap_socket(socket.create_connection((url.hostname, url.port or 443), timeout=15), server_hostname=url.hostname)
        self.buf, self.state, self.frames = b'', None, []
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall(('GET /ws?lv=3 HTTP/1.1\r\nHost: ' + url.netloc + '\r\nOrigin: ' + origin +
                        '\r\nCookie: ' + cookie + '\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ' + key + '\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        while b'\r\n\r\n' not in self.buf:
            chunk = self.s.recv(4096)
            assert chunk, 'WSS closed before upgrade'
            self.buf += chunk
            assert len(self.buf) <= 65536, 'WSS upgrade exceeds bound'
        head, self.buf = self.buf.split(b'\r\n\r\n', 1)
        assert head.startswith(b'HTTP/1.1 101 '), 'public WSS upgrade refused'
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        assert b'sec-websocket-accept: ' + accept.lower() in head.lower()
        assert 's' in self.recv(), 'WSS missing initial snapshot'


def eventually(read, predicate, label, seconds=20):
    until = time.monotonic() + seconds
    while True:
        value = read()
        if predicate(value):
            return value
        if time.monotonic() >= until:
            raise AssertionError(label)
        time.sleep(.25)


def stream(origin, login, printer):
    url = urlsplit(origin)
    connection = http.client.HTTPSConnection(url.hostname, url.port or 443, timeout=15, context=ssl.create_default_context())
    connection.request('GET', '/camera/' + printer + '.mjpg', headers={'Cookie': login.cookie(), 'Origin': origin})
    response = connection.getresponse()
    assert response.status == 200 and response.getheader('Content-Type', '').startswith('multipart/x-mixed-replace')
    return connection, response


def part(response):
    # Read through HTTPResponse so public proxies' transfer chunks are decoded.
    def line():
        value = bytearray()
        while len(value) <= 1024:
            byte = response.read(1)
            assert byte, 'MJPEG ended before a complete header'
            value.extend(byte)
            if byte == b'\n':
                return bytes(value)
        raise AssertionError('MJPEG header exceeds bound')
    assert line() == b'--frame\r\n', 'bad MJPEG boundary'
    assert line() == b'Content-Type: image/jpeg\r\n'
    size = int(line().split(b':', 1)[1])
    assert 4 <= size <= 4194304 and line() == b'\r\n'
    image = response.read(size)
    assert len(image) == size and image.startswith(b'\xff\xd8') and image.endswith(b'\xff\xd9'), 'bad camera JPEG'
    assert response.read(2) == b'\r\n'
    return len(image)


def closed(sock, label):
    until = time.monotonic() + 8
    sock.settimeout(8)
    while time.monotonic() < until:
        try:
            if not sock.recv(65536):
                return
        except (ConnectionError, ssl.SSLError):
            return
    raise AssertionError(label)


def camera_closed(response):
    # A completed chunked HTTP body can end while nginx keeps its TCP connection
    # alive. The response body must end; TCP keep-alive is not a camera viewer.
    until, total = time.monotonic() + 8, 0
    while time.monotonic() < until and total <= 67108864:
        try:
            data = response.read(65536)
            if not data:
                return
            total += len(data)
        except (ConnectionError, ssl.SSLError, http.client.IncompleteRead):
            return
    raise AssertionError('logout left camera response alive')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin', default='https://3dprint.cswine.cloud')
    parser.add_argument('--key-file', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--printers', default='a1,p1s')
    args = parser.parse_args()
    assert args.origin.startswith('https://') and urlsplit(args.origin).path in ('', '/')
    printers = args.printers.split(',')
    assert all(p and all(c in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in p) for p in printers)
    key = load_pem_private_key(args.key_file.read_bytes(), password=None)
    assert isinstance(key, Ed25519PrivateKey)
    evidence = {'origin': args.origin, 'deployed_commit': args.commit, 'checked_at': int(time.time())}
    anonymous = build_opener()
    for path in ['/api/status', '/ws', '/auth/session.js'] + ['/camera/' + p + '.mjpg' for p in printers]:
        try:
            with anonymous.open(args.origin + path, timeout=15) as response:
                code = response.status
        except HTTPError as error:
            code = error.code
            error.close()
        assert code == 401, 'anonymous protected route was accessible'
    evidence['anonymous_protected_routes_401'] = True
    observer, login = Login(args.origin, key), Login(args.origin, key)
    clients, feeds = [], []
    try:
        snapshot = eventually(login.snapshot, lambda rows: all(p in rows and rows[p].get('connection') == 'ONLINE' and rows[p].get('reports', 0) > 0 and 0 <= time.time() - rows[p].get('last_report', 0) < 60 for p in printers), 'real telemetry did not become fresh/online', 45)
        evidence['native_telemetry'] = [{'id': p, 'connection': snapshot[p]['connection'], 'reports': snapshot[p]['reports'], 'last_report': snapshot[p]['last_report']} for p in printers]
        assert login.request('/')[0] == 200
        ws = PublicClient(args.origin, login.cookie()); clients.append(ws)
        ws.until(lambda state: all(has(state, snapshot[p]['name']) for p in printers))
        count = len(ws.frames)
        ws.recv()
        assert len(ws.frames) > count, 'no subsequent WSS update'
        evidence['public_wss_cards_and_updates'] = True
        ws.send('Camera', printers[0]); ws.until(lambda state: has(state, 'Camera on'))
        ws.send('Camera', printers[0]); ws.until(lambda state: not has(state, 'Camera on'))
        evidence['public_wss_camera_toggle'] = True
        evidence['camera_frames'], evidence['shared_camera_upstreams'] = {}, {}
        for printer in printers:
            baseline = login.snapshot()[printer]
            assert baseline['camera_viewers'] == 0, 'another camera viewer is active; cannot isolate acceptance'
            first = stream(args.origin, login, printer); feeds.append(first)
            sizes = [part(first[1]), part(first[1])]
            second = stream(args.origin, login, printer); feeds.append(second); part(second[1])
            active = eventually(login.snapshot, lambda rows: rows[printer]['camera_viewers'] == 2, 'shared viewers missing')
            assert active[printer]['camera_connections'] == baseline['camera_connections'] + 1, 'camera opened duplicate upstreams'
            evidence['shared_camera_upstreams'][printer] = True
            first[1].close(); first[0].close(); feeds.remove(first)
            eventually(login.snapshot, lambda rows: rows[printer]['camera_viewers'] == 1, 'first viewer not removed')
            part(second[1])
            second[1].close(); second[0].close(); feeds.remove(second)
            eventually(login.snapshot, lambda rows: rows[printer]['camera_viewers'] == 0 and rows[printer]['camera_state'] == 'OFF', 'last-viewer cleanup failed')
            evidence['camera_frames'][printer] = sizes
        evidence['final_viewer_cleanup'] = True
        # Keep real feeds open during logout; a second test login observes cleanup.
        for printer in printers:
            feed = stream(args.origin, login, printer); feeds.append(feed); part(feed[1])
        stale_cookie = login.cookie()
        assert login.request('/auth/logout', {})[0] == 200
        with contextlib.suppress(HTTPError):
            req = Request(args.origin + '/api/status', headers={'Cookie': stale_cookie})
            try:
                with anonymous.open(req, timeout=15) as response:
                    assert response.status == 401, 'revoked bearer remained usable'
            except HTTPError as error:
                assert error.code == 401
                error.close()
        closed(ws.s, 'logout left WSS alive')
        for _, response in feeds:
            camera_closed(response)
        eventually(observer.snapshot, lambda rows: all(rows[p]['camera_viewers'] == 0 and rows[p]['camera_state'] == 'OFF' for p in printers), 'logout did not stop native camera sources')
        evidence['logout_closes_wss_and_cameras'] = True
        args.output.write_text(json.dumps(evidence, indent=2) + '\n')
        print(json.dumps(evidence, indent=2))
    finally:
        for connection, response in feeds:
            response.close(); connection.close()
        for client in clients:
            with contextlib.suppress(OSError): client.close()
        for session in (login, observer):
            with contextlib.suppress(Exception): session.request('/auth/logout', {})


if __name__ == '__main__':
    main()

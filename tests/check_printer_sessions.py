#!/usr/bin/env python3
"""Synthetic native 30-day session acceptance; no real printer or login keys."""
import argparse
import base64
import json
import os
from pathlib import Path
import select
import socket
import stat
import subprocess
import tempfile
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

ROOT = Path(__file__).resolve().parents[1]
TTL = 30 * 24 * 60 * 60


class Host:
    def __init__(self, binary, folder, harts):
        self.binary, self.folder, self.harts = binary, folder, harts
        self.key = Ed25519PrivateKey.generate()
        self.allow = folder/'auth.json'
        self.sessions = folder/'sessions.json'
        self.write_key(self.key)
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            self.port = s.getsockname()[1]
        self.child = None

    def write_key(self, key):
        public = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()
        self.allow.write_text(json.dumps([{'name': 'Synthetic test', 'algorithm': 'Ed25519', 'public_key': public}]))

    def start(self, healthy=True):
        self.child = subprocess.Popen([str(self.binary), '--demo', '--port='+str(self.port),
            '--origin=https://print.example', '--auth='+str(self.allow),
            '--session-store='+str(self.sessions), '--store='+str(self.folder/'view.kvlog')],
            cwd=ROOT, env={**os.environ, 'PATH': '/nonexistent', 'FPR_HARTS': str(self.harts)},
            umask=0o077, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        end = time.monotonic()+20
        while time.monotonic() < end:
            if self.child.poll() is not None:
                assert not healthy, 'host unexpectedly refused startup'
                return
            if select.select([self.child.stdout], [], [], .1)[0]:
                line = self.child.stdout.readline()
                if line.startswith('gateway-ready '):
                    assert healthy, 'damaged session store allowed startup'
                    return
        raise AssertionError('host did not reach expected startup outcome')

    def stop(self):
        if self.child is not None:
            self.child.terminate()
            try:
                self.child.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.communicate(timeout=5)
            self.child = None

    def request(self, path, body=None, cookie='', origin='https://print.example'):
        headers = {'Host': 'print.example', 'Origin': origin, 'Cookie': cookie}
        if body is not None:
            headers['Content-Type'] = 'application/json'
        req = Request(f'http://127.0.0.1:{self.port}'+path, headers=headers,
                      data=None if body is None else json.dumps(body).encode())
        try:
            response = urlopen(req, timeout=8)
        except HTTPError as error:
            response = error
        with response:
            return response.status, response.headers, response.read()

    def proof(self):
        status, headers, raw = self.request('/auth/challenge', {})
        assert status == 200, 'challenge refused'
        challenge = json.loads(raw)
        binding = next(v.split(';')[0] for v in headers.get_all('set-cookie') if v.startswith('print_room_challenge='))
        proof = {'id': challenge['id'], 'signature': base64.b64encode(self.key.sign(challenge['message'].encode())).decode()}
        return proof, binding

    def login(self):
        proof, binding = self.proof()
        status, headers, _ = self.request('/auth/verify', proof, binding)
        assert status == 200, 'signature login refused'
        raw = next(v for v in headers.get_all('set-cookie') if v.startswith('print_room_session='))
        assert f'Max-Age={TTL};' in raw and all(flag in raw for flag in ['HttpOnly', 'SameSite=Strict', 'Secure'])
        cookie = raw.split(';')[0]
        assert self.request('/api/status', cookie=cookie)[0] == 200
        assert self.request('/api/status', cookie=cookie, origin='https://other.example')[0] == 403
        return cookie


def check(binary, folder, harts):
    host = Host(binary, folder, harts)
    try:
        host.start()
        cookie = host.login()
        saved = json.loads(host.sessions.read_text())
        assert stat.S_IMODE(host.sessions.stat().st_mode) == 0o600
        assert len(saved['sessions']) == 1
        row = saved['sessions'][0]
        assert set(row) == {'digest', 'origin', 'expires_ms'}
        assert cookie.split('=', 1)[1] not in host.sessions.read_text(), 'bearer saved on server'
        assert abs(row['expires_ms']/1000-time.time()-TTL) < 3
        expiry = row['expires_ms']
        outstanding, binding = host.proof()
        host.stop()
        host.start()
        assert host.request('/api/status', cookie=cookie)[0] == 200, 'session lost on restart'
        assert json.loads(host.sessions.read_text())['sessions'][0]['expires_ms'] == expiry, 'restart extended expiry'
        assert host.request('/auth/verify', outstanding, binding)[0] == 400, 'challenge survived restart'
        assert host.request('/auth/logout', {}, cookie)[0] == 200
        assert host.request('/api/status', cookie=cookie)[0] == 401
        host.stop()
        host.start()
        assert host.request('/api/status', cookie=cookie)[0] == 401, 'revoked token resurrected'

        cookie = host.login()
        # Force an atomic-write failure without modifying the checked snapshot.
        blocked = host.sessions.with_suffix('.json.tmp')
        blocked.mkdir()
        assert host.request('/auth/logout', {}, cookie)[0] == 503, 'undurable logout acknowledged'
        assert host.request('/api/status', cookie=cookie)[0] == 401, 'failed write left authorization open'
        blocked.rmdir()
        replacement = host.login()  # persists in-memory revocation before recovering
        host.stop()
        host.start()
        assert host.request('/api/status', cookie=cookie)[0] == 401
        assert host.request('/api/status', cookie=replacement)[0] == 200

        host.stop()
        host.key = Ed25519PrivateKey.generate()
        host.write_key(host.key)
        host.start()
        assert host.request('/api/status', cookie=replacement)[0] == 401, 'allowlist change kept old session'
        cookie = host.login()
        host.stop()
        saved = json.loads(host.sessions.read_text())
        # Clock.now is second-resolution; place the expiry before that boundary.
        saved['sessions'][0]['expires_ms'] = int(time.time()*1000)-2000
        host.sessions.write_text(json.dumps(saved))
        host.start()
        assert host.request('/api/status', cookie=cookie)[0] == 401, 'expired session restored'
        assert json.loads(host.sessions.read_text())['sessions'] == []
        host.stop()
        host.sessions.write_text('{broken')
        host.start(healthy=False)
        assert host.sessions.read_text() == '{broken', 'damaged store overwritten'
        print(f'{harts} hart(s): 30-day cookie, digest-only storage, restart, logout/recovery, key revocation, expiry and corrupt-store refusal PASS', flush=True)
    finally:
        host.stop()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='printer-session-test-') as temporary:
        for harts in (1, 4):
            folder = Path(temporary)/str(harts)
            folder.mkdir()
            check(args.binary.resolve(), folder, harts)

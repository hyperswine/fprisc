#!/usr/bin/env python3
"""Native maintenance acceptance: synthetic login, two tabs, disk failures, restart.

No printer connection or real login key. Run with the dashboard test venv:
  python tests/check_printer_care.py --binary build/printer-host-maintenance
"""
import argparse
import base64
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from check_live_wire import Client, has

ROOT = Path(__file__).resolve().parents[1]


class Host:
    def __init__(self, binary, directory, harts):
        self.store = directory / 'care.json'
        self.key = Ed25519PrivateKey.generate()
        allow = directory / 'auth.json'
        allow.write_text(json.dumps([{'name': 'Synthetic test', 'algorithm': 'Ed25519',
            'public_key': self.key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()}]))
        self.child = subprocess.Popen([str(binary), '--demo', '--port=0',
            '--auth=' + str(allow), '--origin=https://print.example',
            '--maintenance-store=' + str(self.store)], cwd=ROOT,
            env={**os.environ, 'PATH': '/nonexistent', 'FPR_HARTS': str(harts)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.clients = []
        end = time.monotonic() + 20
        while time.monotonic() < end:
            if self.child.poll() is not None:
                raise AssertionError('host exited: ' + self.child.stderr.read())
            if select.select([self.child.stdout], [], [], .1)[0]:
                line = self.child.stdout.readline()
                if line.startswith('ready '):
                    self.view_port = int(line.split()[1])
                if line.startswith('gateway-ready '):
                    self.port = int(line.split()[1])
                    break
        else:
            self.stop()
            raise TimeoutError('gateway startup')
        self.origin = f'http://localhost:{self.port}'
        assert self.request('/api/status', authenticated=False)[0] == 401
        status, headers, raw = self.request('/auth/challenge', {}, authenticated=False)
        assert status == 200
        challenge = json.loads(raw)
        binding = headers.get_all('set-cookie')[0].split(';')[0]
        proof = {'id': challenge['id'],
            'signature': base64.b64encode(self.key.sign(challenge['message'].encode())).decode()}
        status, headers, raw = self.request('/auth/verify', proof, cookie=binding, authenticated=False)
        assert status == 200, raw
        self.cookie = next(x.split(';')[0] for x in headers.get_all('set-cookie')
            if x.startswith('print_room_session='))

    def request(self, path, data=None, cookie=None, authenticated=True):
        headers = {'Origin': self.origin}
        if cookie is None and authenticated:
            cookie = self.cookie
        if cookie:
            headers['Cookie'] = cookie
        if data is not None:
            headers['Content-Type'] = 'application/json'
        req = Request(self.origin + path, headers=headers,
            data=None if data is None else json.dumps(data).encode())
        try:
            response = urlopen(req, timeout=8)
        except HTTPError as error:
            response = error
        with response:
            return response.status, response.headers, response.read()

    def snapshot(self):
        status, _, raw = self.request('/api/status')
        assert status == 200, raw
        return json.loads(raw)

    def client(self):
        client = Client(self.port, 3, headers={'Cookie': self.cookie, 'Origin': self.origin})
        self.clients.append(client)
        client.send('CarePanel', 'demo')
        client.until(lambda state: has(state, 'Native demo printer'))
        return client

    def wait_revision(self, revision):
        end = time.monotonic() + 12
        while time.monotonic() < end:
            value = self.snapshot()['maintenance']
            if value['rev'] == revision:
                return value
            assert value['rev'] < revision, value
            time.sleep(.05)
        raise TimeoutError(f'log revision {revision}')

    def stop(self):
        failed = self.child.poll() is not None
        for client in self.clients:
            try:
                client.close()
            except (OSError, EOFError):
                pass
        self.child.terminate()
        try:
            self.child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.child.kill()
            self.child.wait()
        self.child.stdout.close()
        if failed:
            diagnostic = self.child.stderr.read()
            if diagnostic:
                print('Synthetic host diagnostic: ' + diagnostic[-12000:], flush=True)
        self.child.stderr.close()


def draft(**values):
    return json.dumps({'title': '', 'days': '30', 'note': '', 'file': '', 'profile': '',
        'category': 'Noise / squeaking', 'outcome': 'Failed', **values}, ensure_ascii=False)


def run(binary, directory, harts):
    host = Host(binary, directory, harts)
    try:
        first = host.snapshot()
        assert first['maintenance_problem'] == ''
        assert all(t['done'] == 0 for t in first['maintenance']['tasks'])
        assert any('do not lubricate' in t['advice'] for t in first['maintenance']['tasks'])
        a, b = host.client(), host.client()
        # Authenticated browser messages cannot claim another printer's task.
        a.send('CareChange', 'done', 'missing', 'demo-carbon', 0, draft(note='wrong owner'))
        a.until(lambda state: has(state, 'Unknown printer'))
        assert host.snapshot()['maintenance']['rev'] == 0
        a.send('CareChange', 'task', 'demo', '', 0, draft(title='Custom rail check', days='0'))
        a.until(lambda state: has(state, '3650 whole days'))
        assert host.snapshot()['maintenance']['rev'] == 0
        note = 'Squeaking while moving Y | exact observation, cause unconfirmed <script> é 🔧'
        a.send('CareChange', 'issue', 'demo', '', 0, draft(note=note))
        b.send('CareChange', 'issue', 'demo', '', 0, draft(note='competing duplicate'))
        saved = host.wait_revision(1)
        assert len(saved['issues']) == 1 and len(saved['history']) == 1
        assert saved['issues'][0]['note'] in (note, 'competing duplicate')
        # Both views share history; the losing tab receives a conflict, no overwrite.
        for client in (a, b):
            client.until(lambda state: has(state, saved['issues'][0]['note'].replace('<', '&lt;').replace('>', '&gt;'))
                or has(state, saved['issues'][0]['note']))
        b.send('CareChange', 'issue', 'demo', '', 0, draft(note='stale retry'))
        b.until(lambda state: has(state, 'log changed in another tab'))
        assert host.snapshot()['maintenance']['rev'] == 1
        filename = 'part-' + 'x' * 150 + '.3mf'
        a.send('CareChange', 'print', 'demo', '', 1,
            draft(file=filename, profile='PLA / 0.4 / upright', note='Failed adhesion; no cause confirmed'))
        host.wait_revision(2)
        a.send('CareChange', 'print', 'demo', '', 2,
            draft(file=filename, profile='PLA / 0.4 / upright', outcome='Passed', note='Inspected fit and finish'))
        host.wait_revision(3)
        a.send('CareChange', 'snooze', 'demo', 'demo-carbon', 3, draft(note='Check tomorrow'))
        snoozed = host.wait_revision(4)
        task = next(t for t in snoozed['tasks'] if t['id'] == 'demo-carbon')
        assert task['done'] == 0 and task['snooze'] == task['due'] + 86400
        a.send('CareChange', 'done', 'demo', 'demo-carbon', 4, draft(note='Cleaned carbon rods; no lubricant'))
        done = host.wait_revision(5)
        task = next(t for t in done['tasks'] if t['id'] == 'demo-carbon')
        assert task['done'] > 0 and task['due'] == task['done'] + 30 * 86400 and task['snooze'] == 0
        issue = done['issues'][0]['id']
        a.send('CareChange', 'resolve', 'demo', issue, 5, draft(note=''))
        a.until(lambda state: has(state, 'Add a note about the fix'))
        a.send('CareChange', 'resolve', 'demo', issue, 5, draft(note='Retested; no noise observed'))
        host.wait_revision(6)
        # A refused disk write is not reflected in memory/API and can be retried.
        blocked = directory / 'care.json.tmp'
        blocked.mkdir()
        a.send('CareChange', 'issue', 'demo', '', 6, draft(note='Draft survives failed save'))
        a.until(lambda state: has(state, 'Could not save maintenance log'))
        assert host.snapshot()['maintenance']['rev'] == 6
        blocked.rmdir()
        a.send('CareChange', 'issue', 'demo', '', 6, draft(note='Draft survives failed save'))
        host.wait_revision(7)
        expected = host.snapshot()['maintenance']
        assert json.loads(host.store.read_text()) == expected
        assert json.loads(Path(str(host.store) + '.bak').read_text())['rev'] == 6
        assert all(secret not in json.dumps(host.snapshot()) for secret in ('signature', 'private_key', 'access_code'))
        assert host.request('/api/status', authenticated=False)[0] == 401
    finally:
        host.stop()
    host = Host(binary, directory, harts)
    try:
        assert host.snapshot()['maintenance'] == expected, 'restart must preserve the entire log'
        assert not host.snapshot()['maintenance_problem']
        # External damage is refused before overwrite; good backup is preserved.
        old_backup = Path(str(host.store) + '.bak').read_bytes()
        host.store.write_text('{truncated')
        a = host.client()
        a.send('CareChange', 'issue', 'demo', '', 7, draft(note='must not overwrite damaged log'))
        a.until(lambda state: has(state, 'invalid nesting'))
        assert host.store.read_text() == '{truncated'
        assert Path(str(host.store) + '.bak').read_bytes() == old_backup
    finally:
        host.stop()
    host = Host(binary, directory, harts)
    try:
        assert 'invalid nesting' in host.snapshot()['maintenance_problem']
        assert host.snapshot()['printers'][0]['connection'] == 'ONLINE', 'telemetry survives log damage'
        assert host.store.read_text() == '{truncated'
    finally:
        host.stop()
    host.store.unlink()
    host = Host(binary, directory, harts)
    try:
        assert 'backup exists' in host.snapshot()['maintenance_problem']
        assert not host.store.exists(), 'missing primary must not silently reset history'
    finally:
        host.stop()
    print(f'printer care: {harts} hart(s), auth/conflict/print/restart/write failure/corruption passed')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--serve', type=Path, help='keep an isolated demo alive for manual browser QA')
    args = parser.parse_args()
    if args.serve:
        args.serve.mkdir(parents=True, exist_ok=True)
        host = Host(args.binary.resolve(), args.serve.resolve(), 4)
        try:
            print(f'Demo UI: http://127.0.0.1:{host.view_port}', flush=True)
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass
        finally:
            host.stop()
        return
    for harts in (1, 4):
        with tempfile.TemporaryDirectory(prefix='printer-care-') as temp:
            run(args.binary.resolve(), Path(temp), harts)


if __name__ == '__main__':
    main()

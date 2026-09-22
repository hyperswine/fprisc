#!/usr/bin/env python3
"""Drive examples/logbook.fpr the way a browser does: over its websocket, with
the typed wire the page uses ("+" [name, ...] takes the argument as the message's
last field).  Then kill it and rebuild the log from the journal alone.

    logbook_ws.py <fpr> <logbook.fpr> <store>
"""
import base64, json, os, socket, struct, subprocess, sys, time

fpr, src, store = sys.argv[1:4]


class Ws:
    def __init__(self, port):
        self.s = socket.create_connection(('127.0.0.1', port), timeout=20)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall(f'GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                       f'Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n'.encode())
        self.buf = b''
        while b'\r\n\r\n' not in self.buf:
            d = self.s.recv(4096)
            assert d, 'closed during the handshake'
            self.buf += d
        head, self.buf = self.buf.split(b'\r\n\r\n', 1)
        assert b' 101 ' in head.split(b'\r\n')[0], head

    def send(self, name, *fields, arg=None):
        wire = ('+' if arg is not None else '=') + json.dumps([name, *fields])
        p = json.dumps({'msg': wire, 'arg': arg or ''}).encode()
        mask = os.urandom(4)
        hdr = bytes([0x81, 0x80 | len(p)]) if len(p) < 126 else bytes([0x81, 0x80 | 126]) + struct.pack('>H', len(p))
        self.s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(p)))

    def need(self, n):
        while len(self.buf) < n:
            d = self.s.recv(65536)
            assert d, 'closed'
            self.buf += d

    def recv(self):
        self.need(2)
        n, off = self.buf[1] & 127, 2
        if n == 126:
            self.need(4); n = struct.unpack('>H', self.buf[2:4])[0]; off = 4
        self.need(off + n)
        p, self.buf = self.buf[off:off + n], self.buf[off + n:]
        self.raw = p.decode()
        return json.loads(p)

    def until(self, text, timeout=20):
        """the next frame that mentions `text`; deltas are folded into the page"""
        end = time.time() + timeout
        while time.time() < end:
            m = self.recv()
            if 's' in m:
                self.page = m
            elif 'd' in m:
                for k, v in m['d'].items(): self.page['d'][int(k)] = v
            if text in self.raw: return m
        raise TimeoutError(text)

    def shown(self):
        """the entries on the page: the statics carry each one's stamp line"""
        return sum(s.count('&#183;') + s.count('·') for s in self.page['s'])


srv = subprocess.Popen([fpr, 'run', src, '--port=0', f'--store={store}'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    line = srv.stdout.readline()
    assert line.startswith('ready '), line + srv.stderr.read()
    port = int(line.split()[1])
    a = Ws(port); a.page = a.recv()
    assert '0 entries' in json.dumps(a.page), a.page
    # add: the clock stamps it, the toast names it, the page shows it
    a.send('Add', arg='INTERNET ISSUE|internet drop out')
    a.until('added #1')
    assert 'internet drop out' in json.dumps(a.page)
    for i in range(24):
        a.send('Add', arg=f'{"power" if i % 2 else ""}|observation {i + 1}')
    a.until('25 entries')
    # a second tab sees the same log, on its own page and with its own search
    b = Ws(port); b.page = b.recv()
    b.until('25 entries, 2 online')                  # the welcome renders before the join lands
    b.send('Search', arg='drop out')
    b.until('{\\"q\\":\\"drop out\\"}')             # the port to the page: the box is filled
    b.until('clear')                                # a full render: the clear button appeared
    assert b.shown() == 1 and 'internet drop out' in json.dumps(b.page), b.page
    # the first tab is unaffected by the second's search: it pages instead
    a.send('Page', 1)
    a.until('page 2 of 2')
    assert a.shown() == 5, a.shown()
    # edit through the second tab: the form is filled from the server, then saved
    b.send('Edit', 1)
    b.until('{\\"edit\\":\\"internet drop out\\"')
    b.send('Save', 1, arg='INTERNET ISSUE, outage|internet drop out, back after 10 min')
    b.until('saved #1')
    assert 'back after 10 min' in json.dumps(b.page) and 'outage' in json.dumps(b.page), b.page
    # the first tab, on page 2 where #1 lives, sees the edit without asking
    a.until('back after 10 min')
    # delete
    b.send('Delete', 1)
    b.until('deleted #1')
    a.until('24 entries')
    time.sleep(1.5)                                 # the entries field saves at most once a second
finally:
    srv.terminate()
    srv.wait(timeout=20)
# the log rebuilt from the journal alone agrees with the durable fields
p = subprocess.run([fpr, 'run', src, f'--store={store}', '--replay'], capture_output=True, text=True, timeout=300)
assert p.returncode == 0 and '24 entries, nextId=26' in p.stdout, p.stdout + p.stderr
# and a restart restores it from the fields (no journal read), with the edit gone
srv = subprocess.Popen([fpr, 'run', src, '--port=0', f'--store={store}'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    port = int(srv.stdout.readline().split()[1])
    c = Ws(port); c.page = c.recv()
    text = json.dumps(c.page)
    assert '24 entries' in text and 'observation 24' in text and 'drop out' not in text, text[:500]
finally:
    srv.terminate()
    srv.wait(timeout=20)
print('ok')

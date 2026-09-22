#!/usr/bin/env python3
"""Check v2 structural patches against a legacy client using a disposable logbook.
Usage: python3 tests/check_live_wire.py /path/to/logbook
"""
import base64, json, os, select, socket, struct, subprocess, sys, tempfile, time
from pathlib import Path

class Client:
    def __init__(self, port, modern):
        self.s = socket.create_connection(('127.0.0.1', port), timeout=10)
        self.buf = b''
        self.state = None
        self.frames = []
        target = '/ws?lv=2' if modern else '/ws'
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall(f'GET {target} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n'.encode())
        while b'\r\n\r\n' not in self.buf:
            self.buf += self.s.recv(4096)
        header, self.buf = self.buf.split(b'\r\n\r\n', 1)
        assert b' 101 ' in header
        first = self.recv()
        assert 's' in first and 'p' not in first, 'connection must begin with snapshot'
    def need(self, n):
        while len(self.buf) < n:
            data = self.s.recv(65536)
            if not data: raise EOFError
            self.buf += data
    def recv(self):
        self.need(2)
        n, offset = self.buf[1] & 127, 2
        if n == 126:
            self.need(4); n = struct.unpack('>H', self.buf[2:4])[0]; offset = 4
        elif n == 127:
            self.need(10); n = struct.unpack('>Q', self.buf[2:10])[0]; offset = 10
        self.need(offset+n)
        payload, self.buf = self.buf[offset:offset+n], self.buf[offset+n:]
        msg = json.loads(payload)
        self.frames.append((msg, len(payload)))
        if msg.get('p') == 2:
            new = {}
            for field in ('s','d'):
                start, remove, insert = msg[field]
                old = self.state[field]
                assert 0 <= start <= len(old) and 0 <= remove <= len(old)-start
                new[field] = old[:start] + insert + old[start+remove:]
            self.state = new
        elif 's' in msg:
            self.state = {'s':msg['s'], 'd':msg['d']}
        elif 'd' in msg:
            for k,v in msg['d'].items(): self.state['d'][int(k)] = v
        assert len(self.state['s']) == len(self.state['d'])+1
        return msg
    def until(self, pred):
        end=time.monotonic()+15
        while not pred(self.state):
            if time.monotonic()>end: raise TimeoutError('view never arrived')
            self.recv()
    def send(self, name, *fields):
        p=json.dumps({'msg':'='+json.dumps([name,*map(str,fields)]),'arg':''}).encode()
        mask=os.urandom(4)
        head=bytes([0x81,0x80|len(p)]) if len(p)<126 else bytes([0x81,0xfe])+struct.pack('>H',len(p))
        self.s.sendall(head+mask+bytes(c^mask[i%4] for i,c in enumerate(p)))
    def close(self):
        self.s.sendall(bytes([0x88,0x80])+os.urandom(4));self.s.close()

def has(state, text): return text in ''.join(state['s']+state['d'])

def main():
    with tempfile.TemporaryDirectory(prefix='live-wire-') as d:
        with open(Path(d)/'server.log','w+') as log:
            p=subprocess.Popen([str(Path(sys.argv[1]).resolve()),'--port=0','--store='+str(Path(d)/'store')],stdout=log,stderr=log)
            clients=[]
            try:
                import re
                for _ in range(200):
                    log.seek(0); m=re.search(r'ready (\d+)',log.read())
                    if m: break
                    if p.poll() is not None: raise RuntimeError('server exited')
                    time.sleep(.05)
                else: raise TimeoutError('startup')
                port=int(m[1]);a=Client(port,True);clients.append(a);b=Client(port,False);clients.append(b)
                for i in range(1,4):
                    a.send('Add',f'tag|wire entry {i}')
                    for c in (a,b): c.until(lambda st:has(st,f'wire entry {i}'))
                    assert a.state==b.state, 'patch and full snapshot disagree'
                a.send('Edit',2)
                a.until(lambda st:has(st,'editing'))
                a.send('Save',2,'tag|changed entry')
                for c in (a,b): c.until(lambda st:has(st,'changed entry') and not has(st,'editing'))
                assert a.state==b.state
                a.send('Delete',1)
                for c in (a,b): c.until(lambda st:not has(st,'wire entry 1'))
                assert a.state==b.state
                patches=[n for msg,n in a.frames if msg.get('p')==2]
                assert patches, 'modern connection never got patches'
                assert not any('p' in msg for msg,n in b.frames), 'legacy client received v2'
                fresh=Client(port,True);clients.append(fresh)
                assert has(fresh.state,'changed entry') and not has(fresh.state,'wire entry 1')
                print(f'PASS: inserts, edit/save, removal, text deltas, legacy equivalence, reconnect snapshot; {len(patches)} patches ({min(patches)}..{max(patches)} bytes)')
            finally:
                for c in clients:c.close()
                p.terminate()
                try:p.wait(timeout=10)
                except subprocess.TimeoutExpired:p.kill();p.wait()
if __name__=='__main__':main()

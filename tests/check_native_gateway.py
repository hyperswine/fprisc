#!/usr/bin/env python3
"""Native gateway/auth acceptance. Synthetic identities; no device access."""
import argparse
import base64
import contextlib
import http.client
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import tempfile
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from check_live_wire import Client

ROOT=Path(__file__).resolve().parents[1]

def run(binary,harts,directory,lan=False):
    telemetry=camera=None
    feeds=[]
    key=Ed25519PrivateKey.generate()
    allow=directory/'auth.json'
    allow.write_text(json.dumps([{'name':'Synthetic test','algorithm':'Ed25519','public_key':key.public_key().public_bytes(Encoding.Raw,PublicFormat.Raw).hex()}]))
    arguments=['--demo']
    environment={**os.environ,'FPR_HARTS':str(harts),'PATH':'/nonexistent'}
    if lan:
        from check_printer_native import PrinterPeer
        from check_native_camera import Peer
        # The camera service permits a first frame later than the WebSocket
        # upgrade timeout. Exercise that contract through the public proxy.
        telemetry,camera=PrinterPeer(),Peer(first_frame_delay=3.5)
        config=directory/'printers.json'
        config.write_text(json.dumps([{'id':'test','name':'Synthetic native printer','model':'P1S','location':'test','host':'127.0.0.1','mqtt_port':telemetry.port,'serial':'TESTSERIAL','access_code_env':'SYNTHETIC_PRINTER_CODE','tls_peer':'server.example','tls_ca':str(ROOT/'tests/fixtures/tls/rootcert.pem'),'camera':'bambu-jpeg','camera_port':camera.port}]))
        arguments=['--config='+str(config)]
        environment['SYNTHETIC_PRINTER_CODE']='test-only'
    child=subprocess.Popen([str(binary),*arguments,'--port=0','--origin=https://print.example','--auth='+str(allow),'--store='+str(directory/'view.kvlog')],cwd=ROOT,env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        until=time.monotonic()+15
        port=None
        while time.monotonic()<until:
            if child.poll() is not None:raise AssertionError(child.stderr.read())
            if select.select([child.stdout],[],[],.1)[0]:
                line=child.stdout.readline()
                if line.startswith('gateway-ready '):port=int(line.split()[1]);break
        assert port, 'gateway did not become ready'
        origin=f'http://localhost:{port}'
        def request(path,body=None,cookie='',headers=None):
            hs={'Cookie':cookie,**(headers or {})}
            if body is not None:hs.update({'Origin':origin,'Content-Type':'application/json'})
            req=Request(origin+path,data=None if body is None else json.dumps(body).encode(),headers=hs)
            try:r=urlopen(req,timeout=6)
            except HTTPError as e:r=e
            with r:return r.status,dict(r.headers),r.read()
        assert request('/api/status')[0]==401
        assert request('/ws')[0]==401
        assert request('/camera/demo.mjpg')[0]==401
        status,hs,page=request('/')
        assert status==200 and b'<form' in page and b'private-key' in page
        assert b'canvas{' not in page
        assert request('/auth/login.js')[0]==200
        assert request('/auth/session.js')[0]==401
        assert request('/health',headers={'Origin':'https://wrong.example'})[0]==403
        assert request('/health',headers={'Host':'wrong.example'})[0]==403
        assert request('/health',headers={'Sec-Fetch-Site':'cross-site'})[0]==403
        status,hs,raw=request('/auth/challenge',{})
        assert status==200,(status,raw)
        challenge=json.loads(raw);binding=hs['set-cookie'].split(';')[0]
        proof={'id':challenge['id'],'signature':base64.b64encode(key.sign(challenge['message'].encode())).decode()}
        assert request('/auth/verify',proof,'wrong=browser')[0]==400
        assert request('/auth/verify',proof,binding)[0]==400,'a failed proof must consume its challenge'
        status,hs,raw=request('/auth/challenge',{})
        challenge=json.loads(raw);binding=hs['set-cookie'].split(';')[0]
        proof={'id':challenge['id'],'signature':base64.b64encode(key.sign(challenge['message'].encode())).decode()}
        status,hs,raw=request('/auth/verify',proof,binding)
        assert status==200,(status,raw)
        cookies=hs['set-cookie'] # urllib dict keeps only last; use raw pair below via response headers
        # Both Set-Cookie fields matter; perform another proof with explicit get_all.
        status,hs,raw=request('/auth/challenge',{})
        challenge=json.loads(raw);binding=hs['set-cookie'].split(';')[0]
        proof={'id':challenge['id'],'signature':base64.b64encode(key.sign(challenge['message'].encode())).decode()}
        req=Request(origin+'/auth/verify',data=json.dumps(proof).encode(),headers={'Origin':origin,'Content-Type':'application/json','Cookie':binding})
        with urlopen(req,timeout=6) as r:
            cookie=next(x.split(';')[0] for x in r.headers.get_all('set-cookie') if x.startswith('print_room_session='))
            assert 'HttpOnly' in str(r.headers) and 'SameSite=Strict' in str(r.headers)
        assert request('/auth/verify',proof,binding)[0]==400
        status,hs,raw=request('/api/status',cookie=cookie)
        assert status==200,(status,raw)
        snapshot=json.loads(raw)
        if lan:
            until=time.monotonic()+8
            while snapshot['printers'][0].get('reports',0)<3 and time.monotonic()<until:
                time.sleep(.05);snapshot=json.loads(request('/api/status',cookie=cookie)[2])
            assert snapshot['printers'][0]['connection']=='ONLINE' and snapshot['printers'][0]['progress']==24,snapshot
            assert 'must-not-be-public' not in json.dumps(snapshot)
        else:assert snapshot['demo'] and snapshot['printers'][0]['connection']=='ONLINE'
        assert b'access_code' not in raw and b'FPR_PRINTER_CODE' not in raw
        status,hs,page=request('/',cookie=cookie)
        assert status==200 and b'Print room' in page and b'/auth/session' in page
        assert request('/auth/session',cookie=cookie)[0]==200
        ws=Client(port,3,headers={'Cookie':cookie,'Origin':origin})
        # Declared oversized frames must close before receiving their bodies.
        for length in (16777217, 1 << 63):
            oversized=Client(port,3,headers={'Cookie':cookie,'Origin':origin})
            oversized.s.sendall(b'\x81\xff'+struct.pack('!Q',length)+b'abcd')
            oversized.s.settimeout(2)
            closed=False
            while True:
                data=oversized.s.recv(4096)
                if not data:closed=True;break
            assert closed
            with contextlib.suppress(OSError):oversized.close()
        assert request('/api/status',cookie=cookie)[0]==200
        if lan:
            from check_native_camera import part
            for _ in range(2):
                conn=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
                conn.request('GET','/camera/test.mjpg',headers={'Cookie':cookie,'Host':f'localhost:{port}'})
                response=conn.getresponse();feeds.append((conn,response));part(response)
            assert camera.starts==1 and camera.active==1
        assert request('/auth/logout',{},cookie)[0]==200
        assert request('/api/status',cookie=cookie)[0]==401
        # Logout must terminate an already authenticated WebSocket.
        deadline=time.monotonic()+4;closed=False
        while time.monotonic()<deadline:
            try:
                value=ws.s.recv(65536)
                if value == b'':closed=True;break
            except (EOFError,ConnectionError,OSError):closed=True;break
        with contextlib.suppress(OSError):ws.close()
        assert closed,'logout left WebSocket alive'
        if lan:
            deadline=time.monotonic()+2
            while camera.active and time.monotonic()<deadline:time.sleep(.02)
            assert camera.active==0,'logout did not stop the native upstream camera'
            assert request('/camera/test.mjpg')[0]==401
        print(f"PASS native gateway/auth {harts} harts ({'TLS peers' if lan else 'demo'}): empty tool PATH, origin/host checks, generated login, one-use proof/binding, native Ed25519, public allowlist, session/logout and live revocation",flush=True)
    finally:
        for conn,response in feeds:
            response.close();conn.close()
        child.terminate()
        try:child.wait(timeout=5)
        except subprocess.TimeoutExpired:child.kill();child.wait()
        errors=child.stderr.read()
        assert 'PANIC' not in errors,errors
        if camera:camera.close()
        if telemetry:telemetry.close()

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--lifetime-binary',type=Path,help='compiled tests/gateway_lifetime.fpr regression')
    args=parser.parse_args()
    if args.lifetime_binary:
        for harts in (1,4):
            subprocess.run([str(args.lifetime_binary.resolve())],check=True,env={**os.environ,'FPR_HARTS':str(harts),'PATH':'/nonexistent'},timeout=15)
    with tempfile.TemporaryDirectory(prefix='fpr-native-gateway-') as temp:
        for harts in (1,4):
            for lan in (False,True):
                directory=Path(temp)/(str(harts)+'-'+str(lan));directory.mkdir();run(args.binary.resolve(),harts,directory,lan)
if __name__=='__main__':main()

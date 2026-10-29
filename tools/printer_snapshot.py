#!/usr/bin/env python3
"""Optional, demand-only RTSPS decoder for the native printer dashboard.

Loopback HTTP, fixed configured printers, verified TLS, bounded FFmpeg captures.
No printer controls, disk images, shell, credential argv, or background polling.
The FP-RISC camera actor owns cadence and viewer lifetime; this adapter only
decodes a requested still. Access codes are read from the existing runtime file.
"""
import argparse
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import threading
import time
from urllib.parse import quote

MAX_FRAME = 4194304
CAPTURE_SECONDS = 15
CACHE_SECONDS = 2


def literal(value):
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError('invalid decoder option')
    return "'" + value.replace("'", "'\\''") + "'"


def decode(row, code, executable, timeout=CAPTURE_SECONDS):
    # FFconcat passes demuxer options with the input. Credentials are on stdin,
    # never the command line, and FFmpeg diagnostics are deliberately discarded.
    host = row['host']
    host = '['+host+']' if ':' in host else host
    url = f"rtsps://bblp:{quote(code,safe='')}@{host}:{row.get('camera_port',322)}/streaming/live/1"
    script = 'ffconcat version 1.0\nfile '+literal(url)+'\n'
    for key,value in [('rtsp_transport','tcp'), ('tls_verify','1'),
                      ('verifyhost',row.get('camera_tls_peer',row['tls_peer'])),
                      ('ca_file',row.get('camera_tls_ca',row['tls_ca'])), ('timeout','6000000')]:
        script += 'option '+key+' '+literal(str(value))+'\n'
    command = [executable,'-hide_banner','-loglevel','quiet','-nostats',
        '-protocol_whitelist','pipe,file,rtsp,rtsps,tcp,tls,rtp,udp',
        '-f','concat','-safe','0','-i','pipe:0','-map','0:v:0','-frames:v','1',
        '-vf','scale=w=1280:h=720:force_original_aspect_ratio=decrease',
        '-threads','1','-c:v','mjpeg','-q:v','5','-f','image2pipe','pipe:1']
    process = subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,close_fds=True,start_new_session=True)
    deadline = time.monotonic()+timeout
    output = bytearray()
    try:
        process.stdin.write(script.encode()); process.stdin.close()
        os.set_blocking(process.stdout.fileno(),False)
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout,selectors.EVENT_READ)
            while True:
                left = deadline-time.monotonic()
                if left <= 0:
                    raise TimeoutError('snapshot timed out')
                if not selector.select(min(left,.1)):
                    continue
                chunk = os.read(process.stdout.fileno(),min(65536,MAX_FRAME+1-len(output)))
                if not chunk:
                    break
                output.extend(chunk)
                if len(output)>MAX_FRAME:
                    raise ValueError('snapshot exceeds bound')
        if process.wait(timeout=max(.01,deadline-time.monotonic())) != 0:
            raise ValueError('decoder unavailable')
        if not (output.startswith(b'\xff\xd8') and output.endswith(b'\xff\xd9')):
            raise ValueError('invalid snapshot')
        return bytes(output)
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=2)
        process.stdout.close()
        if not process.stdin.closed:
            process.stdin.close()


class Source:
    def __init__(self,row,code,executable,capture=decode):
        self.row,self.code,self.executable,self.capture = row,code,executable,capture
        self.lock=threading.Lock()
        self.frame=b''; self.last=0.; self.wall=0; self.failed=0.

    def picture(self):
        if not self.lock.acquire(timeout=CAPTURE_SECONDS+.5):
            raise TimeoutError('snapshot busy')
        try:
            if self.frame and time.monotonic()-self.last<CACHE_SECONDS:
                return self.frame,self.wall
            if self.failed and time.monotonic()-self.failed<CACHE_SECONDS:
                raise ValueError('snapshot backing off')
            try:
                frame=self.capture(self.row,self.code,self.executable)
                if not (4<=len(frame)<=MAX_FRAME and frame[:2]==b'\xff\xd8' and frame[-2:]==b'\xff\xd9'):
                    raise ValueError('invalid snapshot')
            except Exception:
                self.frame=b'';self.failed=time.monotonic()
                raise ValueError('snapshot unavailable') from None
            self.frame,self.last,self.wall=frame,time.monotonic(),int(time.time())
            self.failed=0.
            return self.frame,self.wall
        finally:
            self.lock.release()


class Server(ThreadingHTTPServer):
    daemon_threads=True
    allow_reuse_address=True
    def __init__(self,address,sources):
        assert address[0]=='127.0.0.1'
        self.sources=sources
        self.slots=threading.BoundedSemaphore(8)
        super().__init__(address,Handler)

    def process_request(self,request,address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request,address)
        except BaseException:
            self.slots.release();raise

    def process_request_thread(self,request,address):
        try:
            super().process_request_thread(request,address)
        finally:
            self.slots.release()

    def handle_error(self,*args):
        pass  # Never dump a request, credential header, or decoder arguments.


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup();self.connection.settimeout(CAPTURE_SECONDS + 4)

    def log_message(self,*args):
        pass

    def reply(self,status,body=b'',captured=None):
        self.send_response(status)
        self.send_header('Content-Type','image/jpeg' if status==200 else 'text/plain')
        self.send_header('Content-Length',str(len(body)))
        self.send_header('Cache-Control','no-store')
        self.send_header('Connection','close')
        if captured is not None:
            self.send_header('X-Camera-Captured-At',str(captured))
        self.end_headers()
        self.wfile.write(body)
        self.close_connection=True

    def do_GET(self):
        match=re.fullmatch(r'/snapshot/([a-z0-9-]{1,32})\.jpg',self.path)
        source=self.server.sources.get(match[1]) if match else None
        tokens=self.headers.get_all('X-Printer-Camera-Code',[])
        if source is None or len(tokens)!=1 or not hmac.compare_digest(tokens[0].encode(),source.code.encode()):
            self.reply(403);return
        if self.headers.get('Transfer-Encoding') or self.headers.get('Content-Length','0')!='0':
            self.reply(400);return
        try:
            frame,wall=source.picture()
        except Exception:
            self.reply(503,b'Camera temporarily unavailable\n');return
        self.reply(200,frame,wall)


def load_sources(config,credentials,executable):
    rows=json.loads(Path(config).read_text())
    selected=[r for r in rows if r.get('camera')=='bambu-rtsps-snapshot']
    if not 1<=len(selected)<=4:
        raise ValueError('configure 1..4 snapshot printers')
    names={r['access_code_env'] for r in selected}
    codes={name:os.environ.get(name,'') for name in names}
    for line in Path(credentials).read_text().splitlines():
        line=line.strip()
        if line.startswith('export '):line=line[7:]
        key,sep,value=line.partition('=')
        if sep and key.strip() in names:
            codes[key.strip()]=value.strip().strip('"').strip("'")
    sources={}
    for row in selected:
        code=codes[row['access_code_env']]
        ipaddress.ip_address(row['host'])
        if not re.fullmatch('[a-z0-9-]{1,32}',row['id']) or row['id'] in sources:
            raise ValueError('invalid or duplicate printer id')
        if not row['tls_peer'] or not Path(row.get('camera_tls_ca',row['tls_ca'])).is_file():
            raise ValueError('invalid camera trust configuration')
        if not 1<=int(row.get('camera_port',322))<=65535:
            raise ValueError('invalid camera port')
        if not 1<=len(code)<=32 or not all(32<ord(c)<127 for c in code):
            raise ValueError('invalid camera credential configuration')
        sources[row['id']]=Source(row,code,executable)
    return sources


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',required=True)
    parser.add_argument('--credentials-env-file',required=True)
    parser.add_argument('--ffmpeg',required=True)
    parser.add_argument('--port',type=int,default=6741)
    args=parser.parse_args()
    try:
        if not Path(args.ffmpeg).is_absolute() or not os.access(args.ffmpeg,os.X_OK):
            raise ValueError('decoder unavailable')
        sources=load_sources(args.config,args.credentials_env_file,args.ffmpeg)
        with Server(('127.0.0.1',args.port),sources) as server:
            print('snapshot-ready '+str(server.server_port),flush=True)
            server.serve_forever(poll_interval=.2)
    except Exception:
        raise SystemExit('Snapshot adapter unavailable; check local configuration and decoder') from None


if __name__=='__main__':
    main()

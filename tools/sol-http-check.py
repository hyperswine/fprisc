#!/usr/bin/env python3
"""Loopback-only HTTP/TLS contracts. No public service, account or live secret.

The TLS key/certificates are the existing publicly committed test fixtures.
"""
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import platform
import re
import signal
import ssl
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlsplit

ROOT=Path(__file__).resolve().parents[1]
FPR=Path(os.environ.get('FPR_TEST_BINARY',ROOT/'fpr')).resolve()
FIXTURES=ROOT/'tests/fixtures/tls'
RAW=bytes(range(256))*1024


def lit(value):
    return json.dumps(str(value),ensure_ascii=False).replace('\\u0000','\\0').replace('{','\\{').replace('}','\\}')


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--benchmark',type=Path,help='measure only 100 MiB/1 GiB streamed download memory and throughput')
    args=parser.parse_args()
    checks=0; calls=Counter(); started=threading.Event(); disconnected=threading.Event()
    class Handler(BaseHTTPRequestHandler):
        protocol_version='HTTP/1.1'
        def log_message(self,*args): pass
        def reply(self,status,body=b'',headers=()):
            self.send_response(status)
            self.send_header('Content-Length',str(len(body)))
            self.send_header('Connection','close')
            for k,v in headers: self.send_header(k,v)
            self.end_headers()
            if self.command!='HEAD': self.wfile.write(body)
        def do_HEAD(self): self.do_GET()
        def do_POST(self):
            body=self.rfile.read(int(self.headers.get('Content-Length','0')))
            self.reply(201,body,[('X-Request',self.headers.get('X-Request',''))])
        do_PUT=do_POST
        do_PATCH=do_POST
        do_DELETE=do_POST
        def do_GET(self):
            path=urlsplit(self.path).path; calls[path]+=1
            try:
                if path=='/ok': self.reply(200,RAW,[('X-Dup','one'),('X-Dup','two'),('X-Latin','caf\xe9')])
                elif path=='/empty': self.reply(204)
                elif path=='/missing': self.reply(404,b'{"error":"missing"}')
                elif path=='/json': self.reply(200,'{"label":"λ😀","value":3}'.encode())
                elif path=='/badjson': self.reply(200,b'{"label":')
                elif path=='/wrongjson': self.reply(200,b'{"label":3}')
                elif path=='/redirect': self.reply(302,b'redirect',[('Location','/ok')])
                elif path=='/loop': self.reply(302,headers=[('Location','/loop')])
                elif path=='/badproto': self.reply(302,headers=[('Location','file:///no-sol-file')])
                elif path=='/downgrade': self.reply(302,headers=[('Location',plain+'/ok')])
                elif path=='/slow': time.sleep(1);self.reply(200,b'slow')
                elif path=='/counter': self.reply(200,b'x')
                elif path=='/headers': self.reply(200,b'x',[('X-Large','x'*4096)]*8)
                elif path=='/exactheaders': self.wfile.write(b'HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx')
                elif path=='/truncated': self.wfile.write(b'HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\nx')
                elif path.startswith('/large/'):
                    size=int(path.rsplit('/',1)[1]);self.send_response(200);self.send_header('Content-Length',str(size));self.send_header('Connection','close');self.end_headers()
                    block=bytes(range(256))*256
                    for _ in range(size//len(block)):self.wfile.write(block)
                elif path=='/interim':
                    self.wfile.write(b'HTTP/1.1 100 Continue\r\nX-Interim: ignored\r\n\r\n')
                    self.reply(200,b'final',[('X-Final','yes')])
                elif path=='/chunked':
                    self.send_response(200);self.send_header('Transfer-Encoding','chunked');self.send_header('Connection','close');self.end_headers()
                    for i in range(0,len(RAW),4093):
                        chunk=RAW[i:i+4093]
                        self.wfile.write(f'{len(chunk):x};test=yes\r\n'.encode()+chunk+b'\r\n')
                    self.wfile.write(b'0\r\nX-Trailer: done\r\n\r\n')
                elif path in ['/endless','/drip']:
                    self.send_response(200);self.send_header('Connection','close');self.end_headers();started.set()
                    try:
                        for _ in range(10000):
                            self.wfile.write(b'x'*8192 if path=='/endless' else b'x');self.wfile.flush();time.sleep(.005 if path=='/endless' else .1)
                    finally: disconnected.set()
                else: self.reply(400,b'unknown')
            except (BrokenPipeError,ConnectionResetError,ssl.SSLError): pass
            finally: self.close_connection=True
    plain_server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    tls_server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(FIXTURES/'servercert.pem',FIXTURES/'serverkey.pem')
    tls_server.socket=context.wrap_socket(tls_server.socket,server_side=True)
    plain=f'http://127.0.0.1:{plain_server.server_port}'
    secure=f'https://server.example:{tls_server.server_port}'
    threads=[threading.Thread(target=s.serve_forever,daemon=True) for s in [plain_server,tls_server]]
    for t in threads: t.start()
    try:
        with tempfile.TemporaryDirectory(prefix='sol-http-check-') as tmp:
            w=Path(tmp).resolve(); cache=w/'cache'; destination=w/'download'
            env={k:v for k,v in os.environ.items() if not k.startswith('SOL_')}
            env|={'SOL_GPU':'0','SOL_JIT':os.environ.get('FPR_TEST_JIT','1'),'SOL_CACHE_DIR':str(cache),'TMPDIR':str(w),'PATH':'/nonexistent'}
            imports=f'H = use {lit(ROOT/"sol/lib/http.sol")}.\n'
            def opts(ms=5000,body=1048576,headers=65536,redirect='NoRedirect',ca='',routes='[]'):
                return f'HttpOptions {ms} {body} {headers} ({redirect}) {lit(ca)} {routes}'
            tlsopts=opts(ca=FIXTURES/'rootcert.pem',routes=f'[HttpRoute "server.example" {tls_server.server_port} "127.0.0.1"]')
            def get(path,base=plain): return f'H.get {lit(base+path)}'
            if args.benchmark:
                samples=[]
                for size in [100*1024**2,1024**3]:
                    for repeat in range(3):
                        destination.unlink(missing_ok=True)
                        source=(imports+f'> r = Http.download ({opts(ms=120000,body=size)}) ({get("/large/"+str(size))}) {lit(destination)} False;'
                                f' case r of Ok (HttpInfo 200 headers n) -> if n == {size} then Unit else error "HTTP size"'
                                ' | Ok info -> error (str info) | Err e -> error (str e).\n')
                        script=w/'measure.sol';script.write_text(source)
                        command=['/usr/bin/time','-l' if platform.system()=='Darwin' else '-v',str(FPR),'sol',str(script)]
                        sampling=threading.Event();families=[];owned_peaks={};sampling_errors=[]
                        start=time.monotonic();p=subprocess.Popen(command,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,cwd=w)
                        def sample():
                            while not sampling.is_set():
                                try:
                                    rows=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,rss='],text=True,timeout=2)
                                    table={int(parts[0]):(int(parts[1]),int(parts[2])*1024) for line in rows.splitlines() if len(parts:=line.split())==3}
                                    owned={p.pid}
                                    while True:
                                        expanded=owned|{pid for pid,(parent,rss) in table.items() if parent in owned}
                                        if expanded==owned:break
                                        owned=expanded
                                    family={pid:table[pid][1] for pid in owned if pid in table}
                                    if family:
                                        families.append(sum(family.values()))
                                        for pid,rss in family.items():owned_peaks[pid]=max(owned_peaks.get(pid,0),rss)
                                except Exception as exc:sampling_errors.append(str(exc))
                                sampling.wait(.01)
                        monitor=threading.Thread(target=sample,daemon=True);monitor.start()
                        try: _,stderr=p.communicate(timeout=180)
                        finally:
                            sampling.set();monitor.join(3)
                            if p.poll() is None:p.kill();p.communicate()
                        wall=time.monotonic()-start
                        assert p.returncode==0 and families and not sampling_errors,(p.returncode,stderr,sampling_errors)
                        assert destination.stat().st_size==size
                        expected=hashlib.sha256();actual=hashlib.sha256();block=bytes(range(256))*256
                        for _ in range(size//len(block)):expected.update(block)
                        with destination.open('rb') as stream:
                            for chunk in iter(lambda:stream.read(1048576),b''):actual.update(chunk)
                        assert actual.digest()==expected.digest()
                        if repeat:
                            text=stderr.decode()
                            pattern=r'(\d+)\s+maximum resident set size' if platform.system()=='Darwin' else r'Maximum resident set size \(kbytes\):\s*(\d+)'
                            found=re.search(pattern,text);assert found,text
                            rss=int(found[1])*(1 if platform.system()=='Darwin' else 1024)
                            samples.append(dict(input_bytes=size,wall_seconds=wall,mib_per_second=size/1024**2/wall,reported_peak_rss_bytes=rss,
                                                sampled_peak_family_rss_bytes=max(families),sampled_per_pid_peak_rss_bytes=owned_peaks,command=command,source=source,stderr=text))
                            print(f'HTTP download: {size} bytes, {wall:.3f}s, reported RSS {rss/1024**2:.1f} MiB, sampled family {max(families)/1024**2:.1f} MiB',flush=True)
                small=max(s['sampled_peak_family_rss_bytes'] for s in samples if s['input_bytes']==100*1024**2)
                large=max(s['sampled_peak_family_rss_bytes'] for s in samples if s['input_bytes']==1024**3)
                report=dict(schema=1,host=platform.platform(),machine=platform.machine(),binary_sha256=hashlib.sha256(FPR.read_bytes()).hexdigest(),
                            source_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
                            source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [*sorted((ROOT/'compiler/Sol').glob('*.hs')),ROOT/'compiler/cbits/sol_http.c',ROOT/'compiler/Main.hs',ROOT/'fp-risc.cabal',ROOT/'sol/lib/http.sol',ROOT/'tools/sol-http-check.py']},
                            settings={'SOL_JIT':env['SOL_JIT'],'SOL_GPU':'0','PATH':'/nonexistent','warmups':1,'runs':2},
                            measurement='fresh process; system time RSS plus 10ms ps samples of only the timed process family (parent and native worker); independent streamed hashlib verification; local loopback',
                            samples=samples,gate=dict(small_family_peak_bytes=small,large_family_peak_bytes=large,growth_bytes=large-small,allowance_bytes=32*1024**2,passed=large-small<=32*1024**2))
                args.benchmark.parent.mkdir(parents=True,exist_ok=True);args.benchmark.write_text(json.dumps(report,indent=2)+'\n')
                assert report['gate']['passed'],report['gate']
                print('HTTP sampled family-memory growth gate passed:',args.benchmark,flush=True)
                return
            def run(source='',expected=None,code=0,error=None,extra=None,descriptors=None,script=None,args=()):
                nonlocal checks
                path=w/'main.sol';path.write_text(imports+source)
                def limited():
                    _,hard=resource.getrlimit(resource.RLIMIT_NOFILE);resource.setrlimit(resource.RLIMIT_NOFILE,(descriptors,hard))
                p=subprocess.run([str(FPR),'sol',str(script or path),*map(str,args)],env=env|(extra or {}),capture_output=True,timeout=20,preexec_fn=limited if descriptors else None,cwd=w)
                assert p.returncode==code and (expected is None or p.stdout==expected),(source,p)
                if error is not None: assert error in p.stderr,(source,p)
                checks+=1;return p
            show='reason result = case result of Err (HttpError kind code text) -> print kind | Ok value -> print "ok".\n'
            run('> print (isOk (Http.backend Unit)).\n',b'True\n')
            run(f'> HttpResponse status headers body = unwrapHttp (Http.request ({opts()}) ({get("/ok")})); IO.stdout body.\n'
                'unwrapHttp r = case r of Ok v -> v | Err e -> error (str e).\n',RAW)
            run('unwrapHttp r = case r of Ok v -> v | Err e -> error (str e).\n'+f'> HttpResponse status headers body = unwrapHttp (Http.request ({opts()}) ({get("/ok")})); print (status,H.header "X-Dup" headers,H.header "x-latin" headers,Bytes.len body).\n',
                '(200, [one, two], [café], 262144)\n'.encode())
            run(show+f'> reason (Http.request ({opts()}) ({get("/missing")})).\n',b'ok\n')
            run('unwrapHttp r = case r of Ok v -> v | Err e -> error (str e).\n'+f'> HttpResponse status headers body = unwrapHttp (Http.request ({opts()}) ({get("/missing")})); printed = print status; IO.stdout body.\n',b'404\n{"error":"missing"}')
            run('unwrapHttp r = case r of Ok v -> v | Err e -> error (str e).\n'+f'> HttpResponse status headers body = unwrapHttp (Http.request ({opts(body=0)}) (H.head {lit(plain+"/ok")})); print (status,Bytes.len body).\n',b'(200, 0)\n')
            run('unwrapHttp r = case r of Ok v -> v | Err e -> error (str e).\n'+f'> HttpResponse status headers body = unwrapHttp (Http.request ({opts()}) ({get("/chunked")})); printed = print (status,Bytes.len body,H.header "x-trailer" headers); IO.stdout body.\n',
                b'(200, 262144, [done])\n'+RAW)
            run(show+f'> reason (Http.request ({opts(body=262143)}) ({get("/ok")})).\n',b'HttpLimit\n')
            run(show+f'> reason (Http.request ({opts(body=262144)}) ({get("/chunked")})).\n',b'ok\n')
            run(show+f'> reason (Http.request ({opts(body=262143)}) ({get("/chunked")})).\n',b'HttpLimit\n')
            run(show+f'> reason (Http.request ({opts(body=0)}) ({get("/empty")})).\n',b'ok\n')
            run(show+f'> reason (Http.request ({opts(body=0)}) ({get("/ok")})).\n',b'HttpLimit\n')
            run(show+f'> reason (Http.request ({opts(headers=100)}) ({get("/headers")})).\n',b'HttpLimit\n')
            run(show+f'> reason (Http.request ({opts(headers=0)}) ({get("/empty")})).\n',b'HttpLimit\n')
            exact=len(b'HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\n')
            run(show+f'> reason (Http.request ({opts(headers=exact)}) ({get("/exactheaders")})).\n',b'ok\n')
            run(show+f'> reason (Http.request ({opts(headers=exact-1)}) ({get("/exactheaders")})).\n',b'HttpLimit\n')
            run(show+f'> reason (Http.request ({opts()}) ({get("/truncated")})).\n',b'HttpTransport\n')
            run('unwrapHttp r = case r of Ok v -> v | Err e -> error (str e).\n'+f'> HttpResponse status headers body = unwrapHttp (Http.request ({opts()}) ({get("/interim")})); printed = print (H.header "x-interim" headers,H.header "x-final" headers); IO.stdout body.\n',b'([], [yes])\nfinal')
            # Non-2xx remains inspectable; redirect policies are explicit.
            run('unwrapHttp r = case r of Ok v -> v | Err e -> error (str e).\n'+f'> HttpResponse status headers body = unwrapHttp (Http.request ({opts()}) ({get("/redirect")})); print (status,Bytes.len body).\n',b'(302, 8)\n')
            run('unwrapHttp r = case r of Ok v -> v | Err e -> error (str e).\n'+f'> HttpResponse status headers body = unwrapHttp (Http.request ({opts(redirect="RedirectHttp 2")}) ({get("/redirect")})); IO.stdout body.\n',RAW)
            run(show+f'> reason (Http.request ({opts(redirect="RedirectHttp 2")}) ({get("/loop")})).\n',b'HttpRedirect\n')
            run(show+f'> reason (Http.request ({opts(redirect="RedirectHttp 2")}) ({get("/badproto")})).\n',b'HttpRedirect\n')
            run(show+f'> reason (Http.request ({opts(redirect="RedirectHttps 2")}) ({get("/redirect")})).\n',b'HttpRedirect\n')
            run(show+f'> reason (Http.request ({tlsopts}) ({get("/ok",secure)})).\n',b'ok\n')
            replacement=(f'H.defaultOptions |> H.withCA {lit(FIXTURES/"rootcert.pem")} '
                         f'|> H.withRoute "server.example" {tls_server.server_port} "127.0.0.2" '
                         f'|> H.withRoute "SERVER.EXAMPLE" {tls_server.server_port} "127.0.0.1"')
            run(show+f'> reason (Http.request ({replacement}) ({get("/ok",secure)})).\n',b'ok\n')
            no_ca=opts(routes=f'[HttpRoute "server.example" {tls_server.server_port} "127.0.0.1"]')
            run(show+f'> reason (Http.request ({no_ca}) ({get("/ok",secure)})).\n',b'HttpTls\n')
            run(show+f'> reason (Http.request ({tlsopts}) ({get("/ok",f"https://127.0.0.1:{tls_server.server_port}")})).\n',b'HttpTls\n')
            downgrade=opts(redirect='RedirectHttps 2',ca=FIXTURES/'rootcert.pem',routes=f'[HttpRoute "server.example" {tls_server.server_port} "127.0.0.1"]')
            run(show+f'> reason (Http.request ({downgrade}) ({get("/downgrade",secure)})).\n',b'HttpRedirect\n')
            # Raw binary upload plus exact raw header value, without a shell.
            run('unwrapHttp r = case r of Ok v -> v | Err e -> error (str e).\n'+f'> body = unwrap (Bytes.fromList (List.range 0 255)); req = HttpRequest "POST" {lit(plain+"/echo")} [("X-Request","a b;$(no)*")] body; HttpResponse status headers out = unwrapHttp (Http.request ({opts()}) req); printed = print (status,H.header "x-request" headers); IO.stdout out.\n',
                b'(201, [a b;$(no)*])\n'+bytes(range(256)))
            for invalid in [opts(ms=0),opts(body=-1),opts(body=16777217),opts(headers=1048577),opts(redirect='RedirectHttp 21'),opts(redirect='RedirectHttp (0 - 1)')]:
                run(show+f'> reason (Http.request ({invalid}) ({get("/ok")})).\n',b'HttpInvalid\n')
            for req in [f'HttpRequest "GET" "file:///no-file" [] (Bytes.empty Unit)',
                        f'HttpRequest "GET" "http://user:pass@127.0.0.1/" [] (Bytes.empty Unit)',
                        f'HttpRequest "GET" {lit(plain)} [("X-Bad","a\\nb")] (Bytes.empty Unit)',
                        f'HttpRequest "GET" {lit(plain)} [("Content-Length","1")] (Bytes.empty Unit)',
                        f'HttpRequest "GET" {lit(plain)} [(Str.repeat 257 "x","value")] (Bytes.empty Unit)',
                        f'HttpRequest "GET" {lit(plain)} [("X-Long",Str.repeat 8193 "x")] (Bytes.empty Unit)',
                        f'HttpRequest "HEAD" {lit(plain)} [] (unwrap (Utf8.encode "body"))']:
                run(show+f'> reason (Http.request ({opts()}) ({req})).\n',b'HttpInvalid\n')
            # A slow peer is bounded even before headers or during body transfer.
            for path in ['/slow','/drip']:
                t=time.monotonic()
                run(show+f'> reason (Http.request ({opts(ms=150)}) ({get(path)})).\n',b'HttpTimeout\n')
                assert time.monotonic()-t<3
            # Download publication and errors preserve an existing destination.
            run(show+f'> reason (Http.download ({opts()}) ({get("/ok")}) {lit(destination)} False).\n',b'ok\n')
            assert destination.read_bytes()==RAW
            destination.write_bytes(b'old');destination.chmod(0o640)
            run(show+f'> reason (Http.download ({opts()}) ({get("/ok")}) {lit(destination)} False).\n',b'HttpIo\n')
            for path,options,reason in [('/missing',opts(),'HttpStatus'),('/slow',opts(ms=150),'HttpTimeout'),('/endless',opts(body=1024),'HttpLimit')]:
                run(show+f'> reason (Http.download ({options}) ({get(path)}) {lit(destination)} True).\n',(reason+'\n').encode())
                assert destination.read_bytes()==b'old'
            run(show+f'> reason (Http.download ({opts()}) ({get("/chunked")}) {lit(destination)} True).\n',b'ok\n')
            assert destination.read_bytes()==RAW and destination.stat().st_mode & 0o777==0o640
            # Guarded replay counts network attempts; known-repeatable opt-in is
            # separate from output validation and from GET's method name.
            buffered=w/'buffered';before=calls['/counter']
            run(f'> r = Http.request ({opts()}) ({get("/counter")}); writePath {lit(buffered)} "x".\n',code=1,error=b'guarded retry refused',extra={'SOL_FORCE_RETRY':'2'})
            assert calls['/counter']==before+1 and not buffered.exists()
            run(f'> r = Script.replayable (fn u -> Http.request ({opts()}) ({get("/counter")})); writePath {lit(buffered)} "x".\n',extra={'SOL_FORCE_RETRY':'2'})
            assert calls['/counter']==before+4 and buffered.read_text()=='x'
            before=calls['/counter']
            run(show+f'> u = writePath {lit(buffered)} "queued"; reason (Http.request ({opts()}) ({get("/counter")})).\n',b'HttpInvalid\n')
            assert calls['/counter']==before
            # Actor cancellation and Ctrl-C close a live connection and wait for
            # the owned worker; unpublished download destinations remain intact.
            started.clear();disconnected.clear()
            run(f'worker parent self = r = Http.request ({opts(ms=10000,body=16777216)}) ({get("/endless")}); send parent Unit.\n'
                '> me = myself 0; child = spawn (worker me); u = sleepMs 300; k = kill child; print "cancelled".\n',b'cancelled\n')
            assert started.is_set() and disconnected.wait(3)
            started.clear();disconnected.clear();destination.write_bytes(b'old')
            path=w/'interrupt.sol';path.write_text(imports+f'> Http.download ({opts(ms=10000,body=1099511627776)}) ({get("/endless")}) {lit(destination)} True.\n')
            p=subprocess.Popen([str(FPR),'sol',str(path)],env=env,cwd=w,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            try:
                assert started.wait(5),'HTTP worker did not connect'
                p.send_signal(signal.SIGINT);out,err=p.communicate(timeout=5)
                assert p.returncode==130 and b'interrupted' in err,(p.returncode,out,err)
            finally:
                if p.poll() is None:p.kill();p.communicate()
            assert disconnected.wait(3) and destination.read_bytes()==b'old'
            checks+=1
            run(f'one n i = r = Http.request ({opts(body=0)}) ({get("/empty")}); n + (if isOk r then 1 else 0).\n> print (List.fold one 0 (List.range 1 30)).\n',b'30\n',descriptors=96)
            run(script=ROOT/'sol/scripts/http-fetch.sol',args=[plain+'/ok',w/'script-body'],expected=b'HTTP 200: 262144 bytes\n')
            assert (w/'script-body').read_bytes()==RAW
            transformed=w/'transformed';transformed.write_bytes(b'old');transformed.chmod(0o640)
            run(script=ROOT/'sol/scripts/http-json-field.sol',args=['label',plain+'/json',transformed],expected=b'')
            assert transformed.read_text()=='λ😀\n' and transformed.stat().st_mode & 0o777==0o640
            for endpoint in ['/badjson','/wrongjson','/missing']:
                before=transformed.read_bytes()
                run(script=ROOT/'sol/scripts/http-json-field.sol',args=['label',plain+endpoint,transformed],code=1,error=b'SOL PANIC')
                assert transformed.read_bytes()==before
            assert not list(w.glob('sol-http-*')) and not list(w.glob('.sol-stage-*')),'HTTP scratch/staging leaked'
    finally:
        for s in [plain_server,tls_server]:s.shutdown();s.server_close()
        for t in threads:t.join(3)
    print(f'sol HTTP/TLS: {checks} checks passed (loopback fixtures, owned worker, empty PATH)')


if __name__=='__main__':main()

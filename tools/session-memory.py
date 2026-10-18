#!/usr/bin/env python3
"""Profile the real QOS Liveboard with an explicit, benchmark-only snapshot hook.

The copied source changes only the existing Mem action. Counters are cumulative;
reserved arena and peak RSS are not logical-live bytes. Does not touch deployment.
"""
import argparse, hashlib, importlib.util, json, os, platform, shutil, socket, subprocess, sys, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def command(args,env,timeout=240):
    p=subprocess.run(list(map(str,args)),cwd=ROOT,env=env,text=True,capture_output=True,timeout=timeout)
    assert p.returncode==0,p.stdout+p.stderr
    return p.stdout+p.stderr

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--qos',type=Path,default=ROOT.parent/'qos')
    ap.add_argument('--sessions',type=int,nargs='+',default=[1,10,50,100])
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--sample',action='store_true',help='capture a five-second macOS CPU sample during session admission')
    ap.add_argument('--binary',type=Path,help='profile an already-built matching probe')
    a=ap.parse_args()
    if any(n < 1 for n in a.sessions):ap.error('sessions must be positive')
    if a.sample and (sys.platform != 'darwin' or not shutil.which('sample')):ap.error('--sample requires macOS sample')
    a.output=a.output.resolve(); a.qos=a.qos.resolve(); a.output.mkdir(parents=True,exist_ok=False)
    env=dict(os.environ,FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_COST_PROBE='1',XDG_CACHE_HOME=str(a.output/'cache'))
    env.pop('FPR_FOREIGN',None)
    source=(a.qos/'programs/liveboard.fpr').read_text()
    old='case Sys.memInfo 0 of arena :: free :: _ -> "heap in use {(arena - free) / 1024} MiB" | _ -> "?"'
    assert old in source
    source=source.replace(old,'SessionProbe.snapshot Unit')+'\nSessionProbe.snapshot : Unit -> String .\n'
    src=a.output/'liveboard-probe.fpr'; src.write_text(source)
    exe=a.output/'liveboard-probe'
    args=[ROOT/'fpr','build',src,'--harts','4','--with',ROOT/'tests/bench/sessionprobe.c','-o',exe]
    if a.binary: exe=a.binary.resolve()
    else: (a.output/'build.log').write_text(command(args,env))
    metadata=dict(platform=platform.platform(),binary=str(exe),binary_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),
                  source_sha256=hashlib.sha256(source.encode()).hexdigest(),prebuilt_binary=bool(a.binary),
                  checkout_head=command(['git','rev-parse','HEAD'],env).strip(),harts=4,heap_mb=2048,
                  checkout_runtime_sha256=hashlib.sha256((ROOT/'runtime/runtime.c').read_bytes()).hexdigest(),
                  checkout_std_sha256={name:hashlib.sha256((ROOT/'std'/name).read_bytes()).hexdigest() for name in ('view.fpr','encoding.fpr')},
                  websocket_client_sha256=hashlib.sha256((a.qos/'tools/freebsd-vm/server-check.py').read_bytes()).hexdigest())
    (a.output/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
    (a.output/'runtime.patch').write_text(command(['git','diff','--','runtime'],env))
    (a.output/'stdlib.patch').write_text(command(['git','diff','--','std'],env))
    spec=importlib.util.spec_from_file_location('freebsd_server_check',a.qos/'tools/freebsd-vm/server-check.py')
    ws=importlib.util.module_from_spec(spec)
    saved=sys.argv
    try:
        sys.argv=[str(a.qos/'tools/freebsd-vm/server-check.py')];spec.loader.exec_module(ws)
    finally:sys.argv=saved
    def probe_value(value):
        if isinstance(value,str) and value.startswith('session-probe:'): return json.loads(value[len('session-probe:'):])
        if isinstance(value,(dict,list)):
            for item in (value.values() if isinstance(value,dict) else value):
                result=probe_value(item)
                if result is not None:return result
    with socket.socket() as s: s.bind(('127.0.0.1',0));port=s.getsockname()[1]
    conns=[]; results=[]; admission_seconds=0
    with (a.output/'server.log').open('w') as log:
        p=subprocess.Popen([str(exe),f'--port={port}',f'--store={a.output/"store"}'],cwd=a.output,env=dict(env,FPR_HARTS='4',FPR_HEAP_MB='2048'),stdout=log,stderr=subprocess.STDOUT)
        sampler=None
        try:
            for _ in range(300):
                assert p.poll() is None,(a.output/'server.log').read_text()
                if 'ready' in (a.output/'server.log').read_text():break
                time.sleep(.05)
            else:raise AssertionError('server readiness timed out')
            if a.sample:
                sampler=subprocess.Popen(['sample',str(p.pid),'5','1','-file',str(a.output/'cpu-sample.txt')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            for count in sorted(set(a.sessions)):
                started=time.monotonic()
                while len(conns)<count:
                    c=ws.Ws(port);conns.append(c);c.recv()
                admission_seconds+=time.monotonic()-started
                time.sleep(.2)
                conns[0].send('Mem')
                deadline=time.monotonic()+20
                while True:
                    row=probe_value(conns[0].recv(max(.1,deadline-time.monotonic())))
                    if row is not None:break
                    assert time.monotonic()<deadline,'no memory snapshot'
                row['sessions']=count;row['admission_seconds']=round(admission_seconds,6);results.append(row)
                print(json.dumps(row),flush=True)
            conns[0].send('Bump',989789)
            for c in conns:c.until(lambda frame:ws.has(frame,'"989789"'))
            print('All sessions received shared update',flush=True)
            if sampler:assert sampler.wait(timeout=10)==0,'CPU sample failed'
        finally:
            if sampler and sampler.poll() is None:
                sampler.terminate();sampler.wait(timeout=5)
            for c in conns:c.s.close()
            p.terminate()
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.wait(timeout=5)
    (a.output/'results.json').write_text(json.dumps(results,indent=2)+'\n')
if __name__=='__main__':main()

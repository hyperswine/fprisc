#!/usr/bin/env python3
"""Cache invariants and the real logbook under cached-vs-fresh verification.
Uses the existing compiler binary. No public server or real store is touched.
"""
from pathlib import Path
import os, re, subprocess, sys, tempfile, time
from check_live_wire import Client, has, settled
ROOT = Path(__file__).resolve().parents[1]

def run(args, expected=0, env=None):
    p = subprocess.run([str(x) for x in args], cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=180)
    assert p.returncode == expected, (args,p.returncode,p.stdout,p.stderr)
    return p.stdout+p.stderr

with tempfile.TemporaryDirectory(prefix='viewcache-') as directory:
    tmp=Path(directory)
    env={**os.environ,'FPR_HOME':str(ROOT),'XDG_CACHE_HOME':str(tmp/'cache')}
    unit=tmp/'unit';app=tmp/'logbook'
    run([ROOT/'fpr','build','tests/base/viewcache.fpr','-o',unit],env=env)
    assert 'cache: hits skip rendering' in run([unit])
    assert 'ViewCache: stale output for 1' in run([unit,'stale'],1)
    assert 'ViewCache: duplicate key 1' in run([unit,'duplicate'],1)
    run([ROOT/'fpr','build','examples/logbook.fpr','-o',app],env=env)
    for verify in ('0','1'):
        result=run([sys.executable,'tests/check_live_wire.py',app],env={**env,'FPR_VIEW_VERIFY':verify})
        assert 'PASS:' in result
    # Existing applications keep the original stateless Live.serve interface.
    stateless_source=tmp/'stateless.fpr'
    source=(ROOT/'examples/logbook.fpr').read_text()
    call='Live.serveProjected cfg (cachedApp (Program.envOr "0" "FPR_VIEW_VERIFY" == "1"))'
    assert call in source
    stateless_source.write_text(source.replace(call,'Live.serve cfg app'))
    stateless=tmp/'stateless'
    run([ROOT/'fpr','build',stateless_source,'-o',stateless],env=env)
    assert 'PASS:' in run([sys.executable,'tests/check_live_wire.py',stateless],env=env)
    # Drive enough entries to leave and re-enter the cache's visible page.
    with (tmp/'server.log').open('w+') as log:
        p=subprocess.Popen([str(app),'--port=0','--store='+str(tmp/'store')],
                           stdout=log,stderr=log,env={**env,'FPR_VIEW_VERIFY':'1'})
        clients=[]
        try:
            for _ in range(200):
                log.seek(0);match=re.search(r'ready (\d+)',log.read())
                if match:break
                if p.poll() is not None:raise AssertionError('server exited')
                time.sleep(.05)
            else:raise TimeoutError('server startup')
            port=int(match[1]);a=Client(port,True);clients.append(a);b=Client(port,True);clients.append(b)
            for i in range(25):
                text=f'cache-entry-{i:02}'
                a.send('Add','test|'+text)
                for c in (a,b):c.until(lambda st:has(st,text))
            a.send('Page',1)
            a.until(lambda st:has(st,'page 2 of 2') and has(st,'cache-entry-00'))
            a.send('Search','cache-entry-07')
            a.until(lambda st:has(st,'cache-entry-07') and not has(st,'cache-entry-00') and not has(st,'cache-entry-24'))
            b.send('Edit',25)
            b.until(lambda st:has(st,'editing'))
            b.send('Save',25,'changed|edited while another session searched')
            b.until(lambda st:has(st,'edited while another session searched') and not has(st,'editing'))
            a.send('Search','')
            a.until(lambda st:has(st,'edited while another session searched') and has(st,'page 1 of 2'))
            # toasts are per session now: b's "saved #25" is b's alone, so compare once it clears
            for c in (a,b):c.until(settled)
            assert a.state==b.state
            # A fresh session must reconstruct the same page without a prior cache.
            c=Client(port,True);clients.append(c)
            assert has(c.state,'edited while another session searched')
            assert p.poll() is None
        finally:
            for c in clients:c.close()
            p.terminate()
            try:p.wait(timeout=10)
            except subprocess.TimeoutExpired:p.kill();p.wait()
        log.seek(0);assert 'PANIC' not in log.read()
print('View cache: unit invariants, rejected stale/duplicate keys, normal/verification/stateless wire modes, pagination/search eviction and session isolation: PASS')

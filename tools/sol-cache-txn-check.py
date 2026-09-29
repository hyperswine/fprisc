#!/usr/bin/env python3
"""Content-addressed module caching and exact-byte transaction validation."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT/'fpr')).resolve()


def main():
    with tempfile.TemporaryDirectory(prefix='sol-cache-txn-') as tmp:
        w=Path(tmp); cache=w/'cache'; module=w/'helper.sol'; script=w/'main.sol'
        env={k:v for k,v in os.environ.items() if not k.startswith('SOL_')}
        env.update(SOL_CACHE_DIR=str(cache),SOL_CACHE_TRACE='1',SOL_JIT='0',SOL_GPU='0')
        module.write_text('answer = 42.\n')
        script.write_text('h = use "helper.sol".\n> print "{h.answer}".\n')
        def run(expected=b'42\n', code=0):
            p=subprocess.run([str(FPR),'sol',str(script)],env=env,capture_output=True,timeout=15)
            assert p.returncode==code and p.stdout==expected,p
            return p
        run()
        originals={entry:entry.read_bytes() for entry in (cache/'modules').glob('*.cache')}
        assert len(originals)==2
        p=run();assert b'[sol cache] hit' in p.stderr
        for entry, original in originals.items():
            for broken in (b'', original[:-1], bytes([original[0]^1])+original[1:]):
                entry.write_bytes(broken)
                p=run();assert b'[sol cache] hit' in p.stderr and entry.read_bytes()==original
        # Invalid source is not made valid by either warm cache tier.
        st=module.stat();module.write_text('answer = ).\n');os.utime(module,ns=(st.st_atime_ns,st.st_mtime_ns))
        p=run(b'',1);assert b'does not parse' in p.stderr
        module.write_text('answer = 42.\n')
        p=run();assert b'[sol cache] hit' in p.stderr
        # Prelude parsing must be absent from a warm hit, present on a miss.
        timed=env|{'SOL_TIMINGS':'1'}
        p=subprocess.run([str(FPR),'sol',str(script)],env=timed,capture_output=True,timeout=15)
        assert p.returncode==0 and b'prelude-parse' not in p.stderr,p
        for file in cache.glob('*.cache'):file.unlink()
        p=subprocess.run([str(FPR),'sol',str(script)],env=timed,capture_output=True,timeout=15)
        assert p.returncode==0 and b'prelude-parse' in p.stderr,p
        # Both FF and FE decode to U+FFFD in the previous implementation. Their
        # equal size/mtime must not hide a content change during a transaction.
        data=w/'binary';data.write_bytes(b'\xff')
        helper=w/'mutate.py';helper.write_text('import os,sys\np=sys.argv[1]\nst=os.stat(p)\nopen(p,"wb").write(bytes([254]))\nos.utime(p,ns=(st.st_atime_ns,st.st_mtime_ns))\n')
        script.write_text(f'> r = Try.readPath @{data}; u = print "attempt"; q = Proc.query (ProcessSpec ["{sys.executable}", "{helper}", "{data}"] "" [] "" 1000); print "done".\n')
        p=run(b'attempt\ndone\nattempt\ndone\n');assert b'retrying (attempt 2)' in p.stderr,p
        assert data.read_bytes()==b'\xfe'
        # Exact validation still permits an unchanged binary snapshot.
        p=run(b'attempt\ndone\n');assert b'retrying' not in p.stderr,p
    print('sol module-cache/transaction checks: corruption, invalidation, prelude bypass, exact binary conflicts passed')


if __name__=='__main__':main()

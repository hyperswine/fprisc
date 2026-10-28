#!/usr/bin/env python3
"""Exercise the aggregate durable-capture boundary with actual deferred work."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FPR = Path(os.environ.get('FPR_TEST_BINARY', ROOT/'fpr')).resolve()


def lit(value):
    return json.dumps(str(value)).replace('{', '\\{').replace('}', '\\}')


with tempfile.TemporaryDirectory(prefix='sol-receipts-') as tmp:
    w = Path(tmp).resolve()
    marker = w/'counter'
    landed = w/'landed'
    helper = w/'produce.py'
    helper.write_text('import os,sys\nwith open(sys.argv[1],"a") as f: f.write("x")\n'
                      'os.write(1,b"o"*1048576)\nos.write(2,b"e"*1048576)\n')
    spec = 'ProcessSpec ['+','.join(map(lit,[sys.executable,helper,marker]))+'] "" [] "" 10000'
    script = w/'receipt.sol'
    script.write_text(f'> file = writePath {lit(landed)} "committed"; '+
                      ''.join(f's{i} = Proc.afterCommit ({spec}); ' for i in range(9))+'Unit.\n')
    env = {k:v for k,v in os.environ.items() if not k.startswith('SOL_')}
    env |= {'SOL_GPU':'0','SOL_JIT':'0','SOL_CACHE_DIR':str(w/'cache')}
    with (w/'out').open('wb') as out, (w/'err').open('wb') as err:
        p = subprocess.run([str(FPR),'sol',str(script)],env=env,stdout=out,stderr=err,timeout=600)
    diagnostic = (w/'err').read_bytes()
    assert p.returncode == 1 and b'deferred receipt capture budget exceeded' in diagnostic, (p,diagnostic[-4096:])
    assert b'skipping queued process' in diagnostic and marker.read_text() == 'x'*8, diagnostic[-4096:]
    assert (w/'out').stat().st_size == 7*1048576
    assert landed.read_text() == 'committed'
    assert not list(w.glob('receipt.soljournal.*')), 'completed failure left receipt/spool files'
print('sol receipt budget: 14 MiB retained, next 2 MiB saved as failure, following process fenced, files committed and receipts cleaned')

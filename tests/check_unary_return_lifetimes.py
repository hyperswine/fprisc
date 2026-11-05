#!/usr/bin/env python3
"""Dynamic unary payloads survive region exits, nested calls and actor copying."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from check_product_returns import ROOT, run

COUNT = 128
CHURN = 64
SOURCE = f'''unsafe base.
Cell a = Type (Cell a).
makePayload n = Cell [n,n + 1].
churnPayload n = if n <= 0 then 0 else case makePayload n of Cell ys ->
  case ys of [a,b] -> a + b + churnPayload (n - 1) | _ -> error "bad churn payload".
consumePayload n = case makePayload n of Cell xs ->
  noise = churnPayload {CHURN};
  case xs of [a,b] -> a * 100 + b + noise | _ -> error "lost payload".
loopPayload n acc = if n <= 0 then acc else loopPayload (n - 1) (acc + consumePayload n).
payloadActor parent self = n = receive self;
  payload = case makePayload n of Cell xs -> xs;
  noise = churnPayload {CHURN};
  _ = if noise == {CHURN*(CHURN+2)} then Unit else error "bad actor churn";
  send parent (payload,payload).
main = _ = print (loopPayload {COUNT} 0); me = myself 0;
  a = spawn (payloadActor me); _ = send a 7; print (receiveFrom me a).
'''
EXPECTED = str(101*COUNT*(COUNT+1)//2 + COUNT*(1+CHURN*(CHURN+2)))+'\n([7, 8], [7, 8])\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--compiler', type=Path, default=ROOT/'fpr')
    ap.add_argument('--old', action='store_true')
    ap.add_argument('--target', choices=['macos-x86_64'])
    ap.add_argument('--record', type=Path)
    args = ap.parse_args()
    rows = []
    with tempfile.TemporaryDirectory(prefix='fpr-unary-lifetime-') as directory:
        tmp = Path(directory)
        src = tmp/'payload.fpr'; src.write_text(SOURCE)
        base = {k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
        base.update(FPR_HOME=str(ROOT), FPR_PATH=str(ROOT), XDG_CACHE_HOME=str(tmp/'cache'))
        for normal in (False,True):
            for isolated in (False,True):
                counts = {}
                for enabled in (False,True):
                    env = dict(base)
                    if not normal: env['FPR_NO_INLINE']='1'
                    if not enabled: env['FPR_NO_PAIR_RETURNS']='1'
                    if isolated:
                        env.update(FPR_NO_LOOP_REGIONS='1',FPR_NO_CALL_REGIONS='1',FPR_COST_PROBE='1',FPR_COST_REPORT='1')
                    exe = tmp/f'payload-{normal}-{isolated}-{enabled}'
                    p = run([args.compiler,'build',*(['--target='+args.target] if args.target else []),
                             src,'--harts','4','-o',exe],env)
                    assert p.returncode==0,(p.stdout,p.stderr)
                    for harts in (1,4):
                        p = run([exe],dict(env,FPR_HARTS=str(harts)))
                        assert p.returncode==0 and p.stdout==EXPECTED,(normal,isolated,enabled,harts,p)
                        row = dict(normal_inline=normal,isolated=isolated,enabled=enabled,harts=harts,stdout=p.stdout)
                        if isolated:
                            ledger=json.loads(re.search(r'\[fpr cost\] (\{.*\})',p.stderr)[1])
                            row['allocations']=ledger['alloc_requests']
                            if harts==1: counts[enabled]=row['allocations']
                        else: assert not p.stderr,p.stderr
                        rows.append(row)
                if isolated and not normal:
                    # Every loop invocation, its CHURN calls, and the actor's
                    # payload/churn construct one wrapper. Actual list cells
                    # and message storage remain necessary in both modes.
                    expected_removal=0 if args.old else (COUNT+1)*(CHURN+1)
                    assert counts[False]-counts[True]==expected_removal,counts
                print('Unary payload lifetime:',normal,isolated,counts,'1/4 harts PASS',flush=True)
    if args.record:
        sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
        args.record.write_text(json.dumps(dict(compiler_sha256=sha(args.compiler),test_sha256=sha(Path(__file__)),
            source_sha256=hashlib.sha256(SOURCE.encode()).hexdigest(),target=args.target,old=args.old,rows=rows),indent=2)+'\n')


if __name__=='__main__': main()

#!/usr/bin/env python3
"""Paired opt-in runtime ledgers and uninstrumented throughput measurements.

Writes JSON to stdout; never updates the performance ratchet baseline.
"""
import argparse,json,os,statistics,subprocess,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
HEADER='''Cost.begin : Unit -> Unit .
Cost.report : Unit -> String .
Cost.allocs : Int -> Int -> Int .
Cost.payload : Int -> String .
'''
def run(args,env,timeout=180):
 p=subprocess.run([str(x) for x in args],cwd=ROOT,env=env,capture_output=True,text=True,timeout=timeout)
 assert p.returncode==0,f'{args}: {p.returncode}\n{p.stdout}{p.stderr}'
 return p.stdout
ap=argparse.ArgumentParser();ap.add_argument('--runs',type=int,default=5);ap.add_argument('--harts',type=int,nargs='+',default=[1,2]);ap.add_argument('--quick',action='store_true');a=ap.parse_args()
assert a.runs>0 and all(1<=h<=8 for h in a.harts)
base={**os.environ,'FPR_HOME':str(ROOT),'FPR_PATH':str(ROOT),'FPR_HARTS':'1'};base.pop('FPR_FOREIGN',None)
run(['make','fpr'],base)
results=[]
with tempfile.TemporaryDirectory(prefix='fpr-cost-') as d:
 tmp=Path(d)
 for harts,kind in [(1,'alloc')]+[(h,'message') for h in a.harts]:
  for size in (16,256,4096):
   n=(4096 if kind=='alloc' else 256) if a.quick else (50000000 if kind=='alloc' else 200000)
   if kind=='alloc':
    body=f'main = _ = Cost.begin Unit; sum = Cost.allocs {n} {size}; stats = Cost.report Unit; _ = print "check: {{sum}}"; print stats.\n'
    expected=f'check: {(n//256)*32640 + sum(range(n%256))}'
   else:
    body='''worker : unsafe Int -> Int -> Unit .
worker boss self = m = receive self; _ = send boss (strlen m); _ = drop m; worker boss self.
loop : unsafe Int -> Int -> Int -> String -> Int -> Int .
loop me w n payload acc = if n == 0 then acc else
  r = send w payload;
  ok = case r of Ok _ -> True | Err why -> error why;
  m = receiveFrom me w;
  out = acc + m;
  _ = drop m;
  loop me w (n - 1) payload out.
'''+f'''main = me = myself 0; payload = Cost.payload {size}; w = spawnOn {harts-1} (worker me);
  _ = Cost.begin Unit; sum = loop me w {n} payload 0;
  _ = kill w; stats = Cost.report Unit; _ = print "check: {{sum}}"; print stats.
'''
    expected=f'check: {n*size}'
   src=tmp/'cost.fpr';src.write_text(HEADER+body)
   times=[[],[]];ledgers=[]
   for probe in (False,True):
    exe=tmp/f'{kind}-{size}-{probe}'
    args=['./fpr','build',src,'--harts',str(max(a.harts)),'--with',ROOT/'tests/bench/costprobe.c','-o',exe]
    probe_env={**base,'FPR_HARTS':str(harts),'FPR_COST_PROBE':'1' if probe else '0'}
    run(args,probe_env)
    for _ in range(a.runs):
     start=time.perf_counter();out=run([exe],probe_env);times[probe].append(time.perf_counter()-start)
     lines=out.splitlines();assert lines[0]==expected,out
     ledger=json.loads(lines[1]);assert len(lines)==2,out
     if probe:ledgers.append(ledger)
     else:assert not any(ledger.values()),ledger
   ledger=ledgers[-1]
   if kind=='alloc':assert ledger['alloc_requests']==n and ledger['alloc_bytes']==n*((size+15)//16*16+16),ledger
   else:assert ledger['copy_bytes']==n*(size+32) and ledger['copies']==2*n,ledger
   results.append({'kind':kind,'payload_bytes':size,'operations':n,'harts':harts,
    'best_ms':round(min(times[0])*1000,3),'median_ms':round(statistics.median(times[0])*1000,3),
    'operations_per_second':round(n/min(times[0])),
    'probe_best_ms':round(min(times[1])*1000,3),'ledger':ledger})
 print(json.dumps({'results':results},indent=2))

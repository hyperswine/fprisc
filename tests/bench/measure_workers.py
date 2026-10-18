#!/usr/bin/env python3
"""Uninstrumented million-iteration witnesses; alternating on/off samples."""
from pathlib import Path
import json,os,platform,re,statistics,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[2]
def run(args,env):
 p=subprocess.run(list(map(str,args)),cwd=ROOT,env=env,text=True,capture_output=True,timeout=240)
 assert p.returncode==0,(args,p.stdout,p.stderr)
 return p.stdout
with tempfile.TemporaryDirectory(prefix='fpr-worker-times-') as d:
 tmp=Path(d)
 base=dict(os.environ,FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_COST_PROBE='0',FPR_NO_SPEC='1',FPR_HARTS='1')
 base.pop('FPR_FOREIGN',None)
 sizes={};samples={};assembly={}
 for mode in ('off','on'):
  env=dict(base,FPR_NO_SCALAR_WORKERS='1' if mode=='off' else '0',FPR_NO_FIELD_WORKERS='1' if mode=='off' else '0',XDG_CACHE_HOME=str(tmp/mode))
  exe=tmp/('bench-'+mode)
  run([ROOT/'fpr','build',ROOT/'tests/bench/workers.fpr','--harts','1','--with',ROOT/'tests/bench/workers_clock.c','-o',exe],env)
  sizes[mode]=exe.stat().st_size
  asm=tmp/(mode+'.s')
  run([ROOT/'fpr','compile',ROOT/'tests/bench/workers.fpr',asm],env)
  units=[Path(p) for p in Path(str(asm)+'.units').read_text().split()]
  assembly[mode]={'root_bytes':asm.stat().st_size,'linked_bytes':asm.stat().st_size+sum(p.stat().st_size for p in units),
                  'workers':re.findall(r'# private workers: .*',asm.read_text())}
 for kind in ('scalar','pair','combined','record'):
  for sample in range(7):
   for mode in ('off','on'):
    value,ns=map(int,run([tmp/('bench-'+mode),kind],base).split())
    assert value==(500000500000 if kind=='scalar' else 500001500000)
    samples.setdefault(kind+':'+mode,[]).append(ns)
 print(json.dumps({'platform':platform.platform(),'iterations':1000000,'samples_ns':samples,'medians_ns':{k:statistics.median(v) for k,v in samples.items()},'binary_bytes':sizes,'assembly':assembly},indent=2))

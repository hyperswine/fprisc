#!/usr/bin/env python3
"""Paired cell-layout benchmark: same compiler, checked outputs, rotated timings."""
import argparse, hashlib, json, os, platform, random, re, statistics, subprocess, tempfile, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]

def cases(n):
    result = {
      'list-build-sum':('List = use "std/list".\nmain = print (List.sum (List.range 1 '+str(n)+')).\n',str(n*(n+1)//2)+'\n'),
      'list-map-sum':('List = use "std/list".\nmain = print (List.sum (List.map (fn x -> x + 1) (List.range 1 '+str(n)+'))).\n',str(n*(n+3)//2)+'\n'),
      'tree-build-sum':('Tree = Type (Leaf | Node Tree Int Tree).\nbuild : unsafe Int -> Int -> Tree.\nbuild d k = if d == 0 then Leaf else Node (build (d - 1) (2 * k)) k (build (d - 1) (2 * k + 1)).\ntotal : unsafe Tree -> Int.\ntotal t = case t of Leaf -> 0 | Node l k r -> total l + k + total r.\nmain = print (total (build '+str(18 if n>1000 else 9)+' 1)).\n',str((2**(18 if n>1000 else 9)-1)*2**(17 if n>1000 else 8))+'\n')}

    # Repeat inside the process to keep startup and metadata initialization
    # small relative to allocation/traversal. Outputs still use an independent
    # integer reference; counters must show every repetition materializes.
    for key,(source,want) in result.items():
        before,expr=source.split('main = print ',1)
        expression=expr.removesuffix('.\n')
        result[key]=(before+'go : unsafe Int -> Int -> Int.\ngo r acc = if r == 0 then acc else go (r - 1) (acc + '+expression+').\nmain = print (go 8 0).\n',str(int(want)*8)+'\n')
    return result

def run(argv,env):
    t=time.perf_counter_ns();p=subprocess.run(list(map(str,argv)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=300)
    assert not p.returncode,(argv,p.returncode,p.stdout[-2000:],p.stderr[-3000:])
    return p,time.perf_counter_ns()-t

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--output',type=Path,required=True);ap.add_argument('--samples',type=int,default=15);a=ap.parse_args()
    result={'scope':'Native host; same compiler; list fusion disabled symmetrically to retain materialized lists; normal regions; one hart; process startup included. Instrumented counters are separate from uninstrumented timings.', 'platform':platform.platform(),'machine':platform.machine(),'compiler_sha256':hashlib.sha256((ROOT/'fpr').read_bytes()).hexdigest(),'samples':a.samples,'repetitions_per_process':8,'rows':[]}
    with tempfile.TemporaryDirectory(prefix='fpr-compact-bench-') as td:
      tmp=Path(td);base={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
      base.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_HARTS='1',FPR_NO_LIST_FUSE='1',XDG_CACHE_HOME=str(tmp/'cache'))
      runners=[]
      for name,(source,want) in cases(1000000).items():
       for mode in ('legacy','compact'):
        env=dict(base,FPR_COMPACT_CELLS='1' if mode=='compact' else '0')
        src=tmp/(name+'.fpr');src.write_text(source);exe=tmp/(name+'-'+mode)
        _,compile_ns=run([ROOT/'fpr','build',src,'--harts','1','-o',exe],env)
        row={'case':name,'mode':mode,'source':source,'expected':want,'build_ns':compile_ns,'binary_bytes':exe.stat().st_size,'wall_ns':[]}
        p,_=run([exe],env);assert p.stdout==want,(name,mode,p.stdout,want)
        ps,pw=cases(1000)[name];probe_src=tmp/(name+'-probe.fpr');probe_src.write_text(ps);probe=tmp/(name+'-'+mode+'-probe')
        pe=dict(env,FPR_COST_PROBE='1');run([ROOT/'fpr','build',probe_src,'--harts','1','-o',probe],pe)
        p,_=run([probe],dict(pe,FPR_COST_REPORT='1'));assert p.stdout==pw
        row['ledger']=json.loads(re.search(r'\[fpr cost\] (\{.*\})',p.stderr)[1]);row['probe_source']=ps
        result['rows'].append(row);runners.append((exe,env,row))
      rng=random.Random(20261104)
      for sample in range(a.samples):
       order=list(runners);rng.shuffle(order)
       for exe,env,row in order:
        p,ns=run([exe],env);assert p.stdout==row['expected'];row['wall_ns'].append(ns)
      for row in result['rows']:
       row['median_ns']=statistics.median(row['wall_ns']);print(row['case'],row['mode'],round(row['median_ns']/1e6,3),row['ledger']['alloc_bytes'],flush=True)
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__':main()

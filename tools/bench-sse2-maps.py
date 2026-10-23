#!/usr/bin/env python3
"""Paired x64 emitted-map timings; Rosetta results are not native x64 timings."""
import argparse,hashlib,importlib.util,json,os,platform,random,re,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
from x64_probe import adapt,host,link,run
spec=importlib.util.spec_from_file_location('paired_driver',ROOT/'tools/bench-typed-ir-m3.py')
paired_driver=importlib.util.module_from_spec(spec);spec.loader.exec_module(paired_driver)

def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--output',type=Path,required=True)
 ap.add_argument('--against',type=Path,required=True)
 ap.add_argument('--compiler',type=Path,default=ROOT/'fpr')
 ap.add_argument('--runs',type=int,default=31)
 args=ap.parse_args()
 if args.runs<3:ap.error('at least three rounds required')
 available=host()
 if available is None:ap.error('native x64 or Rosetta required')
 mac,runner,label=available
 out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
 env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
 env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_NO_INLINE='1',FPR_NO_SCALAR_WORKERS='1',FPR_NO_FIELD_WORKERS='1',FPR_TYPED_IR_STRICT='all')
 identities={};builds={}
 for variant,compiler in [('baseline',args.against),('sse2',args.compiler)]:
  compiler=compiler.resolve();identities[variant]=hashlib.sha256(compiler.read_bytes()).hexdigest()
  mode=dict(env,XDG_CACHE_HOME=str(out/('cache-'+variant)))
  asm=out/(variant+'.s');run([compiler,'compile','--target=x64',ROOT/'tests/typed_ir/captured_simd.fpr',asm],mode)
  text=asm.read_text();bodies=re.findall(r'(?ms)^# fn ([^\n]+)\n(.*?)(?=^# native-insns-v1:)',text)
  for name in ('addCap','affineCap'):
   body=next(b for n,b in bodies if n.startswith('$vkernel:fpr_vspec_map_'+name+' '))
   assert ('movdqu (' in body)==(variant=='sse2')
  body='\n'.join(b for n,b in bodies if n.split()[0] not in ('main','plus','mixedCap','probeMixed') and not n.startswith('$vkernel:fpr_vspec_fold_') and not n.startswith('lifted_'))
  objects=set(re.findall(r'\bfpr_obj_[A-Za-z0-9_]+',body))
  asm.write_text('.text\n'+adapt(body,mac))
  source=out/(variant+'.c');source.write_text((ROOT/'tests/typed_ir/sse2_bench.c').read_text()+'\n'+'\n'.join(f'char {o}[40];' for o in sorted(objects)))
  exe=out/variant;link(['-ffp-contract=off','-I'+str(ROOT/'tests/typed_ir'),asm,source],exe,mac,env);builds[variant]=exe
 samples={kind:{v:[] for v in builds} for kind in ('int','float')}
 for kind in samples:
  for exe in builds.values():run([*runner,exe,kind],env)
 rng=random.Random(7415)
 for i in range(args.runs):
  for kind in samples:
   variants=list(builds);rng.shuffle(variants)
   for v in variants:samples[kind][v].append(int(run([*runner,builds[v],kind],env)))
  print('round '+str(i+1)+'/'+str(args.runs),flush=True)
 result={'host':platform.platform(),'execution':label,'compiler_sha256':identities,'runs':args.runs,'scope':'128-element maps repeated 100000 times, no yields, descriptor setup and checks excluded; linkage adapted by the independent oracle. Rosetta does not establish native x64 performance.','samples_ns':samples,'paired':{k:paired_driver.paired(v['baseline'],v['sse2'],rng) for k,v in samples.items()}}
 (out/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result['paired'],indent=2))
if __name__=='__main__':main()

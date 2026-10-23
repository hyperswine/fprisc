#!/usr/bin/env python3
"""Paired deterministic QEMU guest instruction counts for builtin/GC codegen.
This is emitted guest work, not physical RISC-V elapsed time.
"""
import argparse,hashlib,json,os,random,re,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
from x64_probe import run
from check_builtin_heap_index import START

def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--against',type=Path,required=True)
 ap.add_argument('--compiler',type=Path,default=ROOT/'fpr')
 ap.add_argument('--output',type=Path,required=True)
 ap.add_argument('--runs',type=int,default=31)
 args=ap.parse_args()
 if args.runs<3:ap.error('at least 3 pairs')
 out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
 (out/'start.S').write_text(START.replace('call heap_test_exit','1: j 1b'))
 env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')};env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_NO_INLINE='1')
 hashes={};images={}
 for variant,compiler in [('baseline',args.against),('typed',args.compiler)]:
  compiler=compiler.resolve();hashes[variant]=hashlib.sha256(compiler.read_bytes()).hexdigest()
  mode=dict(env,FPR_TYPED_IR_BACKEND='legacy' if variant=='baseline' else 'mixed',XDG_CACHE_HOME=str(out/('cache-'+variant)))
  if variant=='typed':mode['FPR_TYPED_IR_STRICT']='all'
  for width in (32,64):
   asm=out/f'{variant}{width}.s';exe=out/f'{variant}{width}.elf'
   run([compiler,'compile','--system=bare-metal','--profile=builtin','--target=rv'+str(width),ROOT/'tests/typed_ir/builtin_gc.fpr',asm],mode)
   text=asm.read_text();headers=re.findall(r'^# fn ([^\n]+)',text,re.M)
   assert headers and all(('typed-ir' in h)==(variant=='typed') for h in headers)
   flags=['-DFPR_BUILTIN','-DFPR_NHARTS=1','-DFPR_BUILTIN_GC','-DFPR_BUILTIN_GC_STRESS=1','-DFPR_BUILTIN_HEAP_MAX_BYTES=65536','-DBENCH_GUEST','-Iruntime','-Imachine/builtin','-O2','-ffreestanding','-fno-builtin','-nostdlib','-nostartfiles','-ffunction-sections','-fdata-sections','-Wl,--gc-sections','-mcmodel=medany','-msmall-data-limit=0']
   run(['riscv64-unknown-elf-gcc','-march=rv'+str(width)+'im_zicsr','-mabi='+('ilp32' if width==32 else 'lp64'),*flags,'-T',ROOT/'machine/tangnano20k/link.ld',out/'start.S',asm,ROOT/'tests/typed_ir/builtin_gc_oracle.c',ROOT/'machine/builtin/heap.c',ROOT/'machine/tangnano20k/gc_registers.S',ROOT/'machine/tangnano20k/gc_roots.c','-o',exe],mode)
   images[(width,variant)]=exe
 samples={str(w):{v:[] for v in hashes} for w in (32,64)};rng=random.Random(7515)
 for i in range(args.runs):
  keys=list(images);rng.shuffle(keys)
  for width,variant in keys:
   text=run(['qemu-system-riscv'+str(width),'-machine','virt','-m','8M','-nographic','-bios','none','-icount','shift=0,align=off,sleep=off','-kernel',images[(width,variant)]],env,timeout=90)
   assert 'TYPED_BUILTIN_GC_PASS' in text,text
   samples[str(width)][variant].append(int(re.search(r'GUEST_INSNS=([0-9a-f]+)',text)[1],16))
  print('paired round '+str(i+1)+'/'+str(args.runs),flush=True)
 result={'compiler_sha256':hashes,'runs':args.runs,'scope':__doc__,'samples_guest_insns':samples,'ratios':{w:sum(v['typed'])/sum(v['baseline']) for w,v in samples.items()}}
 (out/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()

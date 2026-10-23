#!/usr/bin/env python3
"""Builtin fixed stacks/no fuel and generated roots through actual RISC-V GC."""
import argparse,os,re,tempfile,subprocess,sys,shutil
from pathlib import Path
from x64_probe import ROOT,run
from check_builtin_heap_index import START

def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--require-execution',action='store_true')
 ap.add_argument('--port',help='also run the GC fixture on an already configured RV32 Tang Nano')
 ap.add_argument('--freq-mhz',type=float,default=48)
 ap.add_argument('--board-runs',type=int,default=3)
 args=ap.parse_args()
 if args.board_runs<1:ap.error('board-runs must be positive')
 missing=[t for t in ('riscv64-unknown-elf-gcc','qemu-system-riscv32','qemu-system-riscv64') if not shutil.which(t)]
 if missing:
  if args.require_execution or args.port:ap.error('missing execution tools: '+', '.join(missing))
  print('Builtin execution SKIP: '+', '.join(missing));return
 env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
 env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_NO_INLINE='1',FPR_TYPED_IR_BACKEND='mixed',FPR_TYPED_IR_STRICT='all')
 with tempfile.TemporaryDirectory(prefix='fpr-typed-builtin-') as d:
  tmp=Path(d);env['XDG_CACHE_HOME']=str(tmp/'cache')
  (tmp/'start.S').write_text(START.replace('call heap_test_exit','1: j 1b'))
  builds={}
  for width in (32,64):
   asm=tmp/f'gc{width}.s'
   run([ROOT/'fprc','--system=bare-metal','--profile=builtin','--target=rv'+str(width),ROOT/'tests/typed_ir/builtin_gc.fpr',asm],env)
   text=asm.read_text();assert '# typed IR: no translation' in text
   headers=re.findall(r'^# fn ([^\n]+)',text,re.M)
   assert headers and all('typed-ir rv'+str(width) in h for h in headers)
   assert 'fpr_fuel_exhausted' not in text and 'fpr_stack_grow' not in text and '# wcet:' not in text
   hold=next(h for h in headers if h.startswith('hold '));assert not re.search(r'spills=0\b',hold),hold
   assert 'segmax=UNBOUNDED' in text,'no-fuel loops must retain honest native reports'
   obj=tmp/f'gc{width}.o';run(['riscv64-unknown-elf-gcc','-march=rv'+str(width)+'im','-mabi='+('ilp32' if width==32 else 'lp64'),'-c',asm,'-o',obj],env)
   exe=tmp/f'gc{width}.elf'
   flags=['-DFPR_BUILTIN','-DFPR_NHARTS=1','-DFPR_BUILTIN_GC','-DFPR_BUILTIN_GC_STRESS=1','-DFPR_BUILTIN_HEAP_MAX_BYTES=65536','-Iruntime','-Imachine/builtin','-O2','-ffreestanding','-fno-builtin','-nostdlib','-nostartfiles','-ffunction-sections','-fdata-sections','-Wl,--gc-sections','-mcmodel=medany','-msmall-data-limit=0']
   cmd=['riscv64-unknown-elf-gcc','-march=rv'+str(width)+'im','-mabi='+('ilp32' if width==32 else 'lp64'),*flags,'-T',ROOT/'machine/tangnano20k/link.ld',tmp/'start.S',obj,ROOT/'tests/typed_ir/builtin_gc_oracle.c',ROOT/'machine/builtin/heap.c',ROOT/'machine/tangnano20k/gc_registers.S',ROOT/'machine/tangnano20k/gc_roots.c','-o',exe]
   builds[width]=list(cmd)
   run(cmd,env)
   out=run(['qemu-system-riscv'+str(width),'-machine','virt','-m','8M','-nographic','-bios','none','-kernel',exe],env,timeout=90)
   assert 'TYPED_BUILTIN_GC_PASS' in out,out
   print('RV'+str(width)+': '+out.strip(),flush=True)
   broken=tmp/'missing-roots.c'
   roots=(ROOT/'machine/tangnano20k/gc_roots.c').read_text()
   marker='  fpr_builtin_gc_roots(stack, (const uw *)_stack_top, 1);'
   assert marker in roots
   broken.write_text(roots.replace(marker,'  /* negative control: no generated register/stack roots */'))
   badcmd=list(cmd);badcmd[badcmd.index(ROOT/'machine/tangnano20k/gc_roots.c')]=broken
   run(badcmd,env)
   bad=subprocess.run(['qemu-system-riscv'+str(width),'-machine','virt','-m','8M','-nographic','-bios','none','-kernel',str(exe)],cwd=ROOT,env=env,capture_output=True,text=True,timeout=90)
   assert bad.returncode!=0 and any(marker in bad.stdout for marker in ('GENERATED GC CHECK FAILED','GENERATED GC FAILURE')),(bad.returncode,bad.stdout,bad.stderr)
   print('RV'+str(width)+': missing generated register/stack roots fail the oracle PASS',flush=True)

  if args.port:
   cmd=builds[32];exe=tmp/'gc32.elf';binary=tmp/'gc32.bin'
   cmd.insert(1,'-DPHYSICAL_BOARD');run(cmd,env)
   run(['riscv64-unknown-elf-objcopy','-O','binary',exe,binary],env)
   for iteration in range(args.board_runs):
    out=run([sys.executable,ROOT/'tools/run_tangnano20k_base.py',binary,'--port',args.port,'--freq-mhz',str(args.freq_mhz),'--timeout','120'],env,timeout=240)
    assert 'TYPED_BUILTIN_GC_PASS' in out and 'FPR EXIT 0' in out and 'DONE' in out,out
    print('Physical RV32 generated GC roots '+str(iteration+1)+'/'+str(args.board_runs)+': '+out.strip(),flush=True)

if __name__=='__main__':main()

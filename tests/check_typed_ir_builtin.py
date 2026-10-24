#!/usr/bin/env python3
"""Builtin fixed stacks and no fuel in typed-IR emission (RV32 and RV64).

Until 2026-10-24 this also ran the fixture under the conservative collector to
prove generated code kept its roots visible; the collector is gone (the Base
heap reclaims by compiler-placed regions, docs/2026-10-25-REGIONS-LOOPS-CALLS.md)
and the Builtin profile frees by ownership, so what remains is the emission
contract: every function typed, no fuel tick or stack growth, honest loop reports."""
import argparse,os,re,tempfile,shutil
from pathlib import Path
from x64_probe import ROOT,run

def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--require-execution',action='store_true',help='kept for CI compatibility: the check assembles but runs nothing')
 args=ap.parse_args()
 if not shutil.which('riscv64-unknown-elf-gcc'):
  if args.require_execution:ap.error('missing riscv64-unknown-elf-gcc')
  print('Builtin emission SKIP: riscv64-unknown-elf-gcc');return
 env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
 env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_NO_INLINE='1',FPR_TYPED_IR_BACKEND='mixed',FPR_TYPED_IR_STRICT='all')
 with tempfile.TemporaryDirectory(prefix='fpr-typed-builtin-') as d:
  tmp=Path(d);env['XDG_CACHE_HOME']=str(tmp/'cache')
  for width in (32,64):
   asm=tmp/f'builtin{width}.s'
   run([ROOT/'fprc','--system=bare-metal','--profile=builtin','--target=rv'+str(width),ROOT/'tests/typed_ir/builtin_gc.fpr',asm],env)
   text=asm.read_text();assert '# typed IR: no translation' in text
   headers=re.findall(r'^# fn ([^\n]+)',text,re.M)
   assert headers and all('typed-ir rv'+str(width) in h for h in headers)
   assert 'fpr_fuel_exhausted' not in text and 'fpr_stack_grow' not in text and '# wcet:' not in text
   hold=next(h for h in headers if h.startswith('hold '));assert not re.search(r'spills=0\b',hold),hold
   assert 'segmax=UNBOUNDED' in text,'no-fuel loops must retain honest native reports'
   obj=tmp/f'builtin{width}.o';run(['riscv64-unknown-elf-gcc','-march=rv'+str(width)+'im','-mabi='+('ilp32' if width==32 else 'lp64'),'-c',asm,'-o',obj],env)
   print('RV'+str(width)+': typed builtin emission, fixed stacks, no fuel, assembled PASS',flush=True)

if __name__=='__main__':main()

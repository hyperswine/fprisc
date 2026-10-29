#!/usr/bin/env python3
"""Fixed RV32 Base stack: fitting frames execute, exhaustion refuses before entry.

The optional board run only uploads RAM images to an already configured 48 MHz
Tang Nano; it does not configure or flash the FPGA.
"""
import argparse,hashlib,os,re,shutil,subprocess,sys,tempfile
from pathlib import Path
from check_rv32_float_constants import ROOT,build,run
from check_typed_ir_rv_frames import actor_source

ORACLE=r'''
#include "fpr.h"
extern uw __real_fpr_stack_reserve(uw,uw);
extern V __real_fpr_fn_main(void);
static void say(const char*s){while(*s)hal_putc(*s++);}
uw __wrap_fpr_stack_reserve(uw sp,uw bytes){
 fpr_hart_t*h=fpr_hart();
 if(!h || sp<h->stk_lo || sp-h->stk_lo>=h->stk_span || bytes>sp ||
    sp-bytes-h->stk_lo<h->stk_span)
   fpr_cpanic("fixed-stack oracle: invalid pre-frame miss");
 say("PRE_FRAME_REFUSAL\n");
 return __real_fpr_stack_reserve(sp,bytes);
}
V __wrap_fpr_fn_main(void){return __real_fpr_fn_main();}
static V tick(V u){(void)u;fpr_hart()->fuel=1;return (V)&fpr_unit;}
FPR_FN(fpr_g_Reserve_x2etick,tick,1);
'''

def check(result,negative,physical):
 text=(result.stdout+result.stderr).replace('\r\n','\n')
 if negative:
  assert result.returncode!=0 and 'PRE_FRAME_REFUSAL\n' in text and 'Base: 64 KiB stack exhausted' in text,text
  assert 'RV ACTOR FRAMES HOLD' not in text,text
 else:
  assert result.returncode==0 and 'RV ACTOR FRAMES HOLD' in text and 'PRE_FRAME_REFUSAL' not in text,text
 assert ('FPR EXIT 1' if negative else 'FPR EXIT 0') in text,text
 if physical:assert 'DONE' in text,text
 return text

def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--require-execution',action='store_true');ap.add_argument('--port')
 ap.add_argument('--keep-dir',type=Path);args=ap.parse_args()
 env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
 env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_TYPED_IR_BACKEND='mixed',FPR_TYPED_IR_STRICT='all',
            FPR_NO_INLINE='1',FPR_NO_F64_INLINE='1',FPR_NO_SCALAR_WORKERS='1',FPR_NO_FIELD_WORKERS='1',FPR_NO_REUSE='1')
 if 'FPR_SOFTFLOAT_ROOT' in os.environ:env['FPR_SOFTFLOAT_ROOT']=os.environ['FPR_SOFTFLOAT_ROOT']
 missing=[x for x in ('riscv64-unknown-elf-gcc','qemu-system-riscv32') if not shutil.which(x)]
 soft=Path(env.get('FPR_SOFTFLOAT_ROOT',ROOT/'build/tangnano20k-softfloat'))/'build/Linux-RISCV32-GCC/softfloat.a'
 if not soft.is_file():missing.append('RV32 SoftFloat archive (FPR_SOFTFLOAT_ROOT)')
 if missing:
  assert not (args.require_execution or args.port),missing
  print('Fixed stack reservation SKIP: '+', '.join(missing));return
 run(['make','fpr'],env)
 with tempfile.TemporaryDirectory(prefix='fpr-fixed-reserve-') as d:
  out=args.keep_dir or Path(d);out.mkdir(parents=True,exist_ok=True);env['XDG_CACHE_HOME'] = os.environ.get('XDG_CACHE_HOME', str(out/'cache'))
  oracle=out/'oracle.c';oracle.write_text(ORACLE)
  images=[]
  for negative,depth in ((False,5),(True,80)):
   source=actor_source(out/('refuse.fpr' if negative else 'fit.fpr'),depth)
   for physical in ((False,True) if args.port else (False,)):
    target=out/(('board-' if physical else 'qemu-')+str(depth))
    elf=build(source,target,env,extra=oracle,physical=physical,ldflags=['-Wl,--wrap=fpr_stack_reserve'])
    asm=(target/'base.s').read_text()
    assert re.search(r'^# fn large .*reserve=yes',asm,re.M)
    if physical:
     binary=elf.with_suffix('.bin');run(['riscv64-unknown-elf-objcopy','-O','binary',elf,binary],env)
     images.append((negative,binary))
    else:
     result=subprocess.run(['qemu-system-riscv32','-machine','virt','-m','8M','-nographic','-bios','none','-kernel',elf],
                           env=env,capture_output=True,text=True,timeout=120)
     print(check(result,negative,False),end='',flush=True)
     print(f'QEMU fixed stack depth={depth}, 512 live values: PASS',flush=True)
  if args.port:
   # Read-only UART diagnostic before any image upload; checks configured clock.
   print(run([sys.executable,ROOT/'tools/run_tangnano20k_base.py','--port',args.port,'--freq-mhz','48','--probe'],env),end='',flush=True)
   for negative,binary in images:
    print('Physical image sha256='+hashlib.sha256(binary.read_bytes()).hexdigest(),flush=True)
    result=subprocess.run([sys.executable,ROOT/'tools/run_tangnano20k_base.py',binary,'--port',args.port,'--freq-mhz','48','--timeout','120'],
                          cwd=ROOT,env=env,capture_output=True,text=True,timeout=150)
    print(check(result,negative,True),end='',flush=True)
    print('Physical fixed-stack '+('pre-frame refusal' if negative else 'fitting frame')+': PASS',flush=True)

if __name__=='__main__':main()

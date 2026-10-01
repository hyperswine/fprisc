#!/usr/bin/env python3
"""Differential register promotion across observable effects and call boundaries."""
import os,re,subprocess,tempfile,platform,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
ENV={**os.environ,'FPR_HOME':str(ROOT),'FPR_PATH':str(ROOT)};ENV.pop('FPR_FOREIGN',None)
def run(args,env):
 p=subprocess.run([str(x) for x in args],cwd=ROOT,env=env,capture_output=True,text=True,timeout=180)
 assert p.returncode==0,f'{args}: {p.returncode}\n{p.stdout}{p.stderr}'
 return p.stdout
with tempfile.TemporaryDirectory(prefix='fpr-regs-') as d:
 tmp=Path(d)
 for fixture in ('inlining','slotprims','cafalias','floatinline'):
  for no_inline in ('0','1'):
   outputs=[]
   for no_regs in ('0','1','0'):
    env={**ENV,'FPR_NO_INLINE':no_inline,'FPR_NO_REGISTERS':no_regs}
    exe=tmp/'probe';args=['./fpr','build',f'tests/base/{fixture}.fpr','-o',exe]
    if fixture=='floatinline':args+=['--with','tests/base/floatprobe.c']
    run(args,env);outputs.append(run([exe],env))
   assert outputs[0]==outputs[1]==outputs[2],(fixture,outputs)
 # Confirm the optimization actually ran; otherwise equivalence is vacuous.
 for target in ('rv64','a64','x64'):
  for no_regs in ('0','1'):
   asm=tmp/f'{target}{no_regs}.s'
   run(['./fpr',f'--target={target}',f'--prelude={ROOT}/core/prelude.fpr',
        'tests/bench/nbody.fpr',asm],{**ENV,'FPR_NO_REGISTERS':no_regs})
   text=asm.read_text()
   marker={'rv64':r'\bs[1-5]\b','a64':r'\bx(?:19|20|21|22|23)\b','x64':r'%(?:rbx|r12|r13|r14|r15)\b'}[target]
   assert bool(re.search(marker,text))==(no_regs=='0'),(target,no_regs)
 # Execute a register-heavy generated x64 body against an independent C sum.
 source=tmp/'hot.fpr'
 source.write_text('hot a b c d e = a*b + c*d + e*a + b*c + d*e + a*c + b*d + c*e + d*a + e*b + a*b + c*d + e*a + b*c + d*e + a*c + b*d + c*e + d*a + e*b.\nmain = Unit.\n')
 asm=tmp/'hot.s'
 run(['./fpr','--target=x64',f'--prelude={ROOT}/core/prelude.fpr',source,asm],{**ENV,'FPR_NO_REGISTERS':'0'})
 text=asm.read_text()
 match=re.search(r'(?ms)^\s*\.globl fpr_fn_hot\n.*?(?=^# wcet:|^# fn |\Z)',text)
 assert match and re.search(r'%(?:rbx|r12|r13|r14|r15)\b',match.group())
 mac=platform.system()=='Darwin';native=platform.machine() in ('x86_64','AMD64')
 rosetta=mac and not native and subprocess.run(['arch','-x86_64','/usr/bin/true'],capture_output=True).returncode==0
 if native or rosetta:
  selected='.text\n'+match.group().replace('%fs:fpr_posix_hart@tpoff','probe_hart(%rip)')
  if mac:
   selected=re.sub(r'\bfpr_[A-Za-z0-9_]+\b',lambda m:'_'+m.group(),selected)
   selected=selected.replace('probe_hart(%rip)','_probe_hart(%rip)')
  leaf=tmp/'leaf.s';leaf.write_text(selected)
  harness=tmp/'harness.c';harness.write_text("""
#include <stdint.h>
#include <assert.h>
#include <stdio.h>
static intptr_t hart[60]={1000000};
void *probe_hart=hart;
void fpr_fuel_exhausted(void) { hart[0]=1000000; }
extern intptr_t fpr_fn_hot(intptr_t,intptr_t,intptr_t,intptr_t,intptr_t);
int main(void) {
 for(intptr_t a=-7;a<=7;a++) for(intptr_t b=-9;b<=9;b++) {
  intptr_t c=13,d=-3,e=6;
  intptr_t expected=a*b+c*d+e*a+b*c+d*e+a*c+b*d+c*e+d*a+e*b;
  assert(fpr_fn_hot(a*2+1,b*2+1,c*2+1,d*2+1,e*2+1)==expected*4+1);
 }
 puts("x64 register-heavy body: 285 independent C-reference cases: PASS");
}
""")
  exe=tmp/'x64-hot'
  run([shutil.which('clang') or 'cc',*(['-arch','x86_64'] if mac else []),'-O2',leaf,harness,'-o',exe],ENV)
  print(run([*(['arch','-x86_64'] if rosetta else []),exe],ENV).strip())
 else:print('x64 register-heavy execution: SKIP (needs x64 or Rosetta)')
 print('Registers: differential fixtures, warm-cache mode separation and three-backend emission: PASS')

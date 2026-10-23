#!/usr/bin/env python3
"""x64 sized-frame ABI execution on Intel/Rosetta, with modeled TLS cells."""
import argparse,platform,re,shutil,tempfile
from pathlib import Path
from x64_probe import ROOT,adapt,borrowed_oracle,environment,host,link,run

def shim():
 def clobber(name,callee,keep):
  return f'.globl {name}\n{name}:\n pushq %rbp\n movq %rsp,%rbp\n call {callee}\n popq %rbp\n'+''.join(f' xorq %{r},%{r}\n' for r in ('rax','rdi','rsi','rdx','rcx','r8','r9','r10','r11') if r!=keep)+' ret\n'
 s='.text\n'+clobber('fpr_stack_reserve','oracle_reserve','rax')+clobber('fpr_fuel_exhausted','oracle_tick',None)
 s+='.globl oracle_invoke\noracle_invoke:\n pushq %rbp\n movq %rsp,%rbp\n'
 saved=('rbx','r12','r13','r14','r15')
 for i,r in enumerate(saved):s+=f' pushq %{r}\n movq ${1000+i},%{r}\n'
 s+=' subq $8,%rsp\n leaq -8(%rsp),%r10\n movq %r10,oracle_entry_sp(%rip)\n call *oracle_target(%rip)\n'
 for i,r in enumerate(saved):s+=f' cmpq ${1000+i},%{r}\n jne 99f\n'
 s+=' leaq 48(%rsp),%r10\n cmpq %r10,%rbp\n jne 99f\n addq $8,%rsp\n'
 for r in reversed(saved):s+=f' popq %{r}\n'
 return s+' popq %rbp\n ret\n99:\n movq $200,%rdi\n call oracle_finish\n'

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--keep-dir',type=Path);a=ap.parse_args()
 target=host()
 if target is None:print('x64 frames SKIP: Intel/Rosetta unavailable');return
 mac,runner,label=target
 with tempfile.TemporaryDirectory(prefix='fpr-x64-frames-') as d:
  out=a.keep_dir or Path(d);out.mkdir(parents=True,exist_ok=True);env=environment(out/'cache')
  run(['make','fpr'],env)
  emitter=out/'emit';obj=out/'ghc';obj.mkdir(exist_ok=True)
  run(['cabal','exec','--','ghc','-O1','-w','-icompiler','-outputdir',obj,'tests/EmitX64Frames.hs','-o',emitter],env)
  c=(ROOT/'tests/typed_ir/rv_frames_oracle.c').read_text()
  c=c.replace('static V hart[64];','static V hart[64]; void *probe_hart=hart; V probe_a6,probe_a7;')
  c=c.replace('V,V,V,V,V,V,V,V','V,V,V,V,V,V')
  c=c.replace('__asm__ volatile("mv tp,%0"::"r"(hart):"memory");','')
  for v in ('sp','after'):
   c=c.replace(f'__asm__ volatile("mv %0,sp":"=r"({v}));',f'__asm__ volatile("mov %%rsp,%0":"=r"({v}));')
  c=c.replace('(U)__builtin_frame_address(0)==oracle_entry_sp','(U)__builtin_frame_address(0)+8==oracle_entry_sp')
  c=c.replace('phase>=3?512:9000','phase>=3?5000:9000')
  c=c.replace(',expected[6],expected[7]','')
  c=c.replace('for(int i=8;i<64;i++)hart[i-7]=expected[i];','probe_a6=expected[6];probe_a7=expected[7];for(int i=8;i<64;i++)hart[i-7]=expected[i];')
  c=c.replace('reserves++;','reserves++;probe_a6=probe_a7=tag(-999);')
  c=c.replace('ticks++;','ticks++;probe_a6=probe_a7=tag(-777);')
  start=c.index('static void say(');end=c.index('#define CHECK',start)
  c=c[:start]+'''#include <stdio.h>
#include <stdlib.h>
static void say(const char*s){fputs(s,stdout);}
__attribute__((noreturn)) void oracle_finish(int code){if(code)fprintf(stderr,"x64 frame oracle failed line %d\\n",code);exit(code?1:0);}
'''+c[end:]
  c=c.replace('RV_SIZED_FRAMES_PASS','X64_SIZED_FRAMES_PASS')
  def adapt_all(text,borrowed=False):
   text=adapt(text,mac,borrowed=borrowed)
   return re.sub(r'\boracle_[A-Za-z0-9_]+',lambda m:'_'+m[0],text) if mac else text
  wrapper=out/'shim.s';wrapper.write_text(adapt_all(shim()))
  for hart in ('tls','borrow'):
   source=out/(hart+'.c');code=borrowed_oracle(c) if hart=='borrow' else c
   if hart=='borrow':
    code=code.replace('reserves++;','reserves++;fpr_g_tlsoff=(uintptr_t)&probe_borrows[reserves%2];')
    code=code.replace('ticks++;','ticks++;fpr_g_tlsoff=(uintptr_t)&probe_borrows[(ticks+1)%2];')
   source.write_text(code)
   for loops in ('0','1'):
    asm=out/f'frames-{hart}-{loops}.s'
    print(run([emitter,hart,loops,asm],env),end='',flush=True)
    assert asm.read_text().count('reserve=yes')==3
    if shutil.which('clang'):
     run(['clang','-target','x86_64-unknown-linux-gnu','-c',asm,'-o',asm.with_suffix('.o')],env)
    adapted=out/'adapted.s';adapted.write_text(adapt_all(asm.read_text(),borrowed=hart=='borrow'))
    exe=out/f'oracle-{hart}-{loops}'
    link(['-fno-omit-frame-pointer',*(['-DSELF_LOOPS'] if loops=='1' else []),source,wrapper,adapted],exe,mac,env)
    result=run([*runner,exe],env);assert 'X64_SIZED_FRAMES_PASS' in result,result
    print(f'{label} {hart} loops={loops}: '+result.strip(),flush=True)
  if not mac and platform.machine() in ('x86_64','AMD64'):
   source=out/'actor.fpr';source.write_text('unsafe base.\nReserve.deep : Unit -> Int.\n'
    'main = if Reserve.deep Unit == 9 then print "X64 ACTOR FRAMES HOLD" else error "nested frame count".\n')
   asm=out/'actor-frames.s';run([emitter,'tls','1',asm],env)
   for harts in (1,4):
    exe=out/f'actor-{harts}'
    run([ROOT/'fpr','build',source,'--harts',harts,'--with',ROOT/'tests/typed_ir/actor_frames.c','--with',asm,'-o',exe],env)
    result=run([exe],env);assert 'X64 ACTOR FRAMES HOLD' in result,result
    print(f'Linux x64 production actor runtime: 9000-field frames, nine nested calls, forced yields, {harts} hart(s) PASS',flush=True)
  else:print('Linux x64 production actor runtime SKIP: nonmatching host',flush=True)

if __name__=='__main__':main()

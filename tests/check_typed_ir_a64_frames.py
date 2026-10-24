#!/usr/bin/env python3
"""Native A64 large-frame ABI oracle, independent of the actor runtime."""
import argparse,os,platform,shutil,tempfile
from pathlib import Path
from frame_emitter import build_emitter
from check_typed_ir_rv import ROOT,run

def shim(mac,hart):
 def sym(s):return ('_' if mac else '')+s
 def addr(reg,s):
  s=sym(s)
  return f'adrp {reg},{s}'+('@PAGE' if mac else '')+'\n'+f'add {reg},{reg},'+(s+'@PAGEOFF' if mac else ':lo12:'+s)+'\n'
 def clobber(name,callee,keep):
  return f'.globl {sym(name)}\n{sym(name)}:\n stp x29,x30,[sp,#-16]!\n mov x29,sp\n bl {sym(callee)}\n ldp x29,x30,[sp],#16\n'+''.join(f' mov x{i},#0\n' for i in range(18) if i!=keep)+' ret\n'
 s='.text\n'+clobber('fpr_stack_reserve','oracle_reserve',0)+clobber('fpr_fuel_exhausted','oracle_tick',None)
 s+=f'.globl {sym("oracle_invoke")}\n{sym("oracle_invoke")}:\n sub sp,sp,#256\n stp x29,x30,[sp]\n'
 for i in range(10):s+=f' str x{19+i},[sp,#{16+i*8}]\n mov x{19+i},#{1000+i}\n'
 for i in range(8):s+=f' str d{8+i},[sp,#{96+i*8}]\n mov x9,#{2000+i}\n fmov d{8+i},x9\n'
 if hart=='x28':s+=addr('x10','fpr_posix_hart')+'ldr x28,[x10]\n'
 s+='mov x9,sp\n'+addr('x10','oracle_entry_sp')+'str x9,[x10]\n'+addr('x10','oracle_target')+'ldr x10,[x10]\n blr x10\n'
 for i in range(10):
  s+=(addr('x10','fpr_posix_hart')+'ldr x10,[x10]\n' if i==9 and hart=='x28' else f' mov x10,#{1000+i}\n')
  s+=f' cmp x{19+i},x10\n b.ne 99f\n'
 for i in range(8):s+=f' fmov x9,d{8+i}\n mov x10,#{2000+i}\n cmp x9,x10\n b.ne 99f\n'
 for i in range(10):s+=f' ldr x{19+i},[sp,#{16+i*8}]\n'
 for i in range(8):s+=f' ldr d{8+i},[sp,#{96+i*8}]\n'
 return s+f' ldp x29,x30,[sp]\n add sp,sp,#256\n ret\n99:\n mov x0,#200\n b {sym("oracle_finish")}\n'

def production_runtime(out,env,emitter):
 source=out/'actor.fpr'
 source.write_text('unsafe base.\nReserve.deep : Unit -> Int.\n'
  'main = if Reserve.deep Unit == 9 then print "A64 ACTOR FRAMES HOLD" else error "nested frame count".\n')
 asm=out/'actor-frames.s'
 run([emitter,'a64','mac' if platform.system()=='Darwin' else 'elf','x28','1',asm],env)
 support=ROOT/'tests/typed_ir/actor_frames.c'
 mode=dict(env,FPR_TYPED_IR_BACKEND='mixed',FPR_TYPED_IR_STRICT='all',FPR_NO_INLINE='1',
           FPR_NO_SCALAR_WORKERS='1',FPR_NO_FIELD_WORKERS='1',FPR_NO_REUSE='1',XDG_CACHE_HOME=str(out/'cache'))
 for keg in ('/opt/homebrew/opt/libarchive/lib/pkgconfig','/usr/local/opt/libarchive/lib/pkgconfig'):
  if Path(keg).is_dir():mode['PKG_CONFIG_PATH']=keg+':'+mode.get('PKG_CONFIG_PATH','');break
 for harts in (1,4):
  exe=out/f'actor-{harts}'
  run([ROOT/'fpr','build',source,'--harts',harts,'--with',support,'--with',asm,'-o',exe],mode)
  result=run([exe],mode);assert 'A64 ACTOR FRAMES HOLD' in result,result
  print(f'A64 production actor runtime: 9000-field frames, nine nested calls, forced yields, {harts} hart(s) PASS',flush=True)

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--keep-dir',type=Path);ap.add_argument('--require-execution',action='store_true');args=ap.parse_args()
 native=platform.machine() in ('arm64','aarch64')
 assert native or not args.require_execution,'native A64 execution required'
 mac=platform.system()=='Darwin'
 env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')};env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT))
 run(['make','fpr'],env)
 with tempfile.TemporaryDirectory(prefix='fpr-a64-frames-') as d:
  out=args.keep_dir or Path(d);out.mkdir(parents=True,exist_ok=True)
  emitter=build_emitter(env)
  if shutil.which('clang'):
   for fmt,hart,target in [('elf','tls','aarch64-unknown-linux-gnu'),('mac','tlv','arm64-apple-macos11')]:
    asm=out/('cross-'+fmt+'.s')
    run([emitter,'a64',fmt,hart,'1',asm],env)
    run(['clang','-target',target,'-c',asm,'-o',asm.with_suffix('.o')],env)
    print(f'A64 {fmt} {hart} large-frame assembly PASS',flush=True)
  if not native:
   print('Native A64 large frames SKIP: nonmatching host; portable emission checked');return
  c=(ROOT/'tests/typed_ir/rv_frames_oracle.c').read_text()
  c=c.replace('static V hart[64];','static V hart[64]; V *fpr_posix_hart=hart;')
  c=c.replace('__asm__ volatile("mv tp,%0"::"r"(hart):"memory");','')
  c=c.replace('__asm__ volatile("mv %0,sp":"=r"(sp));','__asm__ volatile("mov %0,sp":"=r"(sp));')
  c=c.replace('__asm__ volatile("mv %0,sp":"=r"(after));','__asm__ volatile("mov %0,sp":"=r"(after));')
  c=c.replace('(U)__builtin_frame_address(0)==oracle_entry_sp','(U)__builtin_frame_address(0)+16==oracle_entry_sp')
  c=c.replace('phase>=3?512:9000','phase>=3?5000:9000')
  start=c.index('static void say(');end=c.index('#define CHECK',start)
  c=c[:start]+'''#include <stdio.h>
#include <stdlib.h>
static void say(const char*s){fputs(s,stdout);}
__attribute__((noreturn)) void oracle_finish(int code){if(code)fprintf(stderr,"A64 frame oracle failed line %d\\n",code);exit(code?1:0);}
'''+c[end:]
  c=c.replace('RV_SIZED_FRAMES_PASS','A64_SIZED_FRAMES_PASS')
  for hart in ('global','x28','tlv' if mac else 'tls'):
   source=out/(hart+'.c');source.write_text(c.replace('V *fpr_posix_hart=hart;','__thread V *fpr_posix_hart=hart;') if hart in ('tlv','tls') else c)
   wrapper=out/(hart+'.s');wrapper.write_text(shim(mac,hart))
   for loops in ('0','1'):
    asm=out/f'frames-{hart}-{loops}.s'
    print(run([emitter,'a64','mac' if mac else 'elf',hart,loops,asm],env),end='',flush=True)
    assert asm.read_text().count('reserve=yes')==3
    exe=out/f'oracle-{hart}-{loops}'
    run(['cc','-O2','-fno-omit-frame-pointer',*(['-DSELF_LOOPS'] if loops=='1' else []),source,wrapper,asm,'-o',exe],env)
    result=run([exe],env);assert 'A64_SIZED_FRAMES_PASS' in result,result
    print(f'A64 {hart} loops={loops}: '+result.strip(),flush=True)
  production_runtime(out,env,emitter)

if __name__=='__main__':main()

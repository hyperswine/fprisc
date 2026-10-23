"""Native Linux AArch64 execution in an isolated ARM64 VM container.
Cross-built from macOS with container GCC; no assembly/TLS substitution.
"""
import os,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'build/linux-a64-typed-retirement';OUT.mkdir(parents=True,exist_ok=True)
CONTAINER='fpr-typed-a64-acceptance'
env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),XDG_CACHE_HOME=str(OUT/'cache'),FPR_NO_INLINE='1',
 PKG_CONFIG_PATH='/opt/homebrew/opt/libarchive/lib/pkgconfig:'+os.environ.get('PKG_CONFIG_PATH',''))
cc=OUT/'cc';cc.write_text('#!/bin/sh\nexec docker exec -w '+str(ROOT)+' '+CONTAINER+' gcc "$@"\n');cc.chmod(0o755)
def run(args,**flags):
 p=subprocess.run(list(map(str,args)),cwd=ROOT,env=dict(env,**flags),capture_output=True,text=True,timeout=600)
 assert p.returncode==0,(args,p.returncode,p.stdout,p.stderr)
 return p.stdout+p.stderr
def guest(exe,harts=1,expected=0):
 p=subprocess.run(['docker','exec','-e','FPR_HARTS='+str(harts),'-e','FPR_HEAP_MB=256','-e','FPR_STACK_MAX_MB=8',CONTAINER,str(exe)],capture_output=True,text=True,timeout=240)
 assert (p.returncode==0)==(expected==0),(p.returncode,p.stdout,p.stderr)
 return p.stdout+p.stderr
sources=[ROOT/'tests/base/a64_fp_context.c',ROOT/'tests/base/a64_fp_context.S']
exe=OUT/'context'
run([cc,'-O2','-DFPR_POSIX','-ffixed-x28','-I'+str(ROOT/'runtime'),*sources,ROOT/'machine/unix/ctx_a64.S','-o',exe])
result=guest(exe);assert '10000 round trips' in result,result;print(result,flush=True)
broken=OUT/'integer-only.S';broken.write_text(re.sub(r'^    (?:stp|ldp) d(?:8|10|12|14),.*\n','',(ROOT/'machine/unix/ctx_a64.S').read_text(),flags=re.M))
negative=OUT/'negative';run([cc,'-O2','-DFPR_POSIX','-ffixed-x28','-I'+str(ROOT/'runtime'),*sources,broken,'-o',negative])
assert 'Assertion' in guest(negative,expected=1)
print('Linux A64 integer-only context negative control rejected PASS',flush=True)
for harts in (1,4):
 exe=OUT/f'pool-{harts}'
 run([ROOT/'fpr','build',ROOT/'tests/base/fp_pool.fpr','--target=linux-aarch64','--cc',cc,'--harts',harts,'--with',ROOT/'tests/base/fp_pool.c','--keep','-o',exe])
 result=guest(exe,harts);assert result.strip()=='162000 168000',result
 print(f'Linux A64 FP pool: 12 live values, forced yields, calls/stack growth, {harts} hart(s) PASS',flush=True)
obj=OUT/'ghc';obj.mkdir(exist_ok=True);emitter=OUT/'emit'
run(['cabal','exec','--','ghc','-O1','-w','-icompiler','-outputdir',obj,'tests/EmitA64Frames.hs','-o',emitter])
asm=OUT/'frames.s';print(run([emitter,'elf','x28','1',asm]),flush=True)
source=OUT/'actor.fpr';source.write_text('unsafe base.\nReserve.deep : Unit -> Int.\nmain = if Reserve.deep Unit == 9 then print "A64 ACTOR FRAMES HOLD" else error "nested frame count".\n')
for harts in (1,4):
 exe=OUT/f'frames-{harts}'
 run([ROOT/'fpr','build',source,'--target=linux-aarch64','--cc',cc,'--harts',harts,'--cflag','-DFPR_STACK_SZ=32752','--cflag','-DFPR_BUDDY_MIN=4096',
      '--with',ROOT/'tests/typed_ir/actor_frames.c','--with',asm,'--keep','-o',exe])
 result=guest(exe,harts);assert 'A64 ACTOR FRAMES HOLD' in result,result
 print(f'Linux A64: 9000 held fields, nine nested frames, forced yields, 32KiB first stack, {harts} hart(s) PASS',flush=True)

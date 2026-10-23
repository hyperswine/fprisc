"""Linux x64 production runtime with typed large frames, cross-built on macOS.
The isolated ARM64 container supplies GCC's x64 sysroot and QEMU user mode.
No assembly or TLS substitution is performed. This is Linux emulation evidence,
not physical x64 performance evidence.
"""
import os,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'build/linux-typed-retirement/x64'
OUT.mkdir(parents=True,exist_ok=True)
env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),XDG_CACHE_HOME=str(OUT/'cache'),
           PKG_CONFIG_PATH='/opt/homebrew/opt/libarchive/lib/pkgconfig:'+env.get('PKG_CONFIG_PATH',''))
CC=ROOT/'build/linux-typed-retirement/x86_64-cc'
RUN=ROOT/'build/linux-typed-retirement/x86_64-run'
def run(args,**flags):
 p=subprocess.run([str(x) for x in args],cwd=ROOT,env=dict(env,**flags),capture_output=True,text=True,timeout=600)
 assert p.returncode==0,(args,p.returncode,p.stdout,p.stderr)
 return p.stdout+p.stderr
obj=OUT/'ghc';obj.mkdir(exist_ok=True)
emitter=OUT/'emit'
print(run(['cabal','exec','--','ghc','-O1','-w','-icompiler','-outputdir',obj,'tests/EmitX64Frames.hs','-o',emitter]),flush=True)
asm=OUT/'frames.s';print(run([emitter,'tls','1',asm]),flush=True)
source=OUT/'actor.fpr'
source.write_text('unsafe base.\nReserve.deep : Unit -> Int.\nmain = if Reserve.deep Unit == 9 then print "X64 ACTOR FRAMES HOLD" else error "nested frame count".\n')
for harts in (1,4):
 for sized in (False,True):
  exe=OUT/f'actor-{harts}-stack{32752 if sized else 131056}'
  flags=['--cflag','-DFPR_STACK_SZ=32752','--cflag','-DFPR_BUDDY_MIN=4096'] if sized else []
  print(run([ROOT/'fpr','build',source,'--target=linux-x86_64','--cc',CC,'--harts',harts,*flags,
             '--with',ROOT/'tests/typed_ir/actor_frames.c','--with',asm,'--keep','-o',exe]),flush=True)
  result=run([RUN,exe],FPR_HARTS=str(harts),FPR_HEAP_MB='256',FPR_STACK_MAX_MB='8')
  assert 'X64 ACTOR FRAMES HOLD' in result,result
  print(f'Linux x64/QEMU: 9000 held fields, nine nested frames, exact data, forced yields; {harts} hart(s), '+('32KiB' if sized else 'default')+' first stack PASS',flush=True)

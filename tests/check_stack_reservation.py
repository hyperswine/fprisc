#!/usr/bin/env python3
"""Real actor-runtime sized reservation and failure/plane controls (this host)."""
import os,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def run(cmd,env):
 return subprocess.run([str(x) for x in cmd],cwd=ROOT,env=env,text=True,capture_output=True,timeout=240)

def main():
 env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')};env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_HARTS='1')
 for keg in ('/opt/homebrew/opt/libarchive/lib/pkgconfig','/usr/local/opt/libarchive/lib/pkgconfig'):
  if Path(keg).is_dir():env['PKG_CONFIG_PATH']=keg+':'+env.get('PKG_CONFIG_PATH','');break
 p=run(['make','fpr'],env);assert p.returncode==0,p.stdout+p.stderr
 with tempfile.TemporaryDirectory(prefix='fpr-stack-reserve-') as t:
  out=Path(t);env['XDG_CACHE_HOME']=str(out/'cache')
  for mode,reason in [(0,None),(1,'reservation exceeds the address range'),(2,'plane memory ABI mismatch'),
                      (3,"fpr_stack_max"),(4,'actor-owned stack'),(5,'plane memory ABI mismatch')]:
   src=out/f'mode-{mode}.fpr';src.write_text(f'unsafe base.\nReserve.exercise : Int -> Int.\nmain = print (Reserve.exercise {mode}).\n')
   exe=out/f'mode-{mode}'
   p=run([ROOT/'fpr','build',src,'--harts','1','--with',ROOT/'tests/typed_ir/runtime_reserve.c','-o',exe],env)
   assert p.returncode==0,p.stdout+p.stderr
   p=run([exe],env)
   if reason is None:assert p.returncode==0 and p.stdout=='32\n',(p.returncode,p.stdout,p.stderr)
   else:assert p.returncode==1 and reason in p.stdout+p.stderr,(mode,p.returncode,p.stdout,p.stderr)
   print(f'Sized stack runtime mode {mode}: '+('32 one-MiB reserve/return/reuse cycles and exact plane delegation PASS' if reason is None else reason+' refused PASS'),flush=True)

if __name__=='__main__':main()

#!/usr/bin/env python3
"""Every selected native backend refuses incomplete coverage before assembly."""
import os,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def main():
 env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
 env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT))
 with tempfile.TemporaryDirectory(prefix='fpr-native-required-') as d:
  out=Path(d);env['XDG_CACHE_HOME'] = os.environ.get('XDG_CACHE_HOME', str(out/'cache'))
  good=out/'good.fpr';good.write_text('main = print 42.\n')
  bad=out/'unsupported.fpr'
  bad.write_text('Wide.call : '+' -> '.join(['Int']*66)+'.\nsafe x = x+1.\n'
                 'main = Wide.call '+' '.join(['1']*65)+'.\n')
  modes=[{}, {'FPR_TYPED_IR_BACKEND':'mixed'}, {'FPR_TYPED_IR_BACKEND':'1'},
         {'FPR_TYPED_IR_BACKEND':'mixed','FPR_TYPED_IR_STRICT':'safe'},
         {'FPR_TYPED_IR_BACKEND':'mixed','FPR_TYPED_IR_STRICT':''}]
  for width in ('32','64'):
   cmd=[ROOT/'fpr','compile','--system=bare-metal','--target=rv'+width]
   for i,flags in enumerate(modes):
    asm=out/f'refused-{width}-{i}.s'
    p=subprocess.run([*map(str,cmd),str(bad),str(asm)],cwd=ROOT,env=dict(env,**flags),capture_output=True,text=True,timeout=600)
    assert p.returncode!=0 and 'typed-ir strict: root:' in p.stderr and '\n  main: ' in p.stderr and 'Wide.call' in p.stderr,(i,p.stdout,p.stderr)
    assert not asm.exists(),asm
   asm=out/f'good-{width}.s'
   p=subprocess.run([*map(str,cmd),str(good),str(asm)],cwd=ROOT,env=env,capture_output=True,text=True,timeout=600)
   assert p.returncode==0,p.stdout+p.stderr
   for path in [asm,*map(Path,Path(str(asm)+'.units').read_text().splitlines())]:
    text=path.read_text();assert text.startswith('# typed IR: no translation') and '# wcet:' not in text,path
   for alias in ('legacy','off','0'):
    old=asm.read_bytes()
    p=subprocess.run([*map(str,cmd),str(good),str(asm)],cwd=ROOT,env=dict(env,FPR_TYPED_IR_BACKEND=alias),capture_output=True,text=True,timeout=120)
    assert p.returncode!=0 and 'legacy backend has been retired on every target' in p.stderr,(p.stdout,p.stderr)
    assert asm.read_bytes()==old
   print(f'RV{width}: mandatory native coverage, named refusals, native root/units and rollback aliases rejected with existing output preserved PASS',flush=True)
  for source in ('compiler/A64.hs','compiler/X64.hs','compiler/RV64.hs','compiler/Peephole.hs'):
   assert not (ROOT/source).exists(),source
  p=subprocess.run([ROOT/'fpr','compile','--target=rv64',str(good),str(out/'summary.s')],cwd=ROOT,env=dict(env,FPRC_NATIVE_INSNS='1'),capture_output=True,text=True,timeout=600)
  assert p.returncode==0 and '[native-insns-v1] root:' in p.stderr and '[wcet]' not in p.stderr,(p.stdout,p.stderr)
  print('Retired generator/translator/peephole modules absent; native instruction summary PASS',flush=True)

if __name__=='__main__':main()

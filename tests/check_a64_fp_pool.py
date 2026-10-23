#!/usr/bin/env python3
"""Real A64 context switches and generated FP values across yields/calls."""
import os,platform,re,tempfile,subprocess
from pathlib import Path
from x64_probe import ROOT,run

def main():
 if platform.machine() not in ('arm64','aarch64'):print('A64 FP pool execution SKIP');return
 env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')};env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_NO_INLINE='1')
 with tempfile.TemporaryDirectory(prefix='fpr-a64-fp-') as d:
  tmp=Path(d);env['XDG_CACHE_HOME']=str(tmp/'cache')
  exe=tmp/'context'
  run(['clang','-O2','-DFPR_POSIX','-ffixed-x28','-I'+str(ROOT/'runtime'),ROOT/'tests/base/a64_fp_context.c',ROOT/'tests/base/a64_fp_context.S',ROOT/'machine/unix/ctx_a64.S','-o',exe],env)
  print(run([exe],env).strip(),flush=True)
  # Removing FP state must make this independent context oracle fail.
  broken=tmp/'ctx-integer-only.S'
  broken.write_text(re.sub(r'^    (?:stp|ldp) d(?:8|10|12|14),.*\n','',(ROOT/'machine/unix/ctx_a64.S').read_text(),flags=re.M))
  negative=tmp/'integer-only'
  run(['clang','-O2','-DFPR_POSIX','-ffixed-x28','-I'+str(ROOT/'runtime'),ROOT/'tests/base/a64_fp_context.c',ROOT/'tests/base/a64_fp_context.S',broken,'-o',negative],env)
  bad=subprocess.run([str(negative)],env=env,capture_output=True,text=True,timeout=30)
  assert bad.returncode!=0 and 'Assertion' in bad.stderr,(bad.returncode,bad.stderr)
  print('A64 FP context: integer-only switch negative control fails as required PASS',flush=True)
  asm=tmp/'pool.s';run([ROOT/'fprc','--target=a64','--system=posix',ROOT/'tests/base/fp_pool.fpr',asm],env)
  text=asm.read_text();body=text.split('# fn hold ',1)[1].split('# native-insns-v1:',1)[0]
  assert re.search(r'saved=\S*d(?:8|9|1[0-5])',body),body[:500]
  assert 'ldr d0' in body or 'ldur d0' in body or 'ldr d1' in body or 'ldur d1' in body,'FP register pressure must exercise spills'
  exe=tmp/'pool';run([ROOT/'fpr','build',ROOT/'tests/base/fp_pool.fpr','--with',ROOT/'tests/base/fp_pool.c','-o',exe],env)
  for harts in ('1','4'):
   out=run([exe],dict(env,FPR_HARTS=harts));assert out.strip()=='162000 168000',out
   print('A64 FP pool: 12 live values across forced yields, recursive calls/stack growth and '+harts+' harts PASS',flush=True)
if __name__=='__main__':main()

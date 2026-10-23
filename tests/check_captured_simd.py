#!/usr/bin/env python3
"""Captured NEON/SSE2 maps against scalar emission and independent C."""
import os,platform,re,tempfile
from pathlib import Path
from x64_probe import ROOT,run,adapt,borrowed_oracle,host,link

def main():
    env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_NO_INLINE='1',FPR_NO_SCALAR_WORKERS='1',FPR_NO_FIELD_WORKERS='1',FPR_TYPED_IR_STRICT='all')
    with tempfile.TemporaryDirectory(prefix='fpr-captured-simd-') as d:
        tmp=Path(d);env['XDG_CACHE_HOME']=str(tmp/'cache')
        fixture=ROOT/'tests/typed_ir/captured_simd.fpr'
        for target in ('qa64mac','x64','qx64'):
          a64=target=='qa64mac'
          for scalar in (False,True):
            mode=dict(env,FPR_NO_VEC_SIMD='1' if scalar else '0')
            asm=tmp/'maps.s';run([ROOT/'fprc','--target='+target,fixture,asm],mode)
            text=asm.read_text()
            assert '# typed IR: no translation' in text and '# wcet:' not in text
            bodies=re.findall(r'(?ms)^# fn ([^\n]+)\n(.*?)(?=^# native-insns-v1:)',text)
            kernels={n.split()[0].split('fpr_vspec_map_')[-1]:b for n,b in bodies if n.startswith('$vkernel:fpr_vspec_map_')}
            lane='ldr q16, [' if a64 else 'movdqu ('
            for name in ('addCap','subCap','rsubCap','affineCap'):
                assert (lane in kernels[name]) != scalar,(target,name,scalar)
                if not scalar:assert re.search(r'dup v\d+\.2d' if a64 else 'punpcklqdq',kernels[name]),name
            assert (lane in kernels['wideCap'])==(a64 and not scalar)
            assert lane not in kernels['longCap']
            assert 'mixedCap' not in kernels
            assert lane not in kernels['heavyCap']
            assert not re.search(r'\bfmadd\b|\bfmla\b|\bvfmadd',text)
            if not a64:
                regs=[int(n) for n in re.findall(r'%xmm(\d+)',kernels['affineCap'])]
                assert all(8<=n<=15 for n in regs)
            print(target+' SIMD emission, scratch budget and scalar boundaries PASS; scalar='+str(scalar),flush=True)
            if a64:
                if platform.machine() not in ('arm64','aarch64'):continue
                runner=[]
            else:
                available=host()
                if available is None:print('x64 execution SKIP');continue
                mac,runner,label=available
            chosen=[b for n,b in bodies if n.split()[0] not in ('main','plus','mixedCap','probeMixed') and not n.startswith('$vkernel:fpr_vspec_fold_') and not n.startswith('lifted_')]
            body='\n'.join(chosen)
            objects=set(re.findall(r'\b_?(fpr_obj_[A-Za-z0-9_]+)',body))
            source=(ROOT/'tests/typed_ir/captured_simd_oracle.c').read_text()
            if target=='qx64':source=borrowed_oracle(source)
            oracle=tmp/'oracle.c';oracle.write_text(source+'\n'+'\n'.join(f'char {o}[40];' for o in sorted(objects)))
            asm.write_text('.text\n'+(body if a64 else adapt(body,mac,borrowed=target=='qx64')))
            exe=tmp/'oracle'
            def build(extra):
                if a64:run(['clang','-O2','-ffp-contract=off','-ffixed-x28',*extra,asm,oracle,'-o',exe],mode)
                else:link(['-ffp-contract=off',*extra,asm,oracle],exe,mac,mode)
            build([]);out=run([*runner,exe],mode);assert 'CAPTURED_SIMD_PASS' in out,out
            print(target+': '+out.strip(),flush=True)
            for case in range(1,7):
                build(['-DTRAP_CASE='+str(case)]);out=run([*runner,exe],mode)
                assert 'CAPTURED_SIMD_TRAP_PASS' in out,(target,scalar,case,out)
            print(target+' Int overflow: first/second lane, add/sub/reverse-sub PASS; scalar='+str(scalar),flush=True)
        if platform.machine() in ('arm64','aarch64'):
            exe=tmp/'hosted';run([ROOT/'fpr','build',fixture,'-o',exe],env)
            for harts in ('1','4'):assert run([exe],dict(env,FPR_HARTS=harts))=='-498500\n'
            print('Captured SIMD: real hosted runtime, 1/4 harts PASS',flush=True)
if __name__=='__main__':main()

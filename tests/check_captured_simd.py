#!/usr/bin/env python3
"""Captured A64 NEON maps against scalar emission and independent C."""
import os,platform,re,tempfile
from pathlib import Path
from x64_probe import ROOT,run

def main():
    env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_NO_INLINE='1',FPR_NO_SCALAR_WORKERS='1',FPR_NO_FIELD_WORKERS='1',FPR_TYPED_IR_STRICT='all')
    with tempfile.TemporaryDirectory(prefix='fpr-captured-simd-') as d:
        tmp=Path(d);env['XDG_CACHE_HOME']=str(tmp/'cache')
        fixture=ROOT/'tests/typed_ir/captured_simd.fpr'
        for scalar in (False,True):
            mode=dict(env,FPR_NO_VEC_SIMD='1' if scalar else '0')
            asm=tmp/'maps.s';run([ROOT/'fprc','--target=qa64mac',fixture,asm],mode)
            text=asm.read_text()
            assert '# typed IR: no translation' in text and '# wcet:' not in text
            bodies=re.findall(r'(?ms)^# fn ([^\n]+)\n(.*?)(?=^# native-insns-v1:)',text)
            kernels={n.split()[0].split('fpr_vspec_map_')[-1]:b for n,b in bodies if n.startswith('$vkernel:fpr_vspec_map_')}
            for name in ('addCap','subCap','rsubCap','affineCap','wideCap'):
                assert ('ldr q16, [' in kernels[name]) != scalar,(name,scalar)
                if not scalar:assert re.search(r'dup v\d+\.2d',kernels[name]),name
            assert 'ldr q16, [' not in kernels['longCap']
            assert 'mixedCap' not in kernels
            assert 'ldr q16, [' not in kernels['heavyCap']
            assert not re.search(r'\bfmadd\b|\bfmla\b',text)
            print('Captured NEON emission and scalar boundaries PASS; scalar='+str(scalar),flush=True)
            if platform.machine() not in ('arm64','aarch64'):continue
            chosen=[b for n,b in bodies if n.split()[0] not in ('main','plus','mixedCap','probeMixed') and not n.startswith('$vkernel:fpr_vspec_fold_') and not n.startswith('lifted_')]
            body='\n'.join(chosen)
            asm.write_text('.text\n'+body)
            objects=set(re.findall(r'\b_?(fpr_obj_[A-Za-z0-9_]+)',body))
            oracle=tmp/'oracle.c';oracle.write_text((ROOT/'tests/typed_ir/captured_simd_oracle.c').read_text()+'\n'+'\n'.join(f'char {o}[40];' for o in sorted(objects)))
            exe=tmp/'oracle'
            def build(extra):
                run(['clang','-O2','-ffp-contract=off','-ffixed-x28',*extra,asm,oracle,'-o',exe],mode)
            build([]);out=run([exe],mode);assert 'CAPTURED_SIMD_PASS' in out,out
            print(out.strip(),flush=True)
            for case in range(1,7):
                build(['-DTRAP_CASE='+str(case)]);out=run([exe],mode)
                assert 'CAPTURED_SIMD_TRAP_PASS' in out,(scalar,case,out)
            print('Captured Int overflow: first/second lane, add/sub/reverse-sub PASS; scalar='+str(scalar),flush=True)
        if platform.machine() in ('arm64','aarch64'):
            exe=tmp/'hosted';run([ROOT/'fpr','build',fixture,'-o',exe],env)
            for harts in ('1','4'):assert run([exe],dict(env,FPR_HARTS=harts))=='-498500\n'
            print('Captured SIMD: real hosted runtime, 1/4 harts PASS',flush=True)
if __name__=='__main__':main()

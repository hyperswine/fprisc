#!/usr/bin/env python3
"""Typed column CFGs: real hosted execution and independent x64/RV oracles."""
import argparse
import os
from pathlib import Path
import re
import shutil
import tempfile
import subprocess
from check_vector_pipelines import check_execution
from x64_probe import adapt, host, link, run

ROOT=Path(__file__).resolve().parents[1]
FIX=ROOT/'tests/typed_ir'

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--require-execution',action='store_true',help='require x64 and both RV widths')
    args=ap.parse_args()
    env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
    env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_NO_INLINE='1',
               FPR_NO_SCALAR_WORKERS='1',FPR_NO_FIELD_WORKERS='1',FPR_TYPED_IR_BACKEND='mixed')
    for keg in ('/opt/homebrew/opt/libarchive/lib/pkgconfig','/usr/local/opt/libarchive/lib/pkgconfig'):
        if Path(keg).is_dir():
            env['PKG_CONFIG_PATH']=keg+':'+env.get('PKG_CONFIG_PATH','')
            break
    run(['make','fpr'],env)
    ghc=['cabal','exec','--','runghc'] if shutil.which('cabal') else ['runghc']
    print(run([*ghc,'-w','-icompiler',ROOT/'tests/KernelIR.hs'],env).strip(),flush=True)
    with tempfile.TemporaryDirectory(prefix='fpr-typed-kernels-') as d:
        tmp=Path(d);env['XDG_CACHE_HOME']=str(tmp/'cache')
        # The real runtime supplies allocation, fallback and actor scheduling.
        exe=tmp/'hosted'
        run([ROOT/'fpr','build',FIX/'kernels.fpr','-o',exe],env)
        for harts in ('1','4'):
            assert run([exe],dict(env,FPR_HARTS=harts))=='750507\n'
        print('typed kernels: hosted result, one/four harts PASS',flush=True)
        for inline in ('0','1'):
            mode=dict(env,FPR_NO_PIPELINE_INLINE=inline)
            run([ROOT/'fpr','build',ROOT/'tests/base/vecpipeline.fpr',
                 '--with',ROOT/'tests/bench/workers_clock.c','--with',ROOT/'tests/base/floatprobe.c','-o',exe],mode)
            def execute(case,harts):
                p=subprocess.run([str(exe)]+([case] if case else []),env=dict(mode,FPR_HARTS=str(harts)),
                                 capture_output=True,text=True,timeout=60)
                return p.returncode,p.stdout,p.stderr
            check_execution(execute)
            print(f'hosted typed pipeline: Int/F64/F32, eight arguments, boxed fallback, effects and traps; inline-disabled={inline} PASS',flush=True)
        # No kernel plan is refused by name any more (F32, mapAs, write-back, record,
        # NEON and RVV shapes all lower); strict mode still reports compiler errors
        # and unbounded segments. The builders' own refusals are KernelIR.hs's.
        check_targets(env,tmp,args,FIX/'kernels.fpr',(FIX/'kernel_oracle.c').read_text(),6,4)
        run([ROOT/'fpr','build',FIX/'record_kernels.fpr','-o',exe],dict(env,FPR_TYPED_IR_STRICT='all'))
        for harts in ('1','4'):
            assert run([exe],dict(env,FPR_HARTS=harts))=='92359\n'
        print('typed record kernels: hosted result, one/four harts PASS',flush=True)
        support=(FIX/'kernel_oracle.c').read_text().split('extern V fpr_fn_probeDiv')[0]
        run([ROOT/'fpr','build',FIX/'f32_kernels.fpr','-o',exe],dict(env,FPR_TYPED_IR_STRICT='all'))
        for harts in ('1','4'):
            assert run([exe],dict(env,FPR_HARTS=harts))=='14881\n'
        print('typed F32 kernels: hosted result, one/four harts PASS',flush=True)
        check_targets(env,tmp,args,FIX/'f32_kernels.fpr',support+(FIX/'f32_oracle.c').read_text(),3,0,floating=True)
        run([ROOT/'fpr','build',FIX/'pairsum_kernels.fpr','-o',exe],dict(env,FPR_TYPED_IR_STRICT='all'))
        for harts in ('1','4'):
            assert run([exe],dict(env,FPR_HARTS=harts))=='1498505\n'
        print('typed pair-sum fold: hosted result (the GPU hook declines), one/four harts PASS',flush=True)
        check_targets(env,tmp,args,FIX/'pairsum_kernels.fpr',support+(FIX/'pairsum_oracle.c').read_text(),1,0)
        # mapAs and the write-back fold: hosted, legacy and typed agree; the
        # typed root names both kernels and no legacy loop
        legacy=dict(env,FPR_TYPED_IR_BACKEND='legacy')
        outputs=[]
        for mode in (legacy,dict(env,FPR_TYPED_IR_STRICT='all')):
            run([ROOT/'fpr','build',FIX/'mapas_kernels.fpr','-o',exe],mode)
            outputs.append(run([exe],dict(mode,FPR_HARTS='4')))
        assert outputs[0]==outputs[1] and outputs[0].split()==['45','97','90'],outputs
        asm=tmp/'mapas.s'
        run([ROOT/'fpr','compile','--target=a64',FIX/'mapas_kernels.fpr',asm],dict(env,FPR_TYPED_IR_STRICT='all'))
        text=asm.read_text()
        assert '$vkernel:fpr_vspec_mapAs' in text and '$vkernel:fpr_vspec_wfold' in text,text[-3000:]
        assert 'direct scalar kernel' not in text and 'write-back fold:' not in text
        print('typed mapAs and write-back fold: hosted agreement with legacy, typed kernels named PASS',flush=True)
        # NEON: the two-lane body on A64, scalar tails; its hosted IEEE reference is check_vector_kinds
        for fixture,lanes in (('vecsimd.fpr',r'fmul v\d+\.2d'),('vecsimd_int.fpr',r'add v\d+\.2d')):
            run([ROOT/'fpr','compile','--target=a64',ROOT/'tests/base'/fixture,asm],dict(env,FPR_TYPED_IR_STRICT='all'))
            text=asm.read_text()
            assert 'ldr q16, [' in text and re.search(lanes,text) and '[NEON 2 lanes]' not in text,fixture
        print('typed NEON pairs: emitted for the Int and F64 SIMD fixtures under strict mode PASS',flush=True)
        check_targets(env,tmp,args,FIX/'record_kernels.fpr',support+(FIX/'record_oracle.c').read_text(),5,1)
        run([ROOT/'fpr','build',FIX/'record_float_kernels.fpr','-o',exe],dict(env,FPR_TYPED_IR_STRICT='all'))
        for harts in ('1','4'):
            assert run([exe],dict(env,FPR_HARTS=harts))=='17.5\n'
        check_targets(env,tmp,args,FIX/'record_float_kernels.fpr',support+(FIX/'record_float_oracle.c').read_text(),3,0,True)



def check_targets(env,tmp,args,fixture,oracle_source,kernel_count,trap_count,floating=False):
    for target in (('a64','x64','rv64') if floating else ('a64','x64','rv64','rv32')):
        asm=tmp/(target+'.s')
        # run() returns stdout only; routing is asserted in emitted code.
        run([ROOT/'fpr','compile','--target='+target,fixture,asm],dict(env,FPR_TYPED_IR_STRICT='all'))
        text=asm.read_text()
        assert '# typed IR: no translation' in text,target
        assert 'fpr_ufn_' not in text,target
        bodies=re.findall(r'(?ms)^# fn ([^\n]+)\n(.*?)(?=^# (?:wcet|native-insns-v1):)',text)
        # The fixture's filler and lifted layout constructor belong only to
        # hosted main; the C oracle constructs descriptors independently.
        chosen=[(name,body) for name,body in bodies
                if name.split()[0] not in ('main','fill') and not name.startswith('lifted_')]
        kernels=[name for name,_ in chosen if name.startswith('$vkernel:fpr_vspec_')]
        assert len(kernels)==kernel_count,(target,kernels)
        print(f'{target}: {kernel_count} typed kernel CFGs; no legacy assembly PASS',flush=True)
        if target=='a64': continue # actual A64 runtime on the matching host above
        body='\n'.join(b for _,b in chosen)
        objects=set(re.findall(r'\bfpr_obj_[A-Za-z0-9_]+',body))
        oracle=tmp/(target+'.c')
        oracle.write_text(oracle_source+'\n'+'\n'.join(f'char {o}[40];' for o in sorted(objects)))
        if target=='x64':
            available=host()
            if available is None:
                assert not args.require_execution,'x64 execution unavailable'
                print('x64 execution SKIP');continue
            mac,runner,label=available
            asm.write_text('.text\n'+adapt(body,mac))
            exe=tmp/'x64-oracle';link([asm,oracle],exe,mac,env)
            output=run([*runner,exe],env)
        else:
            width=target[2:]
            missing=[t for t in ('riscv64-unknown-elf-gcc','qemu-system-riscv'+width) if not shutil.which(t)]
            if missing:
                assert not args.require_execution,missing
                print(target+' execution SKIP: '+', '.join(missing));continue
            asm.write_text('.text\n'+body)
            crt=tmp/(target+'-crt.S');crt.write_text((FIX/'kernel_crt.S').read_text().replace('sd ra','sw ra').replace('ld ra','lw ra') if width=='32' else (FIX/'kernel_crt.S').read_text())
            exe=tmp/(target+'.elf')
            run(['riscv64-unknown-elf-gcc','-march=rv'+width+('imafd_zicsr_zifencei' if floating else 'im_zicsr_zifencei'),'-mabi='+('lp64' if width=='64' else 'ilp32'),
                 '-mcmodel=medany','-msmall-data-limit=0','-O2','-ffreestanding','-nostdlib','-fno-builtin',
                 '-T',FIX/'kernel_link.ld',crt,asm,oracle,'-o',exe],env)
            output=run(['qemu-system-riscv'+width,'-machine','virt','-smp','1','-m','16M','-nographic','-bios','none','-kernel',exe],env)
        assert 'TYPED_KERNEL_PASS' in output,output
        print(target+': '+output.strip(),flush=True)
        for trap in range(1,trap_count+1):
            case=tmp/(target+'-trap.c')
            case.write_text(f'#define TRAP_CASE {trap}\n'+oracle.read_text())
            if target=='x64':
                link([asm,case],exe,mac,env)
                result=run([*runner,exe],env)
            else:
                run(['riscv64-unknown-elf-gcc','-march=rv'+width+('imafd_zicsr_zifencei' if floating else 'im_zicsr_zifencei'),'-mabi='+('lp64' if width=='64' else 'ilp32'),
                     '-mcmodel=medany','-msmall-data-limit=0','-O2','-ffreestanding','-nostdlib','-fno-builtin',
                     '-T',FIX/'kernel_link.ld',crt,asm,case,'-o',exe],env)
                result=run(['qemu-system-riscv'+width,'-machine','virt','-smp','1','-m','16M','-nographic','-bios','none','-kernel',exe],env)
            assert 'TYPED_KERNEL_TRAP_PASS' in result,(target,trap,result)
        if trap_count: print(f'{target}: {trap_count} checked arithmetic trap cases PASS',flush=True)

if __name__=='__main__': main()

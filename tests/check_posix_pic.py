#!/usr/bin/env python3
"""ELF shared module relocation checks; execution lives in check_posix_modules."""
import os, re, shutil, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
if not all(shutil.which(x) for x in ('clang','ld.lld')):
    print('ELF module artifact check SKIPPED: requires clang and ld.lld')
    raise SystemExit(0)
def run(args, env=None):
    p=subprocess.run(list(map(str,args)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=180)
    assert p.returncode==0,p.stdout+p.stderr
    return p.stdout
with tempfile.TemporaryDirectory(prefix='fpr-module-pic-') as directory:
    d=Path(directory);src=d/'module.fpr'
    # Runtime descriptors, imported prelude, TLS argument spills and literals.
    src.write_text('sum a b c d e f g h i = a+b+c+d+e+f+g+h+i.\nop v = strlen "module" + sum v 1 2 3 4 5 6 7 8.\n')
    for target,triple,machine in [('x64','x86_64-linux-gnu',62),('a64','aarch64-linux-gnu',183),('rv64','riscv64-linux-gnu',243)]:
        if target == 'rv64' and not re.search(r'\briscv64\b', run(['clang', '--print-targets'])):
            print('POSIX rv64 artifact check SKIPPED: clang has no RISC-V backend; use a Linux RV64 cross compiler with check_rv64_linux.py')
            continue
        asm=d/(target+'.s')
        run([ROOT/'fpr','compile','--system=posix','--target='+target,'--plugin',src,asm],
            env=dict(os.environ,FPR_TYPED_IR_BACKEND='mixed') if target=='a64' else None)
        objs=[]
        for i,unit in enumerate([str(asm),*Path(str(asm)+'.units').read_text().split()]):
            obj=d/(target+str(i)+'.o');run(['clang','--target='+triple,'-c',unit,'-o',obj]);objs.append(obj)
        shared=d/(target+'.so')
        run(['ld.lld','-shared','-Bsymbolic','-z','text',*objs,'-o',shared])
        data=shared.read_bytes()
        assert int.from_bytes(data[18:20],'little')==machine
        print(f'POSIX {target}: root/imports/TLS/9-argument spill, ELF shared object without text relocations PASS')

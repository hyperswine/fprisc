#!/usr/bin/env python3
"""Record cold Base field-worker compiler and code-size scaling.

The source family grows the number of independent helpers at fixed body/shape
size. Removing a helper-count cutoff should preserve affine function and
assembled-code growth. Compiler allocation/time are recorded, while the
repository's unchanged absolute compile-budget gate remains authoritative.
"""
import argparse
import ast
import hashlib
import os
from pathlib import Path
import re
import json
import subprocess
import sys
import tempfile
import time
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests'))
from check_finite_field_workers import fixture


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline-compiler',type=Path,required=True)
    ap.add_argument('--family',choices=['helpers','parameters'],default='helpers')
    ap.add_argument('--record',type=Path,required=True)
    args=ap.parse_args();rows=[]
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory(prefix='fpr-field-scaling-') as directory:
        tmp=Path(directory)
        for count in ((16,32,64,128,256) if args.family=='helpers' else (8,16,32,64)):
            forms={}
            for name,compiler,explicit in [('before',args.baseline_compiler.resolve(),False),('after',ROOT/'fpr',False),('explicit',ROOT/'fpr',True)]:
                d=tmp/f'{count}-{name}';d.mkdir()
                src=d/'main.fpr';src.write_text(fixture(args.family,count,explicit=explicit)[0])
                out,stats=d/'out.s',d/'rts'
                env={k:v for k,v in os.environ.items() if not k.startswith('FPR_') and k!='GHCRTS'}
                env.update(FPR_HOME=str(ROOT),XDG_CACHE_HOME=str(d/'cache'))
                start=time.monotonic()
                p=subprocess.run([compiler,'compile','--system=posix','--target=rv64',src,out,'+RTS','-t'+str(stats),'--machine-readable','-RTS'],cwd=ROOT,env=env,text=True,capture_output=True,timeout=240)
                assert p.returncode==0,(count,name,p.stderr[-5000:])
                seconds=time.monotonic()-start
                rts=dict(ast.literal_eval(stats.read_text().split('\n',1)[1]))
                obj=d/'out.o'
                subprocess.run(['riscv64-unknown-elf-gcc','-ffixed-x27','-march=rv64imafdc_zicsr','-mabi=lp64','-c',out,'-o',obj],check=True,capture_output=True)
                sizes=subprocess.check_output(['riscv64-unknown-elf-size','-A',obj],text=True)
                text_bytes=sum(int(n) for n in re.findall(r'^\.text(?:\.\S+)?\s+(\d+)',sizes,re.M))
                asm=out.read_text();functions=len(re.findall(r'^# fn ',asm,re.M))
                private=len(re.findall(r'^# fn (?:\$worker\.fields\.)+bump(?:\d+)?\s+\(',asm,re.M))
                if name=='after':assert private==(count if args.family=='helpers' else 1),(count,name,private)
                if name=='explicit':assert private==0,(count,name,private)
                forms[name]=dict(compiler_sha256=sha(compiler),source_sha256=sha(src),allocated_bytes=int(rts['bytes allocated']),max_bytes_used=int(rts['max_bytes_used']),wall_seconds=round(seconds,4),text_bytes=text_bytes,functions=functions,field_workers=private)
            rows.append(dict(helpers=count,**forms))
            print(count,'helpers:',{n:(r['functions'],r['field_workers'],r['text_bytes'],round(r['allocated_bytes']/1e9,3)) for n,r in forms.items()},flush=True)
        # Fixed-size definitions have affine root-function counts. Assembled
        # bytes may change at instruction-immediate and branch-distance limits;
        # report them rather than imposing a synthetic percentage image cap.
        if args.family=='helpers':
            for form,slope in [('after',2),('explicit',1)]:
                for lo,hi in zip(rows,rows[1:]):
                    assert hi[form]['functions']-lo[form]['functions']==slope*(hi['helpers']-lo['helpers']),(form,lo,hi)
        else:
            assert len({r['after']['functions'] for r in rows if r['helpers']>8})==1,rows
    args.record.write_text(json.dumps(dict(compiler_sha256=sha(ROOT/'fpr'),tool_sha256=sha(Path(__file__)),fixture_sha256=sha(ROOT/'tests/check_finite_field_workers.py'),cold_cache=True,family=args.family,target='rv64imafdc_zicsr/lp64',scope='Root code/function growth and whole cold compiler cost; explicit form has no general product entry and therefore a smaller public contract',rows=rows),indent=2)+'\n')
    print('Finite field-worker scaling: complete coverage and expected function growth PASS',flush=True)


if __name__=='__main__':main()

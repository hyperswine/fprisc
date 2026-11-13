#!/usr/bin/env python3
"""Shared RV64 scalar selection: unchanged code, exact bits and bounded loops."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
sys.path.insert(0,str(ROOT/'tests/build-reference'))
import build_static_arena as gate

SOURCE='''profile builtin.
addWords : Word -> Word -> Word.
addWords a b = Word.add a b.
subWords : Word -> Word -> Word.
subWords a b = Word.sub a b.
andWords : Word -> Word -> Word.
andWords a b = Word.and a b.
orWords : Word -> Word -> Word.
orWords a b = Word.or a b.
xorWords : Word -> Word -> Word.
xorWords a b = Word.xor a b.
notWord : Word -> Word.
notWord a = Word.not a.
fromInteger : Int -> Word.
fromInteger a = Word.fromInt a.
toInteger : Word -> Int.
toInteger a = Word.toInt a.
wordWidth : Unit -> Int.
wordWidth u = Word.bits u.
wordEqual : Word -> Word -> Bool.
wordEqual a b = Word.eq a b.
rawEqual : Word -> Word -> Bool.
rawEqual a b = a == b.
rawDifferent : Word -> Word -> Bool.
rawDifferent a b = a != b.
less : Int -> Int -> Bool.
less a b = a < b.
greater : Int -> Int -> Bool.
greater a b = a > b.
lessEqual : Int -> Int -> Bool.
lessEqual a b = a <= b.
greaterEqual : Int -> Int -> Bool.
greaterEqual a b = a >= b.
addressRoundTrip : Word -> Word.
addressRoundTrip a = Addr.toWord (Addr.fromWord a).
addressOffset : Word -> Int -> Word.
addressOffset a n = Addr.toWord (Addr.add (Addr.fromWord a) n).
addressNull : Unit -> Word.
addressNull u = Addr.toWord (Addr.null u).
addressEqual : Word -> Word -> Bool.
addressEqual a b = Addr.eq (Addr.fromWord a) (Addr.fromWord b).
go : Word -> Word -> Word.
go n a = if Word.eq n (Word.fromInt 0) then a else go (Word.sub n (Word.fromInt 1)) (Word.add a (Word.fromInt 1)).
runLoop : Word -> Word -> Word.
runLoop n a = go n a.
badShift : Word -> Int -> Word.
badShift a n = Word.shl a n.
badAdd : Int -> Int -> Int.
badAdd a b = a + b.
'''
MASK=2**64-1


def instructions(text):
    return [s for s in text.splitlines() if s.strip() and not s.lstrip().startswith('#')]


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline-compiler',type=Path)
    ap.add_argument('--require-execution',action='store_true')
    ap.add_argument('--record',type=Path)
    args=ap.parse_args()
    record=dict(schema='scalar-admission-v1',compiler_sha256=gate.sha((ROOT/'fpr').read_bytes()),
        test_sha256=gate.sha(Path(__file__).read_bytes()),source_sha256=gate.sha(SOURCE.encode()),cases=[],refusals=[])
    with tempfile.TemporaryDirectory(prefix='fpr-scalar-admission-') as directory:
        out=Path(directory);source=out/'scalar.fpr';source.write_text(SOURCE)
        env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
        env.update(FPR_HOME=str(ROOT),FPR_NO_INLINE='1',XDG_CACHE_HOME=str(out/'cache'))
        exports=','.join(n for n in re.findall(r'^(\w+) :',SOURCE,re.M) if n not in ('go','badShift','badAdd'))
        def compile(compiler,name,flags=(),export=exports,expected=0):
            asm=out/(name+'.s')
            p=subprocess.run([str(compiler),'compile','--profile=bare-metal-builtin','--arc','--lib','--export='+export,
                *flags,str(source),str(asm)],cwd=ROOT,env=env,capture_output=True,text=True,timeout=180)
            assert p.returncode==expected,(p.returncode,p.stdout[-2000:],p.stderr[-2000:])
            return asm,p.stdout+p.stderr
        plain,_=compile(ROOT/'fpr','plain')
        admitted,_=compile(ROOT/'fpr','admitted',['--heap-budget=65536'])
        assert instructions(plain.read_text())==instructions(admitted.read_text())
        record['admission_preserves_instructions_and_data']=True
        if args.baseline_compiler:
            before,_=compile(args.baseline_compiler,'before')
            assert instructions(before.read_text())==instructions(plain.read_text()),'resource selection changed emitted instructions/data'
            _,failure=compile(args.baseline_compiler,'old-refusal',['--heap-budget=65536'],expected=1)
            assert 'UNPROVED' in failure
            record['baseline_compiler_sha256']=gate.sha(args.baseline_compiler.read_bytes())
            record['baseline_code_identical']=True
            record['baseline_heap_refusal']=failure[-2000:]
        for export in ('badShift','badAdd'):
            _,failure=compile(ROOT/'fpr','refused-'+export,['--heap-budget=65536'],export,1)
            assert 'UNPROVED' in failure
            record['refusals'].append(dict(entry=export,output=failure[-1500:]))
        print('Scalar admission: ordinary/admitted instructions identical; guarded shift/overflow fallbacks still refuse',flush=True)
        missing=[n for n in ('riscv64-unknown-elf-gcc','qemu-system-riscv64') if not shutil.which(n)]
        if missing:
            assert not args.require_execution,missing
            record['execution']=dict(status='SKIP',missing=missing)
        else:
            cases=[]
            pairs=[(0,MASK),(MASK,1),(0x8000000000000000,0x8000000000000001),(0xaaaaaaaaaaaaaaaa,0x5555555555555555)]
            for a,b in pairs:
                for name,answer in [('addWords',a+b),('subWords',a-b),('andWords',a&b),('orWords',a|b),('xorWords',a^b)]:
                    cases.append((name,[a,b],answer&MASK))
            for value in [0,1,2**62-1,2**62,2**63-1,2**63,MASK]:
                tagged=value&((1<<63)-1);signed=tagged-(1<<63) if tagged>=1<<62 else tagged
                cases.extend([('toInteger',[value],signed&MASK),('notWord',[value],(~value)&MASK),('addressRoundTrip',[value],value)])
            for value in [-2**62,-1,0,2**62-1]:cases.append(('fromInteger',[value],value&MASK))
            for a,b in [(-2**62,2**62-1),(2**62-1,-2**62),(0,0)]:
                cases.extend((name,[a,b],int(result)) for name,result in [('less',a<b),('greater',a>b),('lessEqual',a<=b),('greaterEqual',a>=b)])
            for a,b in [(MASK,MASK),(MASK,0),(0,0)]:
                cases.extend((name,[a,b],int(a==b)) for name in ('wordEqual','rawEqual','addressEqual'))
                cases.append(('rawDifferent',[a,b],int(a!=b)))
            cases.extend([('wordWidth',[0],64),('addressNull',[0],0),('addressOffset',[0,-1],MASK),('addressOffset',[MASK,1],0),
                          ('runLoop',[0,MASK],MASK),('runLoop',[10000,MASK-9999],0),('runLoop',[100000,7],100007)])
            for i,(name,values,expected) in enumerate(cases):
                image=out/f'case-{i}.elf'
                receipt=gate.build(source,name,values,4096,4096,image,True)
                assert receipt['execution']['result_bits']==expected,(name,values,expected,receipt['execution'])
                record['cases'].append(dict(entry=name,arguments=values,result_bits=expected,heap=receipt['heap'],
                    stack=receipt['linked_stack']['entries'][0],image_sha256=receipt['image']['image_sha256']))
                if name=='runLoop':
                    assert receipt['heap']['requests']==3 and receipt['heap']['required_arena_bytes']==624
                    exact=gate.build(source,name,values,624,receipt['linked_stack']['entries'][0]['peak_bytes'],image,True)
                    assert exact['execution']['result_bits']==expected
                    record['cases'][-1]['exact_arena']=dict(heap=exact['heap'],
                        stack=exact['linked_stack']['entries'][0],image_sha256=exact['image']['image_sha256'])
            record['execution']='RV64-QEMU-PASS'
            print(f'{len(cases)} scalar/loop executions: wraparound, conversions, comparison endpoints, pointer-bit arithmetic and fixed loop arenas PASS',flush=True)
    if args.record:args.record.write_text(json.dumps(record,indent=2)+'\n')


if __name__=='__main__':main()

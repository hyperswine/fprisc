#!/usr/bin/env python3
"""Closed static-arena images: linked placement, exact budgets and execution."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
sys.path.insert(0,str(ROOT/'tests/build-reference'))
import build_static_arena as gate
from check_linked_stack import Image, function, signed

NESTED_LOOP = '''Pair = Type (Pair Word Word).
Outer = Type (Outer Pair Word).
go : Outer -> Word.
go p = case p of Outer inner initial -> case inner of Pair n value ->
 if Word.eq n (Word.fromInt 0) then Word.xor value initial
 else go (Outer (Pair (Word.sub n (Word.fromInt 1)) (Word.add value (Word.fromInt 1))) initial).
runNested : Word -> Word -> Word.
runNested n value = go (Outer (Pair n value) value).
'''


def refuse(action,reason):
    try:action()
    except (ValueError,OSError) as exc:
        assert reason in str(exc),(reason,str(exc))
        return str(exc)
    raise AssertionError('accepted '+reason)


def symbol_change(data,name,value=None,binding=None):
    out=bytearray(data);h=struct.unpack_from('<HHIQQQIHHHHHH',out,16)
    sections=[struct.unpack_from('<IIQQQQIIQQ',out,h[5]+i*h[10]) for i in range(h[11])]
    for s in sections:
        if s[1]!=2:continue
        names=sections[s[6]];strings=out[names[4]:names[4]+names[5]]
        for p in range(s[4],s[4]+s[5],s[9]):
            n,info,_,_,old,_=struct.unpack_from('<IBBHQQ',out,p)
            if n and strings[n:strings.index(0,n)].decode()==name:
                if value is not None:struct.pack_into('<Q',out,p+8,value)
                if binding is not None:out[p+4]=(binding<<4)|(info&15)
                return bytes(out)
    raise AssertionError(name)


def trace(image_path,receipt):
    data=image_path.read_bytes();image=Image(data);proof=receipt['linked_stack']
    returning={f['address'] for f in proof['functions'] if f['may_return']}
    covered={pc for f in proof['functions'] for pc in function(image,f['address'],returning)['pcs']}
    root=image.symbols['fpr_static_run'][0];region=receipt['regions']['stack'];top=region['end']
    log=image_path.with_suffix('.cpu.log')
    cmd=['qemu-system-riscv64','-machine','virt','-smp','1','-m','128M','-nographic','-bios','none',
         '-accel','tcg,one-insn-per-tb=on','-d','cpu,nochain','-dfilter',
         ','.join(f'{start:#x}..{end-1:#x}' for start,end,_ in image.code),'-D',str(log),'-kernel',str(image_path)]
    p=subprocess.run(cmd,capture_output=True,text=True,timeout=180)
    assert p.returncode==0 and 'STATIC_ARENA_PASS result=' in p.stdout,(p.returncode,p.stdout,p.stderr)
    active=False;pc=None;low=top;steps=0;startup_steps=0;digest=hashlib.sha256();registers={};cleared=[]
    bss_start=image.symbols['fpr_static_bss_start'][0];bss_end=image.symbols['fpr_static_bss_end'][0]
    callbacks={image.symbols[symbol][0]:name for name,symbol in receipt.get('callback_work',{}).get('symbols',{}).items()}
    invocations=[]; return_pc=None
    def observe(pc,registers):
        nonlocal active,low,steps,startup_steps,return_pc
        if pc is None:return
        sp=registers[2]
        if pc==return_pc: return_pc=None
        if pc in callbacks and return_pc is None:
            invocations.append(dict(entry=callbacks[pc],instructions=0))
            return_pc=registers[1]
        if return_pc is not None:
            invocations[-1]['instructions']+=1
        if pc==root:
            assert not active and sp==top
            assert cleared==list(range(bss_start,bss_end,8)),'startup did not clear precisely the reserved BSS'
            active=True
        if active:
            assert pc in covered,hex(pc)
            assert region['start']<=sp<=top,(hex(pc),sp,region)
            low=min(low,sp);steps+=1
        else:
            startup_steps+=1;w=image.word(pc);op=w&127
            assert op!=0x03,'unexpected startup load'
            if op==0x23:
                rs1=(w>>15)&31;rs2=(w>>20)&31;kind=(w>>12)&7
                offset=signed(((w>>25)<<5)|((w>>7)&31),12)
                address=registers[rs1]+offset
                assert rs1!=2 and kind==3 and registers[rs2]==0
                assert bss_start<=address<bss_end and address%8==0
                cleared.append(address)
    with log.open('rb') as stream:
        for raw in stream:
            digest.update(raw);line=raw.decode('ascii')
            if m:=re.match(r' pc\s+([0-9a-f]+)',line):
                observe(pc,registers);pc=int(m[1],16);registers={}
            else:
                registers.update((int(n),int(value,16)) for n,value in re.findall(r'x(\d+)/\S+\s+([0-9a-f]+)',line))
    observe(pc,registers)
    assert active and steps>100 and startup_steps>0
    peak=top-low;assert peak<=proof['entries'][0]['peak_bytes']
    result=dict(observed_peak_stack_bytes=peak,instruction_steps=steps,startup_instruction_steps=startup_steps,bss_initialization_bytes=len(cleared)*8,
        trace_scope='all executable sections, independently of the predicted call graph',trace_sha256=digest.hexdigest(),trace_bytes=log.stat().st_size)
    if callbacks:
        assert return_pc is None
        result['callback_trace']=invocations
    log.unlink();return result


EXPECTED_FLAGS = ['-march=rv64imc_zicsr','-mabi=lp64','-mcmodel=medany','-msmall-data-limit=0','-O2',
       '-ffreestanding','-fno-builtin','-fno-stack-protector','-nostdlib','-nostartfiles',
       '-ffunction-sections','-fdata-sections','-DFPR_BUILTIN','-DFPR_BUILTIN_ARC']


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--require-execution',action='store_true');ap.add_argument('--record',type=Path)
    ap.add_argument('--nested-baseline-compiler',type=Path,help='Saved pre-flattening compiler: require refusal of the nested allocating loop')
    args=ap.parse_args()
    record=dict(schema='static-arena-tests-v1',compiler_sha256=gate.sha((ROOT/'fpr').read_bytes()),cases=[],refusals=[])
    with tempfile.TemporaryDirectory(prefix='fpr-static-tests-') as directory:
        out=Path(directory)
        if args.nested_baseline_compiler:
            nested_source=out/'nested-baseline.fpr';nested_source.write_text('profile builtin.\n'+NESTED_LOOP)
            env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
            env.update(FPR_HOME=str(ROOT),XDG_CACHE_HOME=str(out/'baseline-cache'))
            p=subprocess.run([str(args.nested_baseline_compiler),'compile','--profile=bare-metal-builtin','--arc','--lib',
                '--export=runNested','--heap-budget=65536',str(nested_source),str(out/'nested-baseline.s')],
                cwd=ROOT,env=env,capture_output=True,text=True,timeout=180)
            output=p.stdout+p.stderr
            assert p.returncode!=0 and 'UNPROVED' in output and 'allocating-cycle' in output,output
            record['nested_baseline']=dict(compiler_sha256=gate.sha(args.nested_baseline_compiler.read_bytes()),output=output)
            print('Saved compiler: nested loop refuses admission for its allocating cycle PASS',flush=True)
        fake='# export fpr_static_callback -> function (KWord KInt KBool KUnit -> KWord)\n'
        gate.caller(fake,[2**64-1,-2**62,1,0])
        for values,reason in [([1,2,0],'count differs'),([True,0,0,0],'must be integers'),([2**64,0,0,0],'KWord'),([0,2**62,0,0],'KInt'),([0,0,2,0],'KBool'),([0,0,0,1],'KUnit')]:
            refuse(lambda:gate.caller(fake,values),reason)
        refuse(lambda:gate.caller(fake.replace('KWord KInt','KAddr KInt'),[0,0,0,0]),'scalar Word/Int/Bool/Unit')
        refuse(lambda:gate.caller(fake.replace(' -> KWord',' -> KValue'),[0,0,0,0]),'scalar Word/Int/Bool/Unit')
        refuse(lambda:gate.signature('# export fpr_static_callback -> function ('+' '.join(['KWord']*65)+' -> KWord)\n'),'at most 64')
        contract=gate.verify_contract();bad=dict(contract,sources_sha256=dict(contract['sources_sha256']))
        bad['sources_sha256']['machine/builtin/heap.c']='0'*64
        path=out/'bad-contract.json';path.write_text(json.dumps(bad))
        with patch.object(gate,'CONTRACT',path):refuse(gate.verify_contract,'audited runtime/heap contract changed')
        omitted=out/'omitted-contract.json';omitted.write_text(json.dumps(dict(contract,sources_sha256={})))
        with patch.object(gate,'CONTRACT',omitted):refuse(gate.verify_contract,'complete policy/runtime dependencies')
        missing=[t for t in ['riscv64-unknown-elf-gcc','qemu-system-riscv64'] if not shutil.which(t)]
        if missing:
            assert not args.require_execution,missing
            record['execution']=dict(status='SKIP',missing=missing)
        else:
            def build(name,body,entry,values,heap,stack=4096):
                source=out/(name+'.fpr');source.write_text('profile builtin.\n'+body)
                image=out/(name+'.elf')
                result=gate.build(source,entry,values,heap,stack,image,True)
                assert result['image']['image_sha256']==gate.sha(image.read_bytes())
                assert result==json.loads(Path(str(image)+'.admission.json').read_text())
                return source,image,result
            examples=[
                ('identity','identity : Word -> Word.\nidentity x = x.\n','identity',[0xfedcba9876543210],416,0xfedcba9876543210),
                ('wide','wide : '+' -> '.join(['Word']*13)+'.\nwide '+' '.join('x'+str(i) for i in range(12))+' = x11.\n','wide',list(range(11))+[2**64-1],2640,2**64-1),
                ('arity-limit','wide : '+' -> '.join(['Word']*65)+'.\nwide '+' '.join('x'+str(i) for i in range(64))+' = x63.\n','wide',list(range(63))+[2**64-1],13120,2**64-1),
                ('choose-yes','choose : Bool -> Word -> Word -> Word.\nchoose b x y = if b then x else y.\n','choose',[1,7,11],624,7),
                ('choose-no','choose : Bool -> Word -> Word -> Word.\nchoose b x y = if b then x else y.\n','choose',[0,7,11],624,11),
                ('int-low','same : Int -> Int.\nsame x = x.\n','same',[-2**62],0,(-2**62)%(2**64)),
                ('int-high','same : Int -> Int.\nsame x = x.\n','same',[2**62-1],0,2**62-1),
                ('bool','same : Bool -> Bool.\nsame x = x.\n','same',[1],0,1),
                ('unit','same : Unit -> Unit.\nsame x = x.\n','same',[0],0,0),
                ('mixed','pick : Word -> Unit -> Bool -> Int -> Word -> Word.\npick a u b n z = if b then a else z.\n','pick',[7,0,0,-23,2**64-1],624,2**64-1),
                ('nested-zero',NESTED_LOOP,'runNested',[0,2**64-1],624,0),
                ('nested-wrap',NESTED_LOOP,'runNested',[10000,2**64-10000],624,2**64-10000),
                ('nested-long',NESTED_LOOP,'runNested',[100000,7],624,100000),
            ]
            for name,body,entry,values,heap,expected in examples:
                source,image,result=build(name,body,entry,values,heap)
                assert result['execution']['result_bits']==expected,(name,result['execution'])
                exact=result['linked_stack']['entries'][0]['peak_bytes']
                exact_result=gate.build(source,entry,values,heap,exact,image,True)
                assert exact_result['linked_stack']['entries'][0]['peak_bytes']==exact
                observed=trace(image,exact_result) if name in ('identity','wide','choose-yes','choose-no','nested-zero') else None
                previous=image.read_bytes(),Path(str(image)+'.admission.json').read_bytes()
                message=refuse(lambda:gate.build(source,entry,values,heap,exact-16,image),'needs')
                assert previous==(image.read_bytes(),Path(str(image)+'.admission.json').read_bytes())
                record['cases'].append(dict(name=name,receipt=exact_result,trace=observed,short_stack_refusal=message))
                if name=='bool':
                    admitted=gate.build(source,entry,values,heap,exact,image,True,callback_instructions=20)
                    work=admitted['callback_work']
                    assert work['required']==20 and work['per_entry']=={entry:20}
                    single_trace=trace(image,admitted)['callback_trace']
                    assert single_trace==[dict(entry=entry,instructions=20)]
                    previous=image.read_bytes(),Path(str(image)+'.admission.json').read_bytes()
                    short=refuse(lambda:gate.build(source,entry,values,heap,exact,image,callback_instructions=19),'needs 20')
                    assert previous==(image.read_bytes(),Path(str(image)+'.admission.json').read_bytes())
                    record['single_callback_work']=dict(receipt=admitted,trace=single_trace,short_refusal=short)
                if name.startswith('nested-'):
                    assert exact_result['heap']['requests']==3 and exact_result['heap']['required_arena_bytes']==624
                    record['cases'][-1]['short_heap_refusal']=refuse(lambda:gate.build(source,entry,values,608,exact,image),'needs 624')
                    assert previous==(image.read_bytes(),Path(str(image)+'.admission.json').read_bytes())
                print(name+': exact fixed heap/stack, complete reclamation, guards and short-stack refusal PASS',flush=True)
            nested_cases=[c for c in record['cases'] if c['name'].startswith('nested-')]
            assert len({c['receipt']['linked_stack']['entries'][0]['peak_bytes'] for c in nested_cases})==1
            source,image,result=build('preservation',examples[0][1],'identity',examples[0][3],416)
            previous=image.read_bytes(),Path(str(image)+'.admission.json').read_bytes()
            with patch.object(gate,'CONTRACT',path):
                record['refusals'].append(refuse(lambda:gate.build(source,'identity',examples[0][3],416,4096,image),'audited runtime/heap contract changed'))
            assert previous==(image.read_bytes(),Path(str(image)+'.admission.json').read_bytes())
            bad_target=out/'bad-target.json';target=json.loads(gate.TARGET.read_bytes());target['target']='another-target';bad_target.write_text(json.dumps(target))
            with patch.object(gate,'TARGET',bad_target):
                record['refusals'].append(refuse(lambda:gate.build(source,'identity',examples[0][3],416,4096,image),'manifest target differs'))
            assert previous==(image.read_bytes(),Path(str(image)+'.admission.json').read_bytes())
            target['target']=gate.TARGET_ID;target['ram_bytes']*=2;bad_target.write_text(json.dumps(target))
            with patch.object(gate,'TARGET',bad_target):
                record['refusals'].append(refuse(lambda:gate.build(source,'identity',examples[0][3],416,4096,image),'manifest geometry differs'))
            assert previous==(image.read_bytes(),Path(str(image)+'.admission.json').read_bytes())
            with patch.dict(os.environ,{'FPR_HOME':'/missing','FPR_NO_TYPE_SPEC':'1','HEAP':'fpr','CFLAGS':'-DBROKEN','LDFLAGS':'-Wl,--defsym=fpr_alloc=0'}):
                clean=gate.build(source,'identity',examples[0][3],416,4096,image,True)
            assert clean['flags']==EXPECTED_FLAGS and clean['execution']['result_bits']==examples[0][5]
            previous=image.read_bytes(),Path(str(image)+'.admission.json').read_bytes()
            for kwargs,reason in [({'heap_bytes':400},'needs 416'),({'stack_bytes':16},'needs'),({'arguments':[2**64]},'KWord')]:
                options=dict(source=source,entry='identity',arguments=examples[0][3],heap_bytes=416,stack_bytes=4096,image_path=image)
                options.update(kwargs);record['refusals'].append(refuse(lambda:gate.build(**options),reason))
                assert previous==(image.read_bytes(),Path(str(image)+'.admission.json').read_bytes())
            for name,body,entry,values,reason in [
                ('foreign','speak : Int -> Unit.\nspeak x = print x.\n','speak',[3],'UNPROVED'),
                ('overflow','plus : Int -> Int.\nplus x = x + 1.\n','plus',[2**62-1],'UNPROVED'),
                ('float','same : F64 -> F64.\nsame x = x.\n','same',[0],'scalar Word/Int/Bool/Unit'),
                ('interrupt','enable : Word -> Word.\nenable x = _ = CPU.irqEnable Unit; x.\n','enable',[3],'UNPROVED'),
                ('csr','enable : Word -> Word.\nenable x = _ = CPU.csrWrite 768 x; x.\n','enable',[8],'UNPROVED'),
                ('arity-over','wide : '+' -> '.join(['Word']*66)+'.\nwide '+' '.join('x'+str(i) for i in range(65))+' = x64.\n','wide',list(range(65)),'TYPE ERRORS'),
            ]:
                bad_source=out/(name+'.fpr');bad_source.write_text('profile builtin.\n'+body)
                record['refusals'].append(refuse(lambda:gate.build(bad_source,entry,values,4096,4096,image),reason))
                assert previous==(image.read_bytes(),Path(str(image)+'.admission.json').read_bytes())
            # Corrupt final linked symbol/section facts independently of source
            # declarations; placement must not accept labels as sufficient proof.
            data=image.read_bytes();syms=Image(data).symbols
            overlap=data;guard=syms['fpr_static_heap_guard'][0]
            for label,value in [('guard',guard),('start',guard+16),('end',guard+16+4096)]:
                overlap=symbol_change(overlap,'fpr_static_stack_'+label,value)
            record['refusals'].append(refuse(lambda:gate.placement(overlap,416,4096),'heap and stack arenas overlap'))
            for label,value,binding,reason in [
                ('fpr_static_heap_start',syms['fpr_static_heap_start'][0]+8,None,'geometry'),
                ('fpr_static_heap_end',syms['fpr_static_heap_end'][0]+16,None,'geometry'),
                ('fpr_static_stack_guard',syms['fpr_static_heap_start'][0],None,'geometry'),
                ('fpr_static_bss_end',syms['fpr_static_heap_end'][0],None,'overlaps static'),
                ('fpr_static_heap_start',None,2,'weak arena symbol'),
            ]:
                broken=symbol_change(data,label,value,binding)
                record['refusals'].append(refuse(lambda:gate.placement(broken,416,4096),reason))
            # A runtime guard corruption is an execution refusal, not a receipt.
            with patch.object(gate,'CALLER',gate.CALLER.replace(' INVOCATION',' fpr_static_heap_guard[0]=0; INVOCATION')):
                record['refusals'].append(refuse(lambda:gate.build(source,'identity',examples[0][3],416,4096,image,True),'STATIC_ARENA_FAIL'))
            assert previous==(image.read_bytes(),Path(str(image)+'.admission.json').read_bytes())
            record['execution']='RV64-QEMU-PASS'
            print('Runtime identity, signature domains, metadata corruption, failed execution and publication preservation PASS',flush=True)
    if args.record:args.record.write_text(json.dumps(record,indent=2)+'\n')


if __name__=='__main__':main()

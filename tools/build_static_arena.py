#!/usr/bin/env python3
"""Build and admit one bounded builtin activation or a finite sequence on fixed RV64 arenas.

Authority is fresh compiler analysis plus a closed, audited runtime/link recipe,
not a caller-supplied heap sidecar or the names of functions in an arbitrary ELF.
The receipt is conditional on the compiler/C toolchain, ordinary valid-memory
semantics and the stated machine boot contract; it is not a WCET proof.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile

from check_target_image import admit, require
from check_linked_stack import Image, prove
from linked_callback_work import callback_work
from static_arena_runtime import START, LINK, CALLER, HEAP_SETUP, CHECKPOINT
import static_arena_sequence as sequence_policy

ROOT=Path(__file__).resolve().parents[1]
CONTRACT=ROOT/'machine/builtin/contracts/rv64-c-heap-v1.json'
TARGET=ROOT/'machine/builtin/targets/virt.json'
TARGET_ID='builtin-rv64-virt-128m'
LINK_TOOL=ROOT/'tools/static-arena-link.sol'
PUBLIC='fpr_static_callback'
KINDS={'KWord':'uintptr_t','KInt':'intptr_t','KBool':'int','KUnit':'uintptr_t'}


def sha(data):return hashlib.sha256(data).hexdigest()


def arena_tool(tool, *args, env=None):
    proc = subprocess.run([os.environ.get('SOL') or 'sol', tool, ROOT, *args],
                          cwd=ROOT, env=env, text=True, capture_output=True, timeout=250)
    require(proc.returncode == 0, proc.stderr.strip() or 'controlled link failed')
    return json.loads(proc.stdout)


def verify_contract():
    return arena_tool(ROOT/'tools/static-arena-contract.sol', CONTRACT)


def signature(assembly,public=PUBLIC):
    matches=re.findall(r'^# export '+re.escape(public)+r' -> \S+ \((.*?) -> (\w+)\)$',assembly,re.M)
    require(len(matches)==1,'missing/ambiguous checked callback signature')
    params,result=matches[0];params=params.split()
    require(len(params)<=64,'static activation supports at most 64 parameters')
    require(all(k in KINDS for k in params+[result]),'static activation requires scalar Word/Int/Bool/Unit boundaries')
    return params,result


def literal(kind,value):
    require(type(value) is int,'activation arguments must be integers')
    low,high={'KWord':(0,2**64-1),'KInt':(-2**62,2**62-1),'KBool':(0,1),'KUnit':(0,0)}[kind]
    require(low<=value<=high,'activation argument outside '+kind+' domain')
    return f'({KINDS[kind]})UINT64_C({value & (2**64-1)})'


def caller(assembly,arguments,heap_bytes=112):
    params,result=signature(assembly)
    require(len(params)==len(arguments),'argument count differs from the checked callback signature')
    values=[literal(kind,value) for kind,value in zip(params,arguments)]
    result_c='void' if result=='KUnit' else KINDS[result]
    declaration=f'extern {result_c} {PUBLIC}('+(','.join(KINDS[k] for k in params) or 'void')+');'
    invocation=PUBLIC+'('+','.join(values)+');'
    invocation=(invocation+'fpr_static_result=0;' if result=='KUnit' else 'fpr_static_result=(uw)'+invocation)
    body=CALLER.replace('DECLARATION',declaration).replace('INVOCATION',invocation).replace('HEAP_SETUP',HEAP_SETUP if heap_bytes else '')
    return body,dict(parameters=params,result=result,arguments=arguments)


def placement(data,heap_bytes,stack_bytes):
    image=Image(data)
    def symbol(name):
        require(name in image.symbols and image.symbols[name][1]==1,'missing/weak arena symbol: '+name)
        return image.symbols[name][0]
    regions={}
    for kind,size in [('heap',heap_bytes),('stack',stack_bytes)]:
        start,end,guard=[symbol('fpr_static_'+kind+'_'+s) for s in ('start','end','guard')]
        require(start%16==0 and end-start==size and guard+16==start,'linked arena geometry differs from reserved '+kind)
        regions[kind]=dict(start=start,end=end,bytes=size,lower_guard_start=guard,upper_guard_end=end+16)
    require(regions['heap']['upper_guard_end']<=regions['stack']['lower_guard_start'],'heap and stack arenas overlap')
    # Include every allocated section, not just the highest load address.
    h=struct.unpack_from('<HHIQQQIHHHHHH',data,16)
    sections=[struct.unpack_from('<IIQQQQIIQQ',data,h[5]+i*h[10]) for i in range(h[11])]
    spans=sorted((s[3],s[3]+s[5]) for s in sections if s[2]&2 and s[5])
    require(all(a[1]<=b[0] for a,b in zip(spans,spans[1:])),'allocated sections overlap')
    for kind,region in regions.items():
        covering=[s for s in sections if (s[3],s[3]+s[5])==(region['lower_guard_start'],region['upper_guard_end'])]
        require(len(covering)==1 and covering[0][1]==8 and covering[0][2]&7==3,
                'arena is not an exact writable non-executable NOBITS section: '+kind)
    require(symbol('fpr_static_bss_end')<=regions['heap']['lower_guard_start'],'heap overlaps static state')
    require(h[3]==symbol('_start'),'ELF entry differs from the controlled startup')
    return regions


def build(source,entry,arguments,heap_bytes,stack_bytes,image_path,execute=False,*,sequence=None,callback_instructions=None):
    if sequence is None:
        require(isinstance(entry,str) and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.]*',entry) is not None,'invalid source entry name')
        symbols={entry:PUBLIC}
    else:
        require(entry is None and arguments==[],'choose a sequence or a single entry')
        sequence_policy.parse_sequence(sequence)
        sequence=json.loads(json.dumps(sequence))
        steps=sequence['steps']
        names=dict.fromkeys(step['entry'] for step in steps)
        symbols={name:f'fpr_static_callback_{i}' for i,name in enumerate(names)}
    require(type(heap_bytes) is int and (heap_bytes==0 or 112<=heap_bytes<2**64 and heap_bytes%16==0),'heap bytes must be zero or a 16-byte multiple of at least 112')
    require(type(stack_bytes) is int and 0<stack_bytes<2**64 and stack_bytes%16==0,'stack bytes must be a positive 16-byte multiple')
    if callback_instructions is not None:
        require(type(callback_instructions) is int and 0<callback_instructions<2**64,'invalid callback instruction budget')
    contract=verify_contract()
    image_path=image_path.resolve();source=source.resolve()
    require(source not in (image_path,Path(str(image_path)+'.admission.json')),'output would replace source')
    require(image_path.parent.is_dir(),'output directory does not exist')
    require(not image_path.exists() or image_path.is_file(),'output image is not a file')
    source_hash=sha(source.read_bytes())
    compiler_hash=sha((ROOT/'fpr').read_bytes())
    manifest=TARGET.read_bytes();target=TARGET_ID;selected=json.loads(manifest)
    require(isinstance(selected,dict) and selected.get('target')==target,'manifest target differs from the controlled build target')
    require(tuple(selected.get(k) for k in ('elf_class_bits','ram_origin','ram_bytes'))==(64,0x80000000,128*1024*1024),
            'manifest geometry differs from the controlled startup')
    env={k:v for k,v in os.environ.items() if not k.startswith(('FPR_','CFLAGS','CPPFLAGS','LDFLAGS','GCC_EXEC_PREFIX','COMPILER_PATH','LIBRARY_PATH','CPATH','C_INCLUDE_PATH'))}
    # GCC includes, libraries, assembler and linker must come from the selected
    # toolchain, not inherited injected search paths/flags.
    with tempfile.TemporaryDirectory(prefix='.fpr-static-',dir=image_path.parent) as directory:
        out=Path(directory)
        env.update(FPR_HOME=str(ROOT),XDG_CACHE_HOME=str(out/'cache'))
        commands=[]
        asm=out/'callback.s'
        commands.append(arena_tool(LINK_TOOL, out, 'compile', source, str(max(1,heap_bytes)),
                                   *(name+':'+symbol for name,symbol in symbols.items()), env=env))
        text=asm.read_text()
        by_symbol = arena_tool(ROOT/'tools/static-arena-heap-proof.sol', asm, str(heap_bytes),
                               *symbols.values(), env=env)
        proofs = {name: by_symbol[symbol] for name, symbol in symbols.items()}
        if sequence is None:
            body,sig=caller(text,arguments,heap_bytes)
            heap=dict(**proofs[entry],reserved_bytes=heap_bytes)
        else:
            signatures={name:signature(text,symbol) for name,symbol in symbols.items()}
            decl,calls=sequence_policy.invocation(steps,symbols,signatures,KINDS,literal,HEAP_SETUP if heap_bytes else '',CHECKPOINT)
            body=CALLER.replace('DECLARATION',decl).replace('INVOCATION',calls).replace('HEAP_SETUP',HEAP_SETUP if heap_bytes else '')
            sig={name:dict(parameters=params,result=result,export=symbols[name]) for name,(params,result) in signatures.items()}
            heap=dict(required_arena_bytes=max(p['required_arena_bytes'] for p in proofs.values()),reserved_bytes=heap_bytes,
                      requests=sum(proofs[s['entry']]['requests'] for s in steps),
                      requested_bytes=sum(proofs[s['entry']]['requested_bytes'] for s in steps),per_entry=proofs)
        for name,content in [('start.S',START),('caller.c',body),('link.ld',LINK.replace('HEAP_BYTES',str(heap_bytes)).replace('STACK_BYTES',str(stack_bytes)))]:
            (out/name).write_text(content)
        linked = arena_tool(LINK_TOOL, out, 'single' if sequence is None else 'sequence', env=env)
        commands.extend(linked['commands'])
        elf = out / 'image.elf'
        require(verify_contract()==contract,'runtime contract changed during admission')
        require(sha(source.read_bytes())==source_hash,'root source changed during admission')
        require(sha((ROOT/'fpr').read_bytes())==compiler_hash,'compiler changed during admission')
        data=elf.read_bytes();physical=admit(data,manifest,target)
        regions=placement(data,heap_bytes,stack_bytes)
        stack=prove(data,manifest,target,[('fpr_static_run',stack_bytes)])
        result=dict(schema='static-builtin-activation-v1',image=physical,signature=sig,
            heap=heap,
            regions=regions,linked_stack=stack,compiler_sha256=compiler_hash,
            runtime_contract=contract,recipe_sha256=sha(Path(__file__).read_bytes()),
            runtime_recipe_sha256=sha((ROOT/'tools/static_arena_runtime.py').read_bytes()),
            root_source_sha256=source_hash,assembly_sha256=sha(asm.read_bytes()),
            linked_inputs_sha256=linked['inputs'],flags=linked['flags'],build_commands=commands,toolchain=linked['toolchain'],
            link_recipe_sha256=sha(LINK_TOOL.read_bytes()),
            scope='One fresh, exclusive, non-reentrant RV64 builtin activation from the controlled boot path; no WCET claim.',
            assumptions=['Trusted compiler and C/assembler/linker toolchain; valid-memory program semantics.',
                         'QEMU virt machine address map, machine-mode reset, hart 0; other harts park without memory accesses.',
                         'No executable-code mutation or asynchronous NMI/debugger/DMA memory mutation; ordinary interrupts remain disabled.',
                         'This receipt applies only to the exact image hash; it does not authenticate arbitrary replacement ELF files.'])
        if sequence is not None:
            result.update(schema='static-builtin-sequence-admission-v1',sequence=sequence,
                          sequence_sha256=sha(json.dumps(sequence,sort_keys=True,separators=(',',':')).encode()),dispatch='fixed read-only schedule with direct entry calls',
                          sequence_policy_sha256=sha((ROOT/'tools/static_arena_sequence.py').read_bytes()),
                          scope='Finite exclusive RV64 builtin activations from controlled startup, with typed scalar hand-offs and reclamation checks before every arena reset.')
        if callback_instructions is not None:
            calls=[entry] if sequence is None else [step['entry'] for step in steps]
            result['callback_work']=callback_work(data,symbols,calls,callback_instructions)
            result['callback_work']['analysis_sha256']={name:sha((ROOT/'tools'/name).read_bytes())
                for name in ('linked_callback_work.py','check_linked_stack.py','riscv_compressed.py')}
        if execute:
            execution = arena_tool(LINK_TOOL, out, 'execute', env=env)
            commands.append(execution['command'])
            output = execution['output']
            values=re.findall(r'^STATIC_ARENA_PASS result=(\d+)$',output,re.M)
            require(len(values)==1,'execution did not return the guarded activation result')
            result['execution']=dict(status='RV64-QEMU-PASS',result_bits=int(values[0]),output=output)
        require(elf.read_bytes()==data,'linked image changed during admission')
        receipt=out/'receipt.json';receipt.write_text(json.dumps(result,indent=2)+'\n')
        # All refusal paths precede publication, preserving an existing image
        # and receipt. Each final replacement is atomic on this filesystem.
        os.replace(receipt,Path(str(image_path)+'.admission.json'))
        os.replace(elf,image_path)
        return result


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('source',type=Path)
    selection=ap.add_mutually_exclusive_group(required=True)
    selection.add_argument('--entry');selection.add_argument('--sequence',type=Path,help='finite typed application sequence JSON')
    ap.add_argument('--arguments',help='JSON integer values for each checked Word/Int/Bool/Unit parameter')
    ap.add_argument('--heap-bytes',type=int,required=True);ap.add_argument('--stack-bytes',type=int,required=True)
    ap.add_argument('--callback-instructions',type=int,help='maximum total linked instructions across callbacks, excluding dispatch')
    ap.add_argument('--image',type=Path,required=True);ap.add_argument('--execute',action='store_true')
    args=ap.parse_args()
    try:
        require(args.sequence is None or args.arguments is None,'--arguments belongs to a single entry')
        if args.sequence is not None:
            require(args.sequence.resolve() not in (args.image.resolve(),Path(str(args.image.resolve())+'.admission.json')),'output would replace sequence')
            spec=json.loads(args.sequence.read_text())
            sequence_policy.parse_sequence(spec)
        else:spec=None
        arguments=json.loads(args.arguments) if args.arguments is not None else [];require(isinstance(arguments,list),'arguments must be a JSON list')
        result=build(args.source,args.entry,arguments,args.heap_bytes,args.stack_bytes,args.image,args.execute,sequence=spec,callback_instructions=args.callback_instructions)
    except (OSError,ValueError,struct.error,subprocess.TimeoutExpired) as exc:
        ap.exit(1,'static arena refused: '+str(exc)+'\n')
    label='static sequence' if args.sequence else 'static activation'
    summary=(label+' admitted: heap '+str(result['heap']['required_arena_bytes'])+'/'+str(args.heap_bytes)+
             ', linked startup/caller/runtime stack '+str(result['linked_stack']['entries'][0]['peak_bytes'])+'/'+str(args.stack_bytes))
    if 'callback_work' in result:
        work=result['callback_work']
        summary+=f", callback instructions {work['required']}/{work['limit']}"
    print(summary)


if __name__=='__main__':main()

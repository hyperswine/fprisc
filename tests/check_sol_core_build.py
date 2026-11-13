#!/usr/bin/env python3
"""Independent parity and refusal checks for the Python-free core builders."""
import json
import os
from pathlib import Path
import runpy
import re
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT/'tools'), str(ROOT/'tests/build-reference')]
import build_static_arena as reference
ENV = dict(os.environ, FPR_HOME=str(ROOT), XDG_STATE_HOME='/tmp/fpr-core-state',
           SOL_CACHE_DIR='/tmp/fpr-core-cache', XDG_CACHE_HOME='/tmp/fpr-core-xdg')
SOL = os.environ.get('SOL', 'sol')
def invoke(args, ok=True):
    p = subprocess.run([SOL, *map(str,args)], cwd=ROOT, env=ENV,
                       text=True, capture_output=True, timeout=300)
    assert (p.returncode == 0) == ok, p.stdout+p.stderr
    return p

def plans(tmp):
    actual_run = subprocess.run
    for focus in ['', 'imported-carrier', 'carrier', 'fields', 'storage', 'variant', 'transport']:
        out = tmp/(focus or 'full')
        captured = []
        def intercept(argv, **kwargs):
            if len(argv)>1 and str(argv[1]).endswith('pi-qualification-build.sol'):
                captured.append(json.loads(Path(argv[2]).read_text()))
                return subprocess.CompletedProcess(argv,0)
            return actual_run(argv,**kwargs)
        args=['reference','--root',str(ROOT),'--output',str(out),'--runner-source',str(ROOT/'tools/pi-hart-registers.c')]
        if focus: args += ['--'+focus+'-only']
        with patch.object(sys,'argv',args), patch.dict(os.environ,ENV), patch('subprocess.run',intercept):
            runpy.run_path(str(ROOT/'tests/build-reference/build_pi_runtime_qualification.py'),run_name='__main__')
        output=tmp/((focus or 'full')+'.json')
        args=['tools/build-pi-runtime-qualification.sol','--root',ROOT,'--output',out,
              '--runner-source',ROOT/'tools/pi-hart-registers.c','--plan-output',output]
        if focus:args+=['--'+focus+'-only']
        invoke(args)
        new=json.loads(output.read_text());old=captured[0]
        for field in ['builds','scheduler','cases','metadata','compiler','mode','root','out']:
            assert new[field]==old[field], (focus,field)
        print('Pi plan parity:',focus or 'full',len(new['builds']),flush=True)

def arena(tmp):
    src=tmp/'bool.fpr';src.write_text('profile builtin.\nsame : Bool -> Bool.\nsame x = x.\n')
    image=tmp/'new.elf';old=tmp/'old.elf'
    with patch.dict(os.environ,ENV):
        expected=reference.build(src,'same',[1],0,1024,old,True,callback_instructions=20)
    args=['tools/build-static-arena.sol',src,'--entry','same','--arguments','[1]',
          '--heap-bytes','0','--stack-bytes','1024','--image',image,'--callback-instructions','20','--execute']
    invoke(args)
    actual=json.loads(Path(str(image)+'.admission.json').read_text())
    # GCC records random temporary object names in the ELF string table.
    normalize=lambda b: re.sub(rb'cc[A-Za-z0-9]{6}\.o\x00',b'ccXXXXXX.o\x00',b)
    assert normalize(image.read_bytes())==normalize(old.read_bytes()), 'linked bytes differ beyond temporary object names'
    assert {k:v for k,v in actual['image'].items() if k!='image_sha256'} == {k:v for k,v in expected['image'].items() if k!='image_sha256'}
    for key in ['signature','heap','regions','execution']:
        assert actual[key]==expected[key],key
    assert actual['linked_stack']['entries']==expected['linked_stack']['entries']
    for a,b in zip(actual['linked_stack']['functions'],expected['linked_stack']['functions']):
        a['calls'].sort(key=lambda x:(x['address'],x['retained_bytes']))
        assert a==b,(a,b)
    assert actual['callback_work']=={k:v for k,v in expected['callback_work'].items() if k!='analysis_sha256'}
    saved=(image.read_bytes(),Path(str(image)+'.admission.json').read_bytes())
    for flag,value in [('--callback-instructions','19'),('--stack-bytes','112'),('--arguments','[2]')]:
        bad=args.copy();bad[bad.index(flag)+1]=value
        invoke(bad,False)
        assert saved==(image.read_bytes(),Path(str(image)+'.admission.json').read_bytes())
    # Typed previous-result hand-offs exercise the dispatcher and its stack.
    sequence=tmp/'sequence.json'
    sequence.write_text(json.dumps({'schema':'static-builtin-sequence-v1','steps':[
        {'entry':'same','arguments':[1]},{'entry':'same','arguments':[{'previous':True}]}]}))
    with patch.dict(os.environ,ENV):
        ref=reference.build(src,None,[],0,1024,old,True,sequence=json.loads(sequence.read_text()),callback_instructions=40)
    seq=['tools/build-static-arena.sol',src,'--sequence',sequence,'--heap-bytes','0','--stack-bytes','1024',
         '--image',image,'--callback-instructions','40','--execute']
    invoke(seq)
    got=json.loads(Path(str(image)+'.admission.json').read_text())
    assert got['execution']==ref['execution'] and got['callback_work']=={k:v for k,v in ref['callback_work'].items() if k!='analysis_sha256'}
    assert got['linked_stack']['entries'][0]['peak_bytes']==ref['linked_stack']['entries'][0]['peak_bytes']
    print('Static images: normalized ELF parity, stack/work parity, refusal preservation and sequence execution PASS',flush=True)

def decoder(tmp):
    from riscv_compressed import expand
    rows=[]
    for half in range(65536):
        try: rows.append([half,expand(half)])
        except ValueError: pass
    data=tmp/'decoder.json';data.write_text(json.dumps(rows))
    check=tmp/'decoder.sol'
    check.write_text('R = use "'+str(ROOT/'tools/riscv-compressed')+'".\n'
        'J = use "'+str(ROOT/'sol/lib/json')+'".\n'
        '> rows = unwrap (J.parse (readPath "'+str(data)+'") |>? J.items);\n'
        '  _ = List.map (fn row -> case row of J.JArr [J.JNum h,J.JNum expected] -> '
        'if R.expand h == expected then Unit else error "decoder mismatch {h}" | _ -> error "bad row") rows;\n'
        '  print "decoder parity".\n')
    invoke([check])
    print('Decoder: all',len(rows),'supported encodings match PASS',flush=True)

def linked_oracle(tmp):
    from types import SimpleNamespace
    fixture=SimpleNamespace(**runpy.run_path(str(ROOT/"tests/check_linked_stack.py")))
    from linked_callback_work import callback_work
    from check_linked_stack import prove
    manifest=tmp/'linked-target.json';manifest.write_bytes(fixture.MANIFEST)
    helper=tmp/'callback.sol'
    helper.write_text('R = use "'+str(ROOT/'tools/linked-rv64')+'".\n'
        'F = use "'+str(ROOT/'tools/toolchain-files')+'".\n'
        'J = use "'+str(ROOT/'sol/lib/json')+'".\n'
        'main : unsafe Unit -> Unit .\n'
        '> case args Unit of [image,name,limit] -> img = R.image (F.readBytes image); '
        'print (J.render (R.callbackReport img [(name,name)] [name] (Str.parse limit))) | _ -> error "args".\n')
    accepted=[('leaf',48),('root',80),('tail',80),('loop',0),('frame',4096),('panic_path',16),('mutual_a',0),('same_depth',16)]
    rejected=['cycle','may_return','dynamic','indirect','unbalanced','up','misaligned','join','clobber','unresolved_join','weak_entry','missing']
    work_rejected=['loop','cycle','mutual_a','may_return','panic_path','lost_link','partial_link','clobbered_saved','escaped_write','indirect','weak_entry','dynamic']
    for compressed in [False,True]:
        for relax in [False,True]:
            name=f'linked-{compressed}-{relax}';asm=tmp/(name+'.s');image=tmp/(name+'.elf')
            asm.write_text(fixture.ASM.replace('.option norvc','.option rvc') if compressed else fixture.ASM)
            command=['riscv64-unknown-elf-gcc','-ffixed-x27','-march=rv64imc' if compressed else '-march=rv64im','-mabi=lp64','-nostdlib']
            if not relax:command+=['-mno-relax','-Wl,--no-relax']
            subprocess.run(command+['-T',str(ROOT/'tests/typed_ir/kernel_link.ld'),str(asm),'-o',str(image)],check=True)
            for entry,need in accepted:
                report=tmp/(name+'-'+entry+'.json')
                invoke(['tools/linked-stack.sol','--image',image,'--manifest',manifest,'--target',fixture.TARGET['target'],
                        '--stack-entries',entry+':'+str(max(need,1)),'--report',report])
                actual=json.loads(report.read_text())
                assert actual['schema']==3 and actual['linked_stack']['entries'][0]['peak_bytes']==need
            for entry in rejected:
                invoke(['tools/linked-stack.sol','--image',image,'--manifest',manifest,'--target',fixture.TARGET['target'],'--stack-entries',entry+':65536'],False)
            for entry in ['root','leaf','tail','twice']:
                with patch.dict(os.environ,ENV):expected=callback_work(image.read_bytes(),{entry:entry},[entry],100)
                actual=json.loads(invoke([helper,image,entry,'100']).stdout)
                assert actual==expected,(name,entry,actual,expected)
            for entry in work_rejected:invoke([helper,image,entry,'100000'],False)
            print('Linked proof parity and adversarial refusals:',name,'PASS',flush=True)

def forwarding(tmp):
    sdk=tmp/'sdk';(sdk/'compiler').mkdir(parents=True);(sdk/'tools').mkdir()
    compiler=sdk/'compiler/fpr';shutil.copy2(ROOT/'fpr',compiler)
    c=tmp/'forward.c';c.write_text('#include <stdio.h>\nint main(int argc,char **argv){for(int i=1;i<argc;i++) puts(argv[i]);return 19;}\n')
    native=sdk/'tools/qos'
    subprocess.run(['cc',str(c),'-o',str(native)],check=True)
    (sdk/'sdk.json').write_text('{}')
    project=tmp/'project with spaces';project.mkdir()
    env=dict(ENV)
    def launch(extra=None,expected=19):
        p=subprocess.run([str(compiler),'build','--target=qos-portable',str(project),'-v'],
            env=dict(env,**(extra or {})),capture_output=True,text=True,timeout=30)
        assert p.returncode==expected,(p.returncode,p.stdout,p.stderr)
        return p
    p=launch();assert p.stdout.splitlines()==['build','--compiler',str(compiler.resolve()),str(project),'-v'],p.stdout
    launch({'QOS_PORTABLE_BUILDER':str(native)})
    sol=tmp/'override.sol';sol.write_text('> Script.abort 21.\n')
    launch({'QOS_PORTABLE_BUILDER':str(sol)},21)
    native.unlink();(sdk/'tools/portable_sdk.py').write_text('raise Exception("legacy fallback must not run")')
    launch(expected=2)
    print('Compiler SDK forwarding: native, explicit executable, Sol override, spaces and missing builder PASS',flush=True)

if __name__=='__main__':
    with tempfile.TemporaryDirectory(prefix='fpr-core-build-') as td:
        tmp=Path(td).resolve();plans(tmp);decoder(tmp);arena(tmp);linked_oracle(tmp);forwarding(tmp)

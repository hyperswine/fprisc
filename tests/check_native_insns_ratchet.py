#!/usr/bin/env python3
"""Native-bound consumer: coverage refusal controls plus real typed emission."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('native_ratchet',ROOT/'tools/native-insns-ratchet.py')
gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)

def emitted(name='main',arch='rv64',seg=10,tail=5,calls=1):
    return ('# typed IR: no translation\n'+f'# fn {name} (arity 0) typed-ir {arch} frame=16\n'+
            gate.symbol(name)+':\n    ret\n'+f'# native-insns-v1: {name} segmax={seg} exittail={tail} ccalls={calls}\n')

def main():
    with tempfile.TemporaryDirectory(prefix='fpr-native-ratchet-') as d:
        tmp=Path(d);root=tmp/'root.s';unit=tmp/'unit with spaces.s'
        manifest=Path(str(root)+'.units')
        def reset():
            root.write_text(emitted());unit.write_text(emitted('other',seg=33,tail=20,calls=7));manifest.write_text(unit.name+'\n')
        def refused(change):
            reset();change()
            try:gate.audit(root,'rv64')
            except (gate.Refused,OSError):return
            raise AssertionError('invalid coverage accepted')
        reset();r=gate.audit(root,'rv64')
        assert r['functions']==2 and r['segmax']==33 and r['exittail_max']==20
        assert r['runtime_call_sites_total']==8 and r['runtime_call_sites_max_per_function']==7
        assert r['elapsed_time_certificate'] is False and r['runtime_time_bound']=='unprovided'
        assert r['call_return_composition']=='unprovided'
        cases=[
            lambda:manifest.unlink(),
            lambda:unit.unlink(),
            lambda:manifest.write_text(unit.name+'\n'+unit.name+'\n'),
            lambda:manifest.write_text(root.name+'\n'),
            lambda:manifest.write_text('\n'),
            lambda:unit.write_text(emitted().replace('segmax=10','segmax=UNBOUNDED')),
            lambda:unit.write_text(emitted().replace('exittail=5','exittail=UNBOUNDED')),
            lambda:unit.write_text(emitted().replace('ccalls=1','ccalls=-1')),
            lambda:unit.write_text(emitted().replace('segmax=10','segmax=+10')),
            lambda:unit.write_text(emitted(tail=11)),
            lambda:unit.write_text(emitted().replace('# native-insns-v1: main segmax=10 exittail=5 ccalls=1\n','')),
            lambda:unit.write_text(emitted()+'# native-insns-v1: main segmax=10 exittail=5 ccalls=1\n'),
            lambda:unit.write_text(emitted().replace('native-insns-v1','native-insns-v2')),
            lambda:unit.write_text(emitted().replace('typed-ir rv64','typed-ir a64')),
            lambda:unit.write_text(emitted().replace('# typed IR: no translation\n','')),
            lambda:unit.write_text(emitted().replace('# native-insns-v1: main','# native-insns-v1: wrong')),
            lambda:unit.write_text(emitted().replace('# fn main (arity 0) typed-ir rv64 frame=16\n','')),
            lambda:unit.write_text(emitted().replace('fpr_fn_main:\n','')),
            lambda:unit.write_text(emitted()+'fpr_fn_extra:\n    ret\n'),
            lambda:unit.write_text(emitted()+'fpr_ufn_legacy:\n    ret\n'),
            lambda:unit.write_text(emitted()+'# wcet: old segmax=1 exittail=1 ccalls=0\n'),
            lambda:unit.write_text(emitted()+'# unboxed clone (legacy)\n'),
            lambda:root.write_text('# typed IR: no translation\n'),
            lambda:unit.write_text(emitted()+emitted().split('\n',1)[1]),
        ]
        for case in cases:refused(case)
        reset();unit.write_text('# typed IR: no translation\n    .section .rodata\n')
        assert gate.audit(root,'rv64')['functions']==1,'a data-only unit has no instruction obligation'
        for target,arch in gate.ARCH.items():
            reset();root.write_text(emitted(arch=arch));unit.write_text(emitted('other',arch=arch))
            assert gate.audit(root,target)['functions']==2
        reset();root.write_text(emitted('$vkernel:fpr_vspec_map_x'))
        assert gate.audit(root,'rv64')['functions']==2
        reset();root.write_text(emitted('λ.foo').replace(gate.symbol('λ.foo')+':','_'+gate.symbol('λ.foo')+':'))
        assert gate.audit(root,'rv64')['functions']==2
        print(f'Native consumer: closure/space paths, all target aliases, symbols, metadata and {len(cases)} refusal controls PASS',flush=True)
        reset();result=tmp/'result.json'
        cmd=[sys.executable,ROOT/'tools/native-insns-ratchet.py',root,'33','rv64','--assembly',
             '--runtime-call-sites-ceiling','7','--json-output',result]
        def run(args,expected,env=None):
            p=subprocess.run([str(x) for x in args],cwd=ROOT,env=env,capture_output=True,text=True,timeout=600)
            assert p.returncode==expected,(p.returncode,p.stdout,p.stderr)
            return p.stdout+p.stderr
        run(cmd,0);assert json.loads(result.read_text())['result']=='PASS'
        low=list(cmd);low[3]='32';run(low,1);assert json.loads(result.read_text())['result']=='FAIL'
        low=list(cmd);low[low.index('7')]='6';run(low,1)
        unit.unlink();run(cmd,1);assert json.loads(result.read_text())['result']=='FAIL'
        print('CLI: independent instruction/call-site ceilings and stale success replacement PASS',flush=True)
        # Compile a genuine root plus the linked prelude closure. An inherited
        # rollback request must not turn this native gate into legacy coverage.
        source=tmp/'real.fpr';source.write_text('step n = n + 1.\nmain = step 8.\n')
        env={k:v for k,v in os.environ.items() if not k.startswith('FPR_')}
        env.update(FPR_HOME=str(ROOT),FPR_PATH=str(ROOT),FPR_TYPED_IR_BACKEND='legacy',XDG_CACHE_HOME=os.environ.get('XDG_CACHE_HOME', str(tmp/'cache')))
        real=[sys.executable,ROOT/'tools/native-insns-ratchet.py',source,'100000','rv64',
              '--runtime-call-sites-ceiling','100000','--json-output',result]
        run(real,0,env);data=json.loads(result.read_text())
        assert data['result']=='PASS' and data['functions']>100 and len(data['files'])>1
        assert all(f['functions']>0 for f in data['files'])
        print(f"Real strict typed compilation: {data['functions']} functions, {len(data['files'])} files PASS",flush=True)

if __name__=='__main__':main()

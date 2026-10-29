#!/usr/bin/env python3
"""Exact-output differential and allocation checks for CSS construction."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(args, env):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                       capture_output=True, timeout=240)
    assert p.returncode == 0, (args, p.returncode, p.stdout[-4000:], p.stderr[-4000:])
    return p.stdout

with tempfile.TemporaryDirectory(prefix='fpr-view-construction-') as directory:
    out = Path(directory)
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
               FPR_COST_PROBE='1', XDG_CACHE_HOME=os.environ.get('XDG_CACHE_HOME', str(out/'cache')))
    env.pop('FPR_FOREIGN', None)
    source = (ROOT/'tests/base/viewconstruction.fpr').read_text()
    baseline_source = out/'baseline.fpr'
    baseline = source.replace('G = use "std/view".',
        f'G = use "std/view".\nR = use "{ROOT}/tests/base/viewconstruction_reference".')
    for name in ('hasPrefix', 'atomClasses', 'localCss', 'localStage', 'localRule',
                 'cssFor', 'cssWith', 'renderStyled', 'render'):
        # Include the opening space/parenthesis boundary: render must not
        # accidentally rewrite renderStyled for a second time.
        baseline = baseline.replace('G.'+name+' ', 'R.'+name+' ')
    baseline_source.write_text(baseline)
    binaries = {}
    for name, src in [('baseline', baseline_source), ('candidate', ROOT/'tests/base/viewconstruction.fpr')]:
        exe = out/name
        run([ROOT/'fpr', 'build', src, '--harts', '4', '--with',
             ROOT/'tests/bench/costprobe.c', '-o', exe], env)
        binaries[name] = exe
    for harts in ('1', '4'):
        local = dict(env, FPR_HARTS=harts)
        before = run([binaries['baseline']], local)
        after = run([binaries['candidate']], local)
        assert b'view construction: complete\n' in before
        assert before == after, ('CSS/render bytes changed', hashlib.sha256(before).hexdigest(), hashlib.sha256(after).hexdigest())
        print(f'View construction: byte-identical CSS, classes, render frames and cached fragments ({harts} workers) PASS; bytes={len(after)} sha256={hashlib.sha256(after).hexdigest()}', flush=True)
    for mode in ('prefix-cost', 'stage-cost', 'class-cost', 'tree-cost'):
        ledgers = {}
        outputs = {}
        for name, exe in binaries.items():
            lines = run([exe, mode], dict(env, FPR_HARTS='1')).splitlines()
            outputs[name] = lines[:-1]
            ledgers[name] = json.loads(lines[-1])
        assert outputs['baseline'] == outputs['candidate'], outputs
        before, after = ledgers['baseline'], ledgers['candidate']
        if mode == 'prefix-cost':
            assert after['alloc_requests'] == 0, after
        elif mode in ('stage-cost', 'class-cost'):
            # A budget, not a requirement that the old reference stay slow:
            # a later compiler may optimize both implementations equally.
            assert after['alloc_bytes'] <= 500000, ledgers
        else:
            assert after['alloc_requests'] <= 35000, ledgers
            assert after['alloc_bytes'] <= 2000000, ledgers
        print(f'{mode}: '+json.dumps(ledgers, sort_keys=True), flush=True)

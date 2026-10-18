#!/usr/bin/env python3
"""Linear string builders (docs/2026-10-18-LINEAR-STRING-BUILDERS.md): exact outputs
of View.esc/splitSp/media/rules/render and of the Stream Reader across fill
boundaries, and allocation budgets for a 1 MiB text, a 1 MiB message and the
stylesheet loops.  tests/base/linearstrings.expected was recorded with the
strcat-per-piece library and must not change."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(args, env):
    p = subprocess.run(list(map(str, args)), cwd=ROOT, env=env,
                       capture_output=True, text=True, timeout=240)
    assert p.returncode == 0, (args, p.returncode, p.stdout[-4000:], p.stderr[-4000:])
    return p.stdout

# budgets, not requirements: each is about twice the cost observed on 2026-10-19
BUDGETS = {
    'esc-cost 16384': 12_000_000,     # a 1 MiB text with an escape every 64 bytes, and 1 MiB without
    'txt-cost 16384': 14_000_000,     # the same text rendered as a Txt node
    'split-cost': 1_600_000,          # 8192 words
    'media-cost': 8_000_000,          # 2048 breakpoint rules and 2048 plain rules
    'render-cost': 13_000_000,        # renderStyled: 2000 elements, a <style> block, 31 slots
    'stream-cost': 6_500_000,         # readUntil of a 1 MiB line in 64 KiB fills
    'exact-cost': 6_500_000,          # readExactly of the same 1 MiB
}

with tempfile.TemporaryDirectory(prefix='fpr-linear-strings-') as directory:
    out = Path(directory)
    env = dict(os.environ, FPR_HOME=str(ROOT), FPR_PATH=str(ROOT),
               FPR_COST_PROBE='1', XDG_CACHE_HOME=str(out/'cache'))
    env.pop('FPR_FOREIGN', None)
    exe = out/'linearstrings'
    run([ROOT/'fpr', 'build', 'tests/base/linearstrings.fpr', '--harts', '4', '--with',
         ROOT/'tests/bench/costprobe.c', '-o', exe], env)
    want = (ROOT/'tests/base/linearstrings.expected').read_text()
    for harts in ('1', '4'):
        data = out/f'data{harts}'; data.mkdir()
        got = run([exe, data], dict(env, FPR_HARTS=harts))
        assert got == want, f'linearstrings output differs from linearstrings.expected ({harts} workers)\n{got[-3000:]}'
        print(f'Linear strings: esc, splitSp, media, rules, render frames and the Reader across fills match the strcat-era output ({harts} workers) PASS', flush=True)
    for mode, budget in BUDGETS.items():
        args = mode.split()
        if mode.endswith('-cost') and args[0] in ('stream-cost', 'exact-cost'):
            args.append(str(out))
        lines = run([exe, *args], dict(env, FPR_HARTS='1')).splitlines()
        ledger = json.loads(lines[-1])
        assert ledger['alloc_bytes'] <= budget, (mode, ledger, budget)
        print(f'{mode}: {lines[0]} {json.dumps(ledger, sort_keys=True)} (budget {budget:,} bytes) PASS', flush=True)

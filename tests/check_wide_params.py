#!/usr/bin/env python3
"""Params 7 and 8 under register promotion, on every backend.

Register promotion (Codegen registerSlots) can keep a function's 7th/8th
parameter in a saved register, so the RV64 prologue reads it with
`mv sN, a6` / `mv sN, a7` instead of `sd a6, slot`.  X64.hs used to lower
only the `sd` form and stopped with "X64: a6 -- arity <= 6", which is what
kept most QOS Portable apps from building on x86-64.

Checks, for tests/base/wideparams.fpr:
  * the promotion really happens (the RV64 emission has the `mv` shapes);
  * rv64, a64 and x64 emission succeed with promotion on and off;
  * the x64 prologue reads the TLS cells into a saved register;
  * the program built for this host prints the reference values with
    promotion on and off.
"""
import os, platform, re, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
ENV = {**os.environ, 'FPR_HOME': str(ROOT), 'LC_ALL': 'C.UTF-8'}
for k in ('FPR_PATH', 'FPR_FOREIGN', 'FPRISC_ROOT'): ENV.pop(k, None)
FIXTURE = 'tests/base/wideparams.fpr'

def mix7(a, b, c, d, e, f, g):
    s, t = len(str(g)), len(str(g) * 2)
    return a + b + c + d + e + f + g * g + g * s + g * t + (g + g) * (g + s) + g * 3 + g

def mix8(a, b, c, d, e, f, g, h):
    s, t = len(str(h) + str(g)), len(str(h))
    return a + b + c + d + e + f + h * h + h * g + h * s + g * t + (h + g) * (h + s) + h * 5 + g * g + h + g

EXPECT = f'wide: {mix7(1, 2, 3, 4, 5, 6, 7)} {mix8(1, 2, 3, 4, 5, 6, 7, 8)} {mix7(-1, 0, 0, 0, 0, 0, 123456)}'

def run(args, env):
    p = subprocess.run([str(a) for a in args], cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
    assert p.returncode == 0, f'{args}: exit {p.returncode}\n{p.stdout}{p.stderr}'
    return p.stdout

with tempfile.TemporaryDirectory(prefix='fpr-wide-') as d:
    tmp = Path(d)
    for no_regs in ('0', '1'):
        env = {**ENV, 'FPR_NO_REGISTERS': no_regs}
        asm = {}
        for target in ('rv64', 'a64', 'x64'):
            out = tmp / f'{target}{no_regs}.s'
            run(['./fpr', f'--target={target}', f'--prelude={ROOT}/core/prelude.fpr', FIXTURE, out], env)
            asm[target] = out.read_text()
        promoted = {r: bool(re.search(rf'^\s*mv s\d+, {r}$', asm['rv64'], re.M)) for r in ('a6', 'a7')}
        if no_regs == '0':
            assert promoted == {'a6': True, 'a7': True}, ('promotion did not reach params 7/8; the check is vacuous', promoted)
            for cell in ('fpr_x64_a6', 'fpr_x64_a7'):
                assert re.search(rf'movq %fs:{cell}@tpoff, %(?:rbx|r12|r13|r14|r15)\b', asm['x64']), cell
        else:
            assert promoted == {'a6': False, 'a7': False}, promoted
        exe = tmp / f'wide{no_regs}'
        run(['./fpr', 'build', FIXTURE, '-o', exe], env)
        got = run([exe], env).strip()
        assert got == EXPECT, (no_regs, got, EXPECT)
    print(f'wide params: 7th/8th params promoted to saved registers lower on rv64/a64/x64 and run on {platform.machine()} ({EXPECT}): PASS')

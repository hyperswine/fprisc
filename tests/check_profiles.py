#!/usr/bin/env python3
"""Two axes (docs/2026-09-19-PROFILES.md): the PROFILE a file declares -- `profile
builtin|base|extbase|sol.`, or `unsafe base.` for the blanket-unsafe form
-- and the SYSTEM the compiler is asked for (--system=bare-metal |
qos-native | qos-portable | posix), and posix's HOST (--host=unix |
esp-idf).  The matrix is enforced, the flag may not contradict the file,
the 1.x --profile= and --system=esp-idf spellings still mean what they
meant, and `fpr run` sends a sol program to the VM."""
from pathlib import Path
import os, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
subprocess.run(['make', 'fpr'], check=True, capture_output=True, timeout=300)
P = ROOT / 'tests' / 'profiles'
# the compiler writes <out dir>/units beside its output, so /dev/null is not an output path
TMP = tempfile.TemporaryDirectory(prefix='fpr-profiles-')
OUT = str(Path(TMP.name) / 'out.s')
def compile_(flags, src, expected):
    p = subprocess.run(['./fprc', *flags, str(src), OUT], capture_output=True, text=True, timeout=120)
    assert p.returncode == expected, f'{flags} {src.name}: exit {p.returncode}, expected {expected}\n{p.stdout}\n{p.stderr}'
    return p.stdout + p.stderr
# the matrix
compile_(['--system=bare-metal'], P / 'builtin_decl.fpr', 0)
assert 'bare-metal system only' in compile_(['--system=posix'], P / 'builtin_decl.fpr', 1)
assert 'bare-metal system only' in compile_(['--system=qos-portable'], P / 'builtin_decl.fpr', 1)
for system in ('posix', 'bare-metal', 'qos-native', 'qos-portable'):
    compile_([f'--system={system}'], P / 'base_decl.fpr', 0)
    compile_([f'--system={system}'], P / 'extbase_decl.fpr', 0)
compile_(['--system=posix'], P / 'sol_decl.fpr', 0)
assert 'posix system' in compile_(['--system=bare-metal'], P / 'sol_decl.fpr', 1)
print('The matrix: builtin on bare metal only, base/extbase on every system, sol on posix: PASS')
# the file's word is final; the flag serves files that say nothing; `>` is sol's surface
assert 'declares `profile builtin.`' in compile_(['--system=bare-metal', '--profile=base'], P / 'builtin_decl.fpr', 1)
assert "sol profile's surface" in compile_(['--system=posix'], P / 'base_with_eval.fpr', 1)
compile_(['--system=posix', '--profile=sol'], ROOT / 'tests' / 'hello.fpr', 0)
compile_(['--system=bare-metal', '--profile=builtin'], P / 'builtin_decl.fpr', 0)
# the 1.x spellings
compile_(['--profile=bare-metal-builtin'], P / 'builtin_decl.fpr', 0)
compile_(['--profile=bare-metal'], ROOT / 'tests' / 'hello.fpr', 0)
compile_(['--profile=qos-portable'], ROOT / 'tests' / 'hello.fpr', 0)
compile_(['--profile=base'], ROOT / 'tests' / 'base' / 'hello.fpr', 0)
print('The file wins over the flag, `>` needs profile sol, the 1.x --profile spellings still work: PASS')
# fpr run dispatches on the profile; `unsafe base.` is blanket unsafe + base
def run(src, expected=0):
    p = subprocess.run(['./fpr', 'run', str(src)], capture_output=True, text=True, timeout=180)
    assert p.returncode == expected, f'run {src.name}: exit {p.returncode}\n{p.stdout}\n{p.stderr}'
    return p.stdout
assert 'counted 3' in run(P / 'unsafe_base.fpr')
assert 'sol declared' in run(P / 'sol_decl.fpr')
assert 'base declared' in run(P / 'base_decl.fpr')
p = subprocess.run(['./fpr', 'build', str(P / 'sol_decl.fpr'), '-o', '/dev/null'], capture_output=True, text=True)
assert p.returncode != 0 and 'runs on the VM' in p.stderr, p.stderr
print('fpr run: a base program is built and run, a sol program goes to the VM, fpr build refuses sol; `unsafe base.` is blanket unsafe: PASS')
# the posix system's hosts: unix (this machine, the default) and esp-idf (rv32)
compile_(['--system=posix', '--host=unix'], P / 'base_decl.fpr', 0)
compile_(['--system=posix', '--host=esp-idf'], P / 'base_decl.fpr', 0)
compile_(['--host=esp-idf', '--system=posix'], P / 'base_decl.fpr', 0)
compile_(['--host=esp-idf'], P / 'base_decl.fpr', 0)  # a host means posix
compile_(['--system=esp-idf'], P / 'base_decl.fpr', 0)  # the 1.x spelling
compile_(['--system=posix', '--host=esp-idf', '--target=rv32'], P / 'base_decl.fpr', 0)
assert 'hosts are unix' in compile_(['--system=posix', '--host=amiga'], P / 'base_decl.fpr', 1)
assert 'kind of posix host' in compile_(['--system=bare-metal', '--host=esp-idf'], P / 'base_decl.fpr', 1)
assert 'rv32 code for an ESP-IDF' in compile_(['--host=esp-idf', '--target=rv64'], P / 'base_decl.fpr', 1)
assert 'rv32 code for an ESP-IDF' in compile_(['--host=esp-idf', '--rvv'], P / 'base_decl.fpr', 1)
assert 'not on the esp-idf host' in compile_(['--host=esp-idf'], P / 'sol_decl.fpr', 1)
assert 'bare-metal system only' in compile_(['--host=esp-idf'], P / 'builtin_decl.fpr', 1)
print('posix hosts: unix and esp-idf, a host means posix, the 1.x --system=esp-idf spelling, and the refusals: PASS')

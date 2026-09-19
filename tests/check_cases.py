#!/usr/bin/env python3
"""Case coverage (compiler/Exhaust.hs): a `case` must be exhaustive and no
arm with a refutable head may be unreachable.  Together these refuse the
grammar's one ambiguity -- a `case` nested unparenthesized in a non-final
arm takes the arms after it -- whatever the types involved, while every
legitimate shape (nested patterns, a nested case in the final arm, a
parenthesized nested case, an actor loop's trailing `_`) still compiles."""
from pathlib import Path
import os, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
subprocess.run(['make', 'fpr'], check=True, capture_output=True, timeout=300)
CASES = ROOT / 'tests' / 'cases'
# the compiler writes <out dir>/units beside its output, so /dev/null is not an output path
TMP = tempfile.TemporaryDirectory(prefix='fpr-cases-')
OUT = str(Path(TMP.name) / 'out.s')
def compile_(name):
    p = subprocess.run(['./fprc', '--profile=bare-metal-builtin', '--arc', str(CASES / name), OUT],
                       capture_output=True, text=True, timeout=120)
    return p.returncode, p.stdout + p.stderr
def refused(name, *needles):
    code, out = compile_(name)
    assert code != 0, f'{name} should be refused:\n{out}'
    for n in needles:
        assert n in out, f'{name}: expected {n!r} in\n{out}'
def accepted(name):
    code, out = compile_(name)
    assert code == 0, f'{name} should compile:\n{out}'
refused('nested_unparenthesized.fpr', 'case: not exhaustive')
refused('nested_same_type.fpr', 'the arm for False can never match', 'parenthesize it', 'no arm matches False')
refused('bool_one_arm.fpr', 'no arm matches False')
refused('int_without_catchall.fpr', 'add a catch-all arm')
refused('arm_after_catchall.fpr', 'the arm for 1 can never match')
refused('nested_pattern_missing.fpr', 'not matched by any arm')
print('Refused: the nested-case ambiguity in both type shapes, a one-armed Bool, an Int case without a catch-all, an arm after a catch-all, an uncovered nested pattern: PASS')
for ok in ['nested_parenthesized.fpr', 'nested_final_arm.fpr', 'nested_patterns_ok.fpr', 'message_catchall.fpr']:
    accepted(ok)
print('Accepted: a parenthesized nested case, a nested case in the final arm, nested constructor patterns with full coverage, an actor loop\'s trailing `_`: PASS')

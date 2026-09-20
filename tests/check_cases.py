#!/usr/bin/env python3
"""Coverage and signatures -- the three things a definition must not get away
with.

Case coverage (compiler/Exhaust.hs): a `case` must be exhaustive and no arm
with a refutable head may be unreachable.  Together these refuse the grammar's
one ambiguity -- a `case` nested unparenthesized in a non-final arm takes the
arms after it -- whatever the types involved, while every legitimate shape
(nested patterns, a nested case in the final arm, a parenthesized nested case,
an actor loop's trailing `_`) still compiles.

Clause coverage (Exhaust.checkClauses): the same relation over a function's
CLAUSES, one column per parameter.  A value matching none of them used to
reach a runtime "no matching clause" error instead of a compile error; a
guarded clause never counts as covering, because the guard can decline.

Signature generality (Infer.checkDeclared): a declared signature is a promise
about every type the caller may choose, and it is now checked against the
definition rather than believed.  `f : a -> a.` with `f x = x + 1.` is a lie
every caller was previously typed against."""
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

# clause coverage: the witness names the value nothing matches
refused('clauses_missing_con.fpr', 'in pick: the clauses are not exhaustive', 'nothing matches `pick (C _)`')
refused('clauses_missing_int.fpr', 'nothing matches `step 2`')
refused('clauses_guard_only.fpr', 'nothing matches `only _`')
refused('clauses_second_param.fpr', 'nothing matches `both A False`')
accepted('clauses_ok.fpr')
print('Clauses: a missing constructor, Int literals without a catch-all, a lone guarded clause and a hole in the SECOND parameter are refused, each naming the value nothing matches; a catch-all, a guard with a fallback, full coverage and a completed nested pattern compile: PASS')

# a declared signature is checked against the definition, not believed
refused('sig_too_general.fpr', 'the declared type of bad is more general than its definition',
        'the signature promises a -> a', 'only gives Int -> Int')
refused('sig_two_vars.fpr', 'the declared type of swapish is more general')
accepted('sig_ok.fpr')
print('Signatures: `a -> a` over a body that adds 1, and `a -> b` over a body that returns its argument, are refused naming both types; a genuinely generic signature and one NARROWER than the body compile: PASS')

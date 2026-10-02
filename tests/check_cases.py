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
# a signature the grammar cannot read is a parse error at the offending token;
# it used to backtrack to a dropped annotation and the body was inferred alone
refused('sig_malformed.fpr', 'a signature bound is `work f <= ...`')
refused('sig_malformed_arrow.fpr', "unexpected '-'")
# record types are signature grammar, checked like any other type
accepted('sig_record_ok.fpr')
refused('sig_record_missing_field.fpr', 'closed record has no field .b')
refused('sig_record_wrong_type.fpr', 'cannot unify String with Int')
print('Signatures: `a -> a` over a body that adds 1, and `a -> b` over a body that returns its argument, are refused naming both types; a genuinely generic signature and one NARROWER than the body compile; a malformed signature is a parse error, not a dropped one; record types with a shared row variable check, a missing field and a wrong field type are refused: PASS')

# measures: ONE language for the compile and the std proof pass.  The safe/unsafe
# line is enforced by `fpr build` (the builtin profile is the unchecked tier).
def built(name, *needles, ok=True):
    p = subprocess.run(['./fpr', 'build', str(CASES / name), '-o', str(Path(TMP.name) / 'm.out')],
                       capture_output=True, text=True, timeout=300)
    out = p.stdout + p.stderr
    assert (p.returncode == 0) == ok, f'{name}: expected {"accepted" if ok else "refused"}:\n{out}'
    for n in needles:
        assert n in out, f'{name}: expected {n!r} in\n{out}'
built('measure_mutual_ok.fpr')
built('measure_with_pre.fpr')
built('measure_mutual_bad.fpr', 'the measure does not decrease at the call to ping', ok=False)
built('measure_mutual_missing.fpr', 'MUTUAL with pong, which declares no measure', ok=False)
for name in ['measure_mutual_ok.fpr', 'measure_with_pre.fpr']:
    p = subprocess.run(['./fpr', 'stdcheck', str(CASES / name)], capture_output=True, text=True, timeout=120)
    assert p.returncode == 0 and 'verified by the frontend' in p.stdout and 'wcet: (' in p.stdout, f'{name}: {p.stdout}{p.stderr}'
p = subprocess.run(['./fpr', 'stdcheck', str(ROOT / 'tests' / 'measure.fpr')], capture_output=True, text=True, timeout=120)
assert p.returncode == 0 and 'measure -1*i + lim decreases' in p.stdout, p.stdout
print('Measures: a measure verified across a mutual cycle, and `x >= 0 and measure x` keeping its precondition, compile; a non-decreasing mutual call and a cycle member without a measure are refused; stdcheck takes the SAME verified measures (tests/measure.fpr: fact, sumTo with measure lim - i) and prints their call-count bound: PASS')

# operator resolution: an ambiguous site is refused, never decided by name order
refused('op_ambiguous.fpr', '(+) is ambiguous for V2', 'Alpha.+, Zulu.+')
refused('op_ambiguous2.fpr', '(*) is ambiguous for Int and V2', 'Left.*, Right.*')
p = subprocess.run(['./fpr', 'run', str(CASES / 'op_unique.fpr')], capture_output=True, text=True, timeout=300)
assert p.returncode == 0 and p.stdout.strip().endswith('2337'), f'op_unique:\n{p.stdout}{p.stderr}'
print('Operators: two structures implementing V2 + V2, or Int * V2, are refused naming both; one implementation per site resolves (1122 + 1215 = 2337): PASS')

# --stdcheck is a build gate: a proof failure is a non-zero exit
for name, want in [('stdcheck_ok.fpr', 0), ('stdcheck_fail.fpr', 1)]:
    p = subprocess.run(['./fpr', 'stdcheck', str(CASES / name)], capture_output=True, text=True, timeout=120)
    assert p.returncode == want, f'{name}: exit {p.returncode}, wanted {want}:\n{p.stdout}{p.stderr}'
print('stdcheck: a proven Int function exits 0; a signed function outside the fragment prints FAILED and exits 1: PASS')

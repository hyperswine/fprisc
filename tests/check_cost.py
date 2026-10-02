"""Stage 1 of resource bounds (docs/2026-10-02-RESOURCE-BOUNDS.md): every
root function's work/alloc equations, printed by `fpr build --cost`.

  * measured recursion closes to (measure/step + 1) x per-call body, in the
    function's own parameter names, for all three measure kinds
  * a mutual group closes the same way
  * a call through a function-valued parameter is `work f` until the
    caller supplies the argument; then it is a number
  * an unmeasured recursive helper or an undeclared primitive is w(name),
    listed under `opaque`
  * a real program (examples/todo.fpr) reports in seconds, not minutes
"""
from pathlib import Path
import os, re, subprocess, time
ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
subprocess.run(['make', 'fpr'], check=True, capture_output=True, timeout=300)
CASES = ROOT / 'tests' / 'cases'

def cost(src, timeout=120):
    p = subprocess.run(['./fpr', 'build', '--cost', str(src), '-o', '/tmp/fpr-cost-probe'],
                       capture_output=True, text=True, timeout=timeout)
    assert p.returncode == 0, f'{src}: {p.stdout}{p.stderr}'
    out = p.stdout
    i = out.index('cost (work')
    j = out.index('\nunit ', i) if '\nunit ' in out[i:] else len(out)
    if '\ndeclared bounds:' in out:
        k = out.index('\ndeclared bounds:')
        k2 = out.index('\nunit ', k) if '\nunit ' in out[k:] else len(out)
        return out[i:j] + out[k:k2]
    return out[i:j]

def line(report, fn, kind):
    m = re.search(rf'^  {re.escape(fn)}\s+work  <= (.*)$' if kind == 'work' else rf'^  {re.escape(fn)}.*\n\s+alloc <= (.*) bytes$', report, re.M)
    assert m, f'no {kind} line for {fn} in\n{report}'
    return m.group(1).strip()

r = cost(ROOT / 'tests' / 'measure.fpr')
assert line(r, 'fact', 'work') == '5·(n + 1)', line(r, 'fact', 'work')
assert line(r, 'lsum', 'work') == '6·(len l + 1)', line(r, 'lsum', 'work')
assert line(r, 'sumTo', 'work') == '6·((-1)·i + lim + 1)', line(r, 'sumTo', 'work')
assert line(r, 'fact', 'alloc') == '0'
r = cost(CASES / 'measure_mutual_ok.fpr')
assert line(r, 'ping', 'work') == '5·(n + 1)' and line(r, 'pong', 'work') == '5·(n + 1)', r
r = cost(CASES / 'cost_ho.fpr')
assert line(r, 'apply', 'work') == 'work f + 1', line(r, 'apply', 'work')
assert line(r, 'twice', 'work') == '2·work f + 2', line(r, 'twice', 'work')
assert line(r, 'useIt', 'work') == '11', line(r, 'useIt', 'work')
assert line(r, 'mk', 'alloc') == '24', line(r, 'mk', 'alloc')  # one 2-field cell: 8 + 2*8
assert 'opaque: print' in r
# stage 2: declared bounds are checked coefficient by coefficient, callers
# compose on the declaration, and a failed or unprovable bound is a compile error
def build(name, *needles, ok=True):
    p = subprocess.run(['./fpr', 'build', str(CASES / name), '-o', '/tmp/fpr-cost-probe'], capture_output=True, text=True, timeout=300)
    out = p.stdout + p.stderr
    assert (p.returncode == 0) == ok, f'{name}: expected {"accepted" if ok else "refused"}:\n{out}'
    for n in needles:
        assert n in out, f'{name}: expected {n!r} in\n{out}'
build('bound_ok.fpr')
build('bound_caller.fpr')
build('bound_over.fpr', 'OVER (n: derived 5, declared 4)', ok=False)
build('bound_free_name.fpr', 'the bound names `omega`, which is not a parameter of count', ok=False)
build('bound_unproved.fpr', 'UNPROVED (opaque: print)', ok=False)
r = cost(CASES / 'bound_caller.fpr')
assert line(r, 'g', 'work') == '12', line(r, 'g', 'work')  # inc's DECLARED 10, not its derived 1
assert 'inc: declared work <= 10   derived 1   PROVEN' in r, r
r = cost(CASES / 'bound_ok.fpr')
assert 'count: declared work <= 5·n + 5   derived 5·(n + 1)   PROVEN' in r, r
# declared result sizes let a pipeline close: range (b - a + 1) -> map (len xs) -> sum
r = cost(CASES / 'bound_pipeline.fpr')
assert line(r, 'total', 'work') == '19·(len xs + 1) + 8', line(r, 'total', 'work')
assert line(r, 'main', 'work') == 'ω(print) + 292', line(r, 'main', 'work')
assert 'total: declared work <= 19·len xs + 27   derived 19·(len xs + 1) + 8   PROVEN' in r, r

# stage 3: a target manifest prices ops and primitives, binds coefficients,
# and judges budgeted functions; every number is printed beside the target's name
MAN = ROOT / 'tests' / 'manifests'
def judged(name, manifest, *needles, ok=True):
    p = subprocess.run(['./fpr', 'build', str(CASES / name), f'--manifest={MAN / manifest}', '-o', '/tmp/fpr-cost-probe'],
                       capture_output=True, text=True, timeout=300)
    out = p.stdout + p.stderr
    assert (p.returncode == 0) == ok, f'{name} with {manifest}: expected {"accepted" if ok else "refused"}:\n{out}'
    for n in needles:
        assert n in out, f'{name} with {manifest}: expected {n!r} in\n{out}'
judged('bound_pipeline.fpr', 'host.fprt', 'target host-test:', '1.3 ns/op', 'main      work 2292 ops → 2.98 µs   PROVEN within budget 5 µs',
       'total     work <= 19·(len xs + 1) + 8   (parametric; × 1.3 ns)')
judged('bound_pipeline.fpr', 'host-tight.fprt', 'main      work 2292 ops → 2.98 µs   OVER budget 1 µs', ok=False)
build('bound_coef.fpr', 'a named coefficient needs a target manifest', ok=False)
judged('bound_coef.fpr', 'host.fprt', 'count: declared work <= 5·n + 5   derived 5·(n + 1)   PROVEN')
judged('bound_coef.fpr', 'host-omega4.fprt', 'OVER (n: derived 5, declared 4)', ok=False)
bad = Path('/tmp/fpr-bad-manifest.fprt'); bad.write_text('name x\nns_per_op fast\n')
p = subprocess.run(['./fpr', 'build', str(CASES / 'bound_ok.fpr'), f'--manifest={bad}', '-o', '/tmp/fpr-cost-probe'], capture_output=True, text=True, timeout=300)
assert p.returncode != 0 and 'not a number: fast' in p.stdout + p.stderr, p.stdout + p.stderr

# stage 4: live is alloc under the pool model, credited back inside an arena;
# a persistent loop reports one step's cost
r = cost(CASES / 'live_bounds.fpr')
assert 'build: declared live <= 24·n + 24   derived 24·(n + 1)   PROVEN' in r, r
assert re.search(r'^  scratch\s+work  <= .*\n\s+alloc <= ω\(\?len\) \+ 48 bytes\n\s+live  <= ω\(\?len\) \+ 24·\(ω\(\?\) \+ 1\) \+ 64 bytes', r, re.M), r
r = cost(ROOT / 'tests' / 'base' / 'loopwith.fpr')
assert re.search(r'^  run\s+work  <= .*ω\(loop:Sys\.loopWith\)', r, re.M), r
assert 'per step (Sys.loopWith): work <= ω(diffc) + ω(draw) + ω(junk) + ω(lenL) + 27, alloc <= ω(diffc) + ω(draw) + ω(junk) + ω(lenL) + 96 bytes' in r, r

t0 = time.time()
r = cost(ROOT / 'examples' / 'todo.fpr', timeout=120)
dt = time.time() - t0
assert dt < 60, f'todo cost report took {dt:.0f}s'
assert re.search(r'^  update\s+work  <= max\(', r, re.M), r
# std/list's loops carry measures: view's per-item cost is (len items + 1) x the row
assert re.search(r'^  view\s+work  <= .*\(len m\.#2 \+ 1\)·\(', r, re.M), r
# the program's own unmeasured helper, and the length of a rendered string, stay opaque and are named
assert 'dropLastChar  work  <= ω(dropGo) + 3' in r, r
assert 'ω(?len)' in r and 'ω(str)' in r, r
print(f'Cost: measured, structural and mutual recursion close to (measure/step + 1)·body; `work f` is a variable until the argument is supplied; an unmeasured helper is ω(name) under `opaque`; a declared bound is PROVEN, OVER naming the coefficient, or UNPROVED naming the ω, callers compose on the declaration; a manifest prices ops and print, binds omega, and judges main against its budget (PROVEN 2.98 µs ≤ 5 µs, OVER against 1 µs); live is alloc, credited inside an arena, and a loopWith reports one step; todo.fpr reports in {dt:.1f}s: PASS')

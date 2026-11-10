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
assert line(r, 'fact', 'work') == '5·(max(0, n) + 1)', line(r, 'fact', 'work')
assert line(r, 'lsum', 'work') == '6·(len l + 1)', line(r, 'lsum', 'work')
assert line(r, 'sumTo', 'work') == '6·(max(0, (-1)·i + lim) + 1)', line(r, 'sumTo', 'work')
assert line(r, 'fact', 'alloc') == '0'
r = cost(CASES / 'measure_mutual_ok.fpr')
assert line(r, 'ping', 'work') == '5·(max(0, n) + 1)' and line(r, 'pong', 'work') == '5·(max(0, n) + 1)', r
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
build('bound_signed_unsafe.fpr', 'UNPROVED', 'signed input domain', ok=False)
build('bound_caller.fpr')
build('bound_over.fpr', 'OVER (max(0, n): derived 5, declared 4)', ok=False)
build('bound_unused_over.fpr', 'OVER (max(0, n): derived 5, declared 4)', ok=False)
build('bound_free_name.fpr', 'the bound names `omega`, which is not a parameter of count', ok=False)
build('bound_unproved.fpr', 'UNPROVED (opaque: print)', ok=False)
r = cost(CASES / 'bound_caller.fpr')
assert line(r, 'g', 'work') == '12', line(r, 'g', 'work')  # inc's DECLARED 10, not its derived 1
assert 'inc: declared work <= 10   derived 1   PROVEN' in r, r
r = cost(CASES / 'bound_ok.fpr')
assert 'count: declared work <= 5·max(0, n) + 5   derived 5·(max(0, n) + 1)   PROVEN' in r, r
# The original std-map proof priced its growing reverse accumulator at the
# initial length. The exit-path recurrence charges mapGo's final reverse
# once, at the accumulator's grown length: the derived bound is linear and
# proves 23·len xs + 27, while the historical 19·len xs + 27 is refused as
# OVER. A direct measured map keeps the independent composition, callback,
# declared-size and manifest checks below meaningful.
r = cost(CASES / 'bound_pipeline.fpr')
assert 'total: declared work <= 23·len xs + 27   derived 9·len xs + 14·(len xs + 1) + 13   PROVEN' in r, r
old_bound = Path('/tmp/fpr-cost-bound-pipeline-19.fpr')
old_bound.write_text((CASES / 'bound_pipeline.fpr').read_text().replace('23 * len xs + 27', '19 * len xs + 27'))
p = subprocess.run(['./fpr', 'build', str(old_bound), '-o', '/tmp/fpr-cost-probe'], capture_output=True, text=True, timeout=300)
assert p.returncode != 0 and 'OVER (len xs: derived 23, declared 19)' in p.stdout + p.stderr, p.stdout + p.stderr
r = cost(CASES / 'bound_pipeline_direct.fpr')
assert line(r, 'total', 'work') == '16·(len xs + 1) + 6', line(r, 'total', 'work')
assert line(r, 'main', 'work') == 'ω(print) + 257', line(r, 'main', 'work')
assert 'total: declared work <= 16·len xs + 22   derived 16·(len xs + 1) + 6   PROVEN' in r, r

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
judged('bound_pipeline_direct.fpr', 'host.fprt', 'target host-test:', '1.3 ns/op', 'main       work 2257 ops → 2.93 µs   PROVEN within budget 5 µs',
       'total      work <= 16·(len xs + 1) + 6   (parametric; × 1.3 ns)')
judged('bound_pipeline_direct.fpr', 'host-tight.fprt', 'main       work 2257 ops → 2.93 µs   OVER budget 1 µs', ok=False)
build('bound_coef.fpr', 'a named coefficient needs a target manifest', ok=False)
judged('bound_coef.fpr', 'host.fprt', 'count: declared work <= 5·max(0, n) + 5   derived 5·(max(0, n) + 1)   PROVEN')
judged('bound_coef.fpr', 'host-omega4.fprt', 'OVER (max(0, n): derived 5, declared 4)', ok=False)
bad = Path('/tmp/fpr-bad-manifest.fprt'); bad.write_text('name x\nns_per_op fast\n')
p = subprocess.run(['./fpr', 'build', str(CASES / 'bound_ok.fpr'), f'--manifest={bad}', '-o', '/tmp/fpr-cost-probe'], capture_output=True, text=True, timeout=300)
assert p.returncode != 0 and 'not a number: fast' in p.stdout + p.stderr, p.stdout + p.stderr

# stage 4: live is alloc under the pool model, credited back inside an arena;
# a persistent loop reports one step's cost
r = cost(CASES / 'live_bounds.fpr')
assert 'build: declared live <= 24·max(0, n) + 24   derived 24·(max(0, n) + 1)   PROVEN' in r, r
# The lifted two-argument closure reserves 32 + 2*8 = 48 requested bytes,
# rather than the old 24-byte estimate for one supplied capture.
assert re.search(r'^  scratch\s+work  <= .*\n\s+alloc <= ω\(\?len\) \+ 72 bytes\n\s+live  <= ω\(\?len\) \+ 24·\(max\(0, ω\(\?\)\) \+ 1\) \+ 88 bytes', r, re.M), r
r = cost(ROOT / 'tests' / 'base' / 'loopwith.fpr')
assert re.search(r'^  run\s+work  <= .*ω\(loop:Sys\.loopWith\)', r, re.M), r
# lenL walks a list and allocates nothing: unmeasured recursion whose bodies
# allocate nothing per call allocates nothing (docs/2026-10-25-REGIONS-LOOPS-CALLS.md)
assert 'per scoped step: work <= ω(diffc) + ω(draw) + ω(junk) + ω(lenL) + 27, alloc <= ω(diffc) + ω(draw) + ω(junk) + 96 bytes' in r, r
r = cost(ROOT / 'tests' / 'base' / 'loopstate.fpr')
assert re.search(r'^  run\s+work  <= .*ω\(loop:Sys\.loop\)', r, re.M), r
assert 'per scoped step: work <=' in r, r

t0 = time.time()
r = cost(ROOT / 'examples' / 'todo.fpr', timeout=120)
dt = time.time() - t0
assert dt < 60, f'todo cost report took {dt:.0f}s'
assert re.search(r'^  updateWith\s+work  <= max\(', r, re.M), r
# The per-item depth remains visible (the items list's length is opaque
# here, ω(?len)), and std-map/indexedMap's reverse accumulators are priced
# once at their grown length instead of as varying terms.
assert re.search(r'^  view\s+work  <= .*ω\(\?len\)·\(', r, re.M), r
assert 'varying-recursive-parameter:' not in line(r, 'view', 'work'), r
# Todo's UTF-8 helper now declares measure k; preserve that recurrence rather
# than the older opaque-helper expectation. Rendered string lengths stay opaque.
assert line(r, 'dropGo', 'work') == '(max(0, k) + 1)·(len s + 15)', r
assert line(r, 'dropLastChar', 'work') == '(max(0, ω(?)) + 1)·(len s + 15) + 2', r
assert 'ω(?len)' in r and 'ω(str)' in r, r
print(f'Cost: linear measured recursion and invariant callbacks compose; branching/growing recursive costs stay unproved; full PAP capacity is charged; declared bounds and manifest judgements (fixture: 2.93 µs within 5 µs, over 1 µs), scoped live/loop costs and Todo reporting ({dt:.1f}s) PASS')

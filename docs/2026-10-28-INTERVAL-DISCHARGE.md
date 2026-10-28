# Difference-bound discharge

2026-10-28, codegen rev 137. Plan step 4.4
(`docs/2026-10-26-PERFORMANCE-PLAN.md`), first landing.

`Codegen.Interval` is a Simplify pass (`discharge-proven-checks`, on by
default; `FPR_NO_INTERVAL=1`, `-nointerval` in the option identity) that
derives difference-bound facts `x - y <= c` from dominating comparisons
and removes the checks they prove dead:

- an edge fact is taken from a `condbr` on an `OCmp` to a target that
  has no other predecessor — every path into the target's dominator
  subtree crossed the edge;
- every `TInt` value carries the domain bounds of its width
  (`intBounds`: 63-bit on W64, 31-bit on W32);
- `i < n` therefore proves `i + 1` cannot overflow
  (`i <= n - 1 <= maxInt - 1`): `OArith` becomes `OArithU`, and the fit
  check and its slow path leave the loop. Only Add/Sub against a
  constant are discharged; Mul keeps its wide path, Div keeps its zero
  check, and nothing about an accumulator add is claimed;
- a `condbr` whose comparison a dominating fact already decides is
  threaded to its taken arm and the orphaned blocks swept — this is what
  removes a read fragment's guard when an enclosing range test covers
  it, and what folds constant comparisons;
- a pure operation repeated across blocks is one value: `untag v` in the
  guard block and `untag v` in the body are resolved to a single
  representative before facts are consulted (share-pure-in-block stops
  at the block edge; full cross-block sharing is plan step 4.3).

`OArithU` selects a plain `add`/`sub` on A64 and x64 and — where the
checked form still calls the C primitive — on RV32/RV64 too. The
evaluator computes it without the fit trap, so the TypedIR-style
differential (lowered vs. simplified, same results, traps and texts)
holds by construction and is exercised by the new suite.

## Proof discipline and its boundaries

Every removal is a derived bound in the domain, not a pattern; the pass
result re-verifies like every Simplify pass. The tests pin the boundary
both ways (`tests/Interval.hs`, `tests/check_interval.py`):

- `count (maxInt - 1) maxInt 0` runs one iteration and returns
  `maxInt - 1`: the discharged `i + 1` reaches `maxInt` exactly and does
  not trap;
- `over (maxInt - 1) maxInt 0` — the `i <= n` loop, whose counter *can*
  reach `maxInt` with the exit false — keeps its check and traps with
  the exact runtime `Int overflow` text, natively and in the evaluator;
- accumulator adds, and indices not related to a length by a dominating
  guard, keep their checks.

What the domain cannot yet see, and where that belongs:

- the initial values of a recursive function's parameters
  (`sumB s 0 (strlen s) 0`: `0 <= i` and `n == strlen s` are the
  *caller's* facts) — that is interprocedural, the source-level
  precondition checker the plan points at (`compiler/Precond.hs`), and
  this domain is its engine;
- induction over loop-carried parameters (guess-and-verify ranges for a
  header parameter whose back edge is `p + k`): within one function the
  initial values above are exactly what it needs, so it lands with or
  after the precondition work, not before;
- byteloop's `charAt` guards stay for this reason: inside `sumB`,
  nothing relates `i` to the string's length.

## Measurement

`bench/2026-10-28-interval-discharge.json`: byteloop 1.14x from the
discharge alone (both arms with the inline string reads), 1.23x combined
with them (`base 107 ms -> strfast 97 ms -> +interval 87 ms`, medians
under load 5-14); `sumB` goes from segmax 73/4 ccalls to 64/3. sha is
unchanged within noise (0.988) — its rounds are vector and kernel work,
not guarded scalar counters.

# One measure language

Date: 2026-10-02. Kind: implementation record. Stage 0 of
[2026-10-02-RESOURCE-BOUNDS.md](2026-10-02-RESOURCE-BOUNDS.md).

## Before

Two termination checkers held two readings of the same declaration.
`Safety.hs` verified `(x : T | measure e)` with structural descent or a linear
decrease with a floor from guards, self-recursion only. `StdCheck.hs` ignored
the declaration and looked for a parameter written literally as `p - k` at every
self-call with a finite lower-bound precondition. `tests/measure.fpr`
compiled and failed `fpr stdcheck` on both `fact` and `sumTo`.

## After

`Safety.measureCheck :: [STop] -> (Map Name Measure, [String])` is the only
verifier. A `Measure` carries the function, its canonical parameter names, the
kind (`MStructural param` or `MLinear coefficients constant`), the step every
call lowers it by, and the recursive group it was verified with. `safetyCheck`
uses it for the safe/unsafe line; `StdBridge` passes it to `StdCheck` as
`fMeasure`, and `StdCheck`'s own `findMeasure` is deleted. The cost closed form
is `(measure/step + 1) * per-call body`, with the measure as a linear cost term
over the parameters.

Three extensions came with the unification:

- **Mutual recursion.** A cycle is verified as a group when every member
  declares a measure: at each call from f to g in the cycle, g's measure on the
  call's arguments must be below f's measure on its parameters, with the floor
  on f's side. The group's step is the minimum over its calls. A member without
  a measure, or a call that does not descend, names the callee in the error.
  `StdCheck` accepts the group and multiplies the call count by the maximum
  per-call body over the members (a partner's own parameters are opaque, as
  Fold's callee's are).
- **A precondition and a measure in one slot.** `(x : Int | x >= 0 and measure x)`
  is split by `Precond.splitMeasure`: the measure goes to Safety, the rest stays
  a value contract, and the signature's value preconditions are now facts for
  the floor check. `std/checkdemo.fpr`'s `fact_acc` uses this; its base case
  tests `x == 0`, which alone gives no floor.
- **Safety runs before precondition insertion** in the native pipeline, as it
  already did in Sol. The inserted guards wrap call arguments, and the measure
  has to read the user's arguments to see the descent.

The shared call graph (`callGraphOf`) is one function used by both checks.

## Tests

`tests/check_cases.py`: `measure_mutual_ok.fpr` and `measure_with_pre.fpr`
build; `measure_mutual_bad.fpr` (a call that hands the same measure back) and
`measure_mutual_missing.fpr` (a cycle member without a measure) are refused
naming the call; `fpr stdcheck` on both accepted cases and on
`tests/measure.fpr` prints the frontend-verified bound (`measure -1*i + lim`
for `sumTo`). All native suites, Sol scripts, examples and `qos.py test`
(13/13) pass.

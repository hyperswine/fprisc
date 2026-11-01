# List fusion: trap safety fixes

Date: 2026-11-02. These fix the defects a review of the zero-overhead work
found in [checked List fusion](2026-11-01-LIST-FUSION.md) and
[case of known constructor](2026-11-01-CASE-KNOWN.md). Each was reproduced
with the passes on and off (`FPR_NO_LIST_FUSE=1 FPR_NO_CASE_KNOWN=1`).

## What was wrong

- **A let-bound producer could lose its trap.** The float moved a single-use
  `map`/`filter`/`range` binding to its use when that use sat in an `if` arm,
  a `case` arm or after `and`. For example,
  `ys = List.map (fn x -> 100 / x) (List.range 0 3); if c then List.sum ys else 0`
  printed `0` with `c = False` where the program traps with "division by zero".
  The float happened before any safety check, so a later decline did not
  undo it.
- **Other conditional positions were still entered** after the first
  partial fix (which refused if arms, matches and capture lists). These were
  the body of a refutable pattern binding (`O.Some v = o; v + List.sum ys`
  failed with "let pattern: no match" instead of "division by zero"), the
  right side of `|>?`, and update branches.
- **A use only through a closure capture deleted the binding.** The program
  then failed verification ("out-of-scope capture identity").
- **`length (map f xs)` became `length xs`, even for an `f` that can overflow.**
  The trap disappeared. The Int-overflow relaxation lets fusion move where
  an overflow traps, never drop it, and the old doc text above ("cannot be
  ... elided") did not hold for this rule.
- **`mapRange` calls `f` from the top of the range down.** The overflow
  message then names a different element. This is within the relaxation, but
  no test pinned it.
- **Case of known constructor's single-use check counted deduplicated uses,**
  so it held for any binder that appeared at all.

## What changed

- **The float enters only positions that always run** (`ListFusion.tryFloat`).
  These are `Let` (right side, then body), applications, constructors,
  tuples, lists, records, field reads and updates, `Sequence`, `BoolTest`,
  and code calls whose captures do not hold the binder. Beyond those, three
  nodes are entered on one side only:
  - an `if` condition;
  - the body of a pattern binding whose pattern cannot fail;
  - the scrutinee side of `|>?` and of a planned update.

  Every other node refuses: lambdas, matches, conditional branches,
  refutable bodies, region and vector operations, and anything new. The
  rule is a whitelist, so a node added to typed Core later is refused until
  someone decides otherwise.
- **`FusionSafety` has a strict mode** (`unsafeTargetStrict`,
  `unsafeExpressionStrict`, `FusionPolicy.trapFreePrimitives`). It admits
  comparisons, Boolean operators and float arithmetic other than division,
  and refuses Int `+`, `-` and `*`. Length after map takes the strict
  evidence for its callback and captures. A callback this pass generated
  counts as unsafe there.
- **`mapRange`'s order is kept and pinned.** Making the target ascending would
  need a reverse (or tail-recursion modulo cons, B2), so the descending
  one-pass target stays. Its callbacks are already limited to those whose
  only trap is Int overflow, and a new test pins that the fused program
  reports `3 * ...` where the unfused one reports `2 * ...`.
- **Case of known constructor uses `usedInArms`.** This is the earlier
  uncommitted fix.

## The cost

`List.length (List.map (fn x -> x + 1) (List.range 1 1000))` allocated
nothing before and now allocates 1000 requests (unfused: 3000). Length after
map declines because `x + 1` can overflow, and only map over range fuses. A
callback that cannot trap (`fn x -> x > 500`) still gives 0 requests; the
allocation gate now uses one. Every other allocation gate is unchanged.

## Tests

`tests/check_list_fusion.py` adds, each run with fusion on and off:
- the four conditional cases (if arm, case arm, `and`, refutable pattern)
  plus `|>?`, which must trap identically;
- the capture-only case, which must print `[16, 17]`;
- length after map with an overflowing callback, which must trap in both
  modes;
- the `mapRange` order pin.

`tests/check_list_fusion.py` and `tests/check_case_known.py` pass.

## Not done

- The raw benchmark data behind the 2026-11-01 figures (list_sum 31.3 ms, B5,
  option_loop) is still not committed.
- The random-pipeline differential test with trapping callbacks is still not
  written.
- Case of known constructor still explains no declines through `--remarks`.

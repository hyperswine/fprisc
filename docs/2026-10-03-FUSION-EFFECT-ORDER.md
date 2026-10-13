# Vector fusion keeps effect and failure order

Date: 2026-10-03. Kind: implementation record. Step 0 of
[2026-10-03-VECTOR-AUDIT.md](2026-10-03-VECTOR-AUDIT.md), which found the
defect; supersedes the ownership-only soundness argument in
[2026-08-25-VEC.md](2026-08-25-VEC.md).

## The defect

`fuseVec` rewrote `Vec.map f (Vec.map g v)` to one pass over the composite
`f . g`, arguing that single ownership made the intermediate vector
unobservable. Ownership is not the only channel. Two materializing maps run
`g` over every element before `f` starts; the fused pass interleaves them.
With `first` and `second` printing, the audited checkout printed
`first 1, second 1, first 2, second 2` where the source means
`first 1, first 2, second 1, second 2`. Failure is the same channel: a
panic in the first map on element 2 must come before any work of the
second map on element 1.

## The rule

A pair fuses only when both element functions are **unobservable**:
`fusionSafe` (Codegen.hs) holds when the function and every known callee use
only locals, literals, constructors, tag tests, projections, `if`/`let`,
the fuel tick, and the arithmetic, comparison and logic primitives that
cannot trap. Division is excluded because it traps. Every other primitive,
every call through a parameter, every partial application and every
unknown function value is excluded. The same predicate gates the
write-back fold (`Vec.fold f z (Vec.map g v)`), which interleaves a fold
step and a map step per element.

Non-termination is not an effect here: if `g` loops on element 2, the
original never runs `f` at all and the fused pass runs `f (g 1)` first, but
`f` is unobservable, so no trace differs.

## Nothing is silent

A pair declined for this reason is reported with the construct that made
it observable, once per pair:

```
vec note: Vec.map `second` after Vec.map `first` (in main) is NOT fused:
  `first` uses the primitive `print` -- the two passes run in order, each over the whole vector
```

The note joins the existing generic-tier declines in the compile output
(`fpr build -v`). `codegenRev` is 28.

## Evidence

`tests/base/vecfuse_effects.fpr`: the printing pair produces the source
trace, and a pure `inc`/`double` pair beside it still fuses in place (pool
grew 0 bytes, sum 62). `tests/base/vecfuse_fail.fpr`: a first map that
fails on element 2 panics before any `second` output. Both run in
`tests/check_base.py`. `tests/fuse.fpr`'s seven fusion witnesses still
hold.

Not changed: the width, kernel, layout and SIMD items of the audit (steps
1 to 5), which depend on this rule being in place first.

## 2026-10-12: Int arithmetic can fail

Int `+ - *` trap on overflow now ([2026-10-12-INT-OVERFLOW.md](2026-10-12-INT-OVERFLOW.md)),
so for one day they left the fusion-safe set as `/` did: an Int pair was
declined with `` `idouble` uses the primitive `*` `` and ran in order. That
made every integer pipeline two passes.

## 2026-10-13: the one reordering fusion may make

Decision: a pair fuses when each element function is pure and can fail
only by an Int overflow trap. The fused kernel keeps each element's own
order (g then f on element i, before element i+1), so the only difference
from the two passes is WHICH overflow is reported: the fused kernel may
panic on an earlier element, or in the other function. The program
fail-stops with "Int overflow" either way. `safePrims` in Codegen.hs
admits `+ - *` again; `/` stays out, since a zero divisor is a different
failure and the line is kept narrow. Evidence: `tests/base/vecfuse_effects.fpr`
(an F64 pair and an Int pair both fuse in place; the printing pair does
not), `tests/base/veckinds.fpr` (the captured Int map pair specializes on
`_vfuse_`).

This is a stated exception to the rule above, not a refinement of it, and
a more elegant answer is wanted eventually. Two candidates: a fused kernel
that records the element index and the operation at the trap, so its
panic names what the two passes would have named; or an overflow check
that is itself fused (the lanes' fit checked once per element for the
whole chain), which would make the reordering unobservable rather than
tolerated. Neither is started.

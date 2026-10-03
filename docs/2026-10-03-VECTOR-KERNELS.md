# Vector kernels: captures, wide records, record filters

Date: 2026-10-03. Kind: implementation record. Step 2 of
[2026-10-03-VECTOR-AUDIT.md](2026-10-03-VECTOR-AUDIT.md), the scalar
column kernels; x64 is the part not done (below).

The audit's complaint was a set of cliffs: ordinary callback styles fell
out of the column loops into the generic tier, which rebuilds a row and
applies a PAP per element, and nothing said so. This step removes the
cliffs that were limits of the kernels rather than of the idea.

## Scalar captures in map and filter

`Vec.map (affine 2 1) v` and `Vec.filter (above k) v` now run in the
specialized loops. A plan carries `spCaps`, the number of scalar
captures; the site passes them ahead of the vector, so the kernel symbol
takes `c1 .. ck, vec`. At entry each capture must be a tagged Int
(anything else, a Bool or a float, goes to the generic tier with the
closure rebuilt by `k` applies); the captures are untagged once into
frame slots and passed raw to the unboxed clone before each element. The
element function's arity is captures plus one and fits the eight
registers. Float closures with captures decline, with the reason: a raw
float capture carries no tag an entry guard could check.

The audit's measurement was a five-million-element `map (affine 2 1)`
that missed the kernel and grew the actor pool by 67,109,184 bytes. The
same program now grows it by 0 bytes.

## Record maps of any width

The record-map kernel emitted at most four output fields, and each
field's dual took at most eight parameters. Both were choices, not
structure: cursors and buffered results are frame slots, so the output
count is unbounded, and a dual with more than eight parameters now takes
arguments eight and up through the per-hart spill cells, the convention
`compileFn` already uses for wide functions (`compileUFn` copies them out
in its prologue). A nine-field record map whose first field reads all
nine columns runs in place.

Two planner defects were in the way and are fixed:

- A helper that takes the whole element (`total r`) inlines to
  `let r' = el in …`; the planner peeled alias lets before inlining but
  not after, and read the leftover alias as the element escaping.
- (From step 1) a multi-arm shape dispatch was walked by taking its first
  arm.

## Record filters

`Vec.filter keep v` over a record vector had no kernel: the generic tier
rebuilt each row and applied the predicate. `soaDualPred` now dualizes a
one-argument predicate over the element's columns, inlining helpers that
take the element, and `emitRFilterSpec` runs one in-place pass: the
predicate reads its columns at row i straight from the spans, and a kept
row's words are copied from i to the write position in every column. The
column count is read from the header, so any record width compacts; more
than eight used columns go through the spill cells. Float predicates
decline for now.

The fold planner's refusal of column indexes at or past eight was the old
bitmap's limit and is gone; the real limit is seven used columns beside
the accumulator in registers.

## Reporting

A site whose element function is a partial application is now reported
when it declines, with the capture count and the reason: not an
arithmetic or record dual; a fold with captures (no kernel yet); more
than seven captures; a float closure with captures. Before, a captured
site that missed the kernel printed nothing.

## Not done

- **x64.** `spec = not x64` stands. The kernels use `s0..s9`; SysV has six
  callee-saved registers and the x64 lowering maps only `s0..s5`. Enabling
  the tier there means lowering `s6..s9` to frame slots in `X64.hs`, which
  is a change to the lowering, not to the kernels.
- Folds with captures, record accumulators, and type-changing `mapAs`
  through a kernel.
- Columns are still machine words.

## Evidence

`tests/base/veccaps.fpr` (in `check_base`), every site with no decline
note and zero pool growth: `affine` over 100,000 elements, `above` as a
captured filter, a Bool capture falling back to the same answer, the
nine-field record map, and a record filter keeping 559 of 1,000 nine-field
rows, against a Python reference. RV64, RV32 and x64 emit. The seven older
vector witnesses, `vecwide`, the typed-vector suite and the safepoint
ratchet (116 instructions on `bound_pipeline`) hold. `codegenRev` is 30.

# Checks in byte loops: what moved, what did not

Date: 12 November 2026. Kind: implementation record and findings. It follows
[allocation sites, strings and products](2026-11-12-ALLOCATION-SITES-STRINGS-AND-PRODUCTS.md),
whose section 5 found csv and wordfreq spending their time in the prelude's byte loops. It is a
first slice of the [fixed-cost proposal](2026-11-06-FIXED-COSTS-PROPOSAL.md)'s steps 1 and 3.

## Summary

| Measure | Before | After |
|---|---|---|
| csv instructions | 15.6 G | 13.1 G |
| wordfreq instructions | 16.5 G | 13.4 G |
| `myCmp` microbenchmark (20,001 compares of 1,011 bytes) | 2.638 G | 2.123 G |
| `strCmpGo` text | 247 instructions | 195 instructions |

All app outputs are unchanged. The changes are AArch64-only, apart from the String guard, which is shared IR. `codegenRev`
is now 216 (215 went to a concurrent send change on main). It had not been bumped for this branch's earlier codegen changes either, and a stale unit cache hid this
round's effect until it was.

## The loop, per byte, before

`strCmpGo` in its default build, for one equal byte:

- the fuel tick;
- two length guards, each untagging both operands, comparing, setting a flag and branching on it;
- for each string, `charAt`'s guarded fast path (`Codegen.StringRead`): an Int-bit test,
  a type-id test, a variant test, a length load, two bounds compares (each against a constant moved into
  a register first) and the byte load. That is about 25 instructions, twice;
- `i + 1`, untagged, added and retagged.

The stack check was already outside the loop: the self-loop's back edge enters after it.

## What changed

- **One header word for the String guard.** `StringRead` now guards with `OVariantTest` (type id
  and variant compared as one word, answering False for a tagged Int) instead of `OIsInt` followed by
  `OTagTest`. That is the same answer from one load and one compare.
- **Compare and branch (AArch64).** A block whose last instruction is an `OCmp` or `OVariantTest` used only
  by the block's branch compares and branches on the flags. There is no `cset` into a register and no
  `cbz` on it. A constant made in the same block for that compare alone becomes an immediate (`cmp x, #0`).
  This is the proposal's step 1 ("branch on the comparison directly; use immediate operands"), and every
  function benefits.
- **String scans keep up.** `Codegen.StringScan`, the opt-in loop versioning for String scans
  (`FPR_TYPED_IR_STRING_SCAN`), recognizes the one-word guard as well as the old pair.

## What did not move, and why

The invariant guards stay in the loop even with `FPR_TYPED_IR_EARLY_LOOPS=1 FPR_TYPED_IR_LOOP_MOTION=1`:

- **Motion finds them.** In the String loop it finds eight invariant operations: the two untagged lengths
  and each string's tests and address.
- **The pressure gate admits only the untags.** Values live across the slow paths' C calls need
  callee-saved registers. Eight are free on AArch64, and the loop already uses them.
- **Forcing them out loses.** With the gate disabled, and header tests admitted as speculatable, everything
  hoists and the microbenchmark improves (2.64 -> 2.15 G before the changes above), but the hoisted predicates
  spill to the frame. `LoopOptimize` keeps its rule that header tests do not speculate: its unit test pins it,
  and admitting them gained nothing under the gate.

Three ways forward, in order of expected value:

1. **Mixed scalar workers.** `strCmpGo`'s Ints (`i`, `la`, `lb`) travel tagged because a scalar
   worker requires every parameter to be a raw Int or Bool, and two of them are Strings. A worker
   that passes the Strings through as values and the Ints raw would remove the untag and retag work
   each byte (about 9 instructions) and free registers.
2. **Unswitch on invariant guards.** Test the strings once in the preheader. If both pass, run
   a copy of the loop whose guards are known true; otherwise run the original. No predicate then needs a
   register in the loop.
3. **Cold calls.** A slow-path C call could save its live values around itself instead of
   forcing every loop value into a callee-saved register. The loop would then use the caller-saved bank.

## Checks

Every base job passes on this change, apart from the four known-red ones. Updated expectations:

- **`check_typed_case`.** On a64mac the header test may now be fused into its branch, so there is no
  out-of-line `varno` label. The check accepts either form: the Int bit, then one header load at +0.
- **`tests/compile_budget.json`.** Allocation is now 2-3% lower on every program. `hello`'s peak residency is
  48 MB, the same as at `69d893a0`. The 28 MB recorded earlier today was an outlier, so the budget is rerecorded.

# Scalar replacement of loop-carried tuples and records (A2)

Date: 2 November 2026. Kind: implementation record. Base: main `b13aec9`.
Proposal: [2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md),
Phase 1 option A2 (`FPR_NO_TUPLE_SCALARS`).

## What it does

In a tail-recursive function carrying a fixed-width tuple or record parameter
`p` (such as `tests/bench/unbox/tuple_loop.fpr`), an inlined step helper
(`step p = case p of (a, b) -> (b, (a + b) % 1000003)`) or a `let`-bound next
state (`next = step p; loop (i - 1) next`) leaves the recursive call's argument
as a `CLet`/`CIf` tree whose leaves construct the next tuple `CMk t v xs` (or
forward `p` unchanged on a conditional branch), rather than a bare `CMk` directly
under `CApp`.

Previously, two passes declined on that shape:

1. `ReceiveTurns.allocates` (`compiler/ReceiveTurns.hs`) only exempted bare
   `CMk` nodes in `argAlloc`. When a recursive call argument was a `CLet`/`CIf`
   tree ending in `CMk`, `argAlloc` fell back to `rawAlloc`, counted the
   next-state tuple as per-iteration scratch allocation, and wrapped `loop` in a
   per-slab loop region (`$loop.in.loop` / `$loop.cycle.loop`) that passed `p`
   whole across the region cycle boundary.
2. `Workers.fieldWorkers` (`compiler/Workers.hs`) only recognized bare
   `CMk t v xs` at `args !! i` in `rebuilt`, `recursive`, `uses`, and `rewrite`,
   and ran only a single pass over non-internal functions.

With A2 (`cgTupleScalars`, default on; `FPR_NO_TUPLE_SCALARS=1` disables it with
cache tag `-notuplescalars`):

- `ReceiveTurns.hs` widens `argAlloc` and `iterAlloc` to descend through `CLet`
  and `CIf` when a bound variable or branch result is used only as the result of
  a recursive call argument (`usedOnlyAsResult`, `usedOnlyAsGroupArg`), while
  still charging `rawAlloc` on all intermediate bindings, conditions, and
  constructor field expressions.
- `Workers.fieldWorkers` (`compiler/Workers.hs`):
  - floats `CLet` and `CIf` out of `CLet n a b` when `n` is used only as a
    direct recursive call argument (`usedOnlyAsRecArg` / `prepRecArgLets`) and
    splits the leaf `CMk` into ordered field bindings `$worker.let.<k>.<n>`;
  - recognizes constructor trees (`ctorTags`, `isCtorTree`) at `args !! i`,
    including conditional arms that forward `p` unchanged (which become `CMk`
    leaves once `makeBody` substitutes `p` with `CMk t v (map CVar fields)`);
  - rewrites constructor-tree call sites (`pushCall`) by binding any
    non-trivial preceding arguments `take i args` to fresh `$worker.arg.` locals
    before pushing the `$worker.fields.` call to the `CMk` leaves of `args !! i`,
    preserving strict left-to-right argument and field evaluation order;
  - runs up to four rounds on newly created `$worker.fields.` functions so loops
    carrying multiple tuple or record parameters unbox each parameter in turn;
  - hands the resulting field worker to `scalarWorkers` (and `batchTicks`),
    producing `$worker.scalar.$worker.fields.<name>` with unboxed `Int`/`Bool`
    registers, one fuel tick per iteration, and zero heap allocations.

## Rollback and cache identity

- `FPR_NO_TUPLE_SCALARS=1` sets `cgTupleScalars = False` in
  `compiler/Compiler/Options.hs`, appends `-notuplescalars` to
  `optimizationFlags` / `codegenCacheIdentity`, and restores the bare-`CMk`
  restriction in `Workers.fieldWorkers`.
- `codegenRev` bumped to `144` in `compiler/Codegen.hs`.

## Verification

- `tests/CompilerOptions.hs`: verifies `FPR_NO_TUPLE_SCALARS=1` alters
  `codegenCacheIdentity`.
- `tests/WorkersCheck.hs`: unit-tests constructor-tree recursive arguments,
  `let`-bound next states, conditional parameter forwarding, multi-tuple loops,
  and the `workerizeWithOptions` rollback toggle.
- `tests/check_tuple_scalars.py` (registered in `tests/check_registry.py`):
  checks differential output, allocation counts (`1002 -> 1` requests on 1,000
  iterations of `tuple-step`, `let-bound-step`, and `record-step`; `502 -> 1` on
  `conditional-forward`; `1003 -> 1` on `two-tuples`; `<= 2` startup requests on
  `tests/bench/unbox/tuple_loop.fpr`), whole-value escape refusal, and assembly
  rollback under `FPR_NO_TUPLE_SCALARS=1`.

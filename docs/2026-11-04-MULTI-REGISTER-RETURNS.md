# Multi-register returns: a pair answered in two registers

Date: 2026-11-04. Status: landed, on for hosted A64, X64 and RV64
(`FPR_NO_PAIR_RETURNS=1` rolls back; cache suffix `-nopairret`; `codegenRev` 148).
Check: `tests/check_ret2.py` (base CI group). Unit test: `tests/CorePipeline.hs`.

This is the first C2 prerequisite from the
[unboxing proposal](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md) (addendum C,
order item 2): a function that answers a small all-scalar product answers it in
registers, so a non-inlinable, non-tail-recursive function returning
`(Int, Int)` stops allocating a heap cell per call.

## What it does

`Core.Opt.PairReturns` (last pass, after `BatchTicks`) finds functions whose
every result is a two-field constructor of one shape, directly or through a
saturated tail call to another such function (a fixpoint, so mutual tail calls
and self calls qualify). For each caller that only tests the pair's shape and
reads its fields (`let t = f x in if TagEq s t then ... Proj 0 t ... Proj 1 t`)
it routes the call to a twin, `$worker.ret2.f`. The twin's Core is the original
Core with its tail calls renamed to twins; only `Codegen.Lower` gives it the
pair ABI. The original `f` stays for every other use, so a pair that escapes
(used any other way than the shape test and the two projections) keeps the word
ABI untouched.

Typed IR: `TPair` (a function result type only), `OCall2` (defines the first
word), `OSecond` (the second word; must directly follow its `OCall2`, checked by
`Verify`) and `TRet2`. The adjacency encoding keeps `Instr` single-def. Both ops
are `AnyEffect`, so nothing merges, hoists or drops them. Each backend's
`selectBlock` fuses the `OCall2`/`OSecond` pair into one call instruction with
two fixed defs (x0/x1, rax/rdx, a0/a1) through `Calling.selectPairTransfer`
(`PairResult`: the clobber set excludes both result registers, and
`checkTransfers` validates the placement). `TRet2` selects a return with two
fixed uses. `Eval` models `TRet2` as a pair value so the IR oracle still runs.

Gate: hosted base profile, 8-byte word, not ARC, native backend A64, X64 or
RV64 (not QOS, not RV32, not builtin). Builtin non-ARC is the obvious next
profile; its allocator and root scans need the same review the scalar workers
had.

## Measurements

Arm64 host, 20M calls of `sumcount n = if n == 0 then (0,0) else case sumcount (n-1) of (s,c) -> (s+n, c+1)`
(`tests/bench/unbox/pair_ret.fpr`), best of 7:

| variant | time |
|---|---|
| word ABI, heap pair per call (`FPR_NO_PAIR_RETURNS=1`) | 154 ms |
| pair returns | 118 ms (-23%) |
| single-result control (same recursion, one Int) | 105 ms |

The control bounds the gain: the pair version is within 13 ms of a function that
returns one word, so what remains is the second `asr`/move, not memory.

## Verification

- Output is identical on and off for the benchmark, a mix of non-tail, mutually
  tail-calling, self-looping and escaping pairs, and three actors running the
  twin under 1 and 4 harts (preemption inside the callee).
- On A64, X64 and RV64 the twin is called, and the second result register is
  read after the call and before the next call; the twin returns it.
- The unit test covers twin creation, routing of the recursive call, the
  untouched escaping caller, the report note and the rollback.
- Regression: self loops (x64 under Rosetta, RV64 under QEMU), workers, list
  fusion, case-of-known, typed case, tick batching, registers, tuple scalars,
  early loops, reset reuse, ARC typed IR, compile budget, the cabal suites.

## Limits

- Only X64 and RV64 *emission* is checked, not execution: the hosted runtime
  harness is arm64 only. The shared selected-IR checks (`checkTransfers`,
  `Forms`, the allocator's fixed-operand validation) run on all three.
- Two-field pairs of one shape. Wider products need more result registers (x2..
  on A64, a2.. on RV, nothing past rdx on X64) and are a separate decision.
- A pair worker that a backend declines would leave callers calling it under a
  different ABI. Unit emission is strict for these targets, so the compile
  fails instead of linking; the twin never has a C fallback.
- Not done: RawWord fields (the other prerequisite, see
  [the experiment](2026-11-03-PAIR-RAWWORD-EXPERIMENT.md)), and the builtin
  profile.

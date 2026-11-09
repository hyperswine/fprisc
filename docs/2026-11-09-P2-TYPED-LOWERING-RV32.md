# P2 typed lowering on RV32: two pipeline facts the plan mirrored only for the host

9 November 2026. Follows the
[typed closures and vectors record](2026-11-09-TYPED-CLOSURES-AND-VECTORS.md),
whose eight-target vector-read check stopped on RV32 with a typed-lowering
disagreement in `logPutTo`.

## What was wrong

Every sweep so far ran on the host, and `check_typed_lowering.py` covered host
and RV64. RV32 differs from both in two ways the plan didn't follow:

1. **Literal lets.** Since step 3c the plan substituted every Int-literal let
   at its uses, because the optimizer's `normIn` does that before the erased
   lowering. `normIn` only runs with constructor reuse and fast scalars
   (64-bit word, fuel, no ARC). On RV32 the erased Core keeps
   `let level = 2` (an early constant) while the typed plan put the literal at
   its use, so any program reaching the prelude's log functions stopped with a
   disagreement (`log`, `logErr`, `logWarn`, `logStart`, `logEchoAt`,
   `logPutTo`).
2. **The call table.** The erased lowering resolves calls against the
   optimized program plus the read-only imported templates (`Codegen`'s
   `context`). The typed lowering used the placed program, which has neither
   the templates nor `Mono`'s compatibility clones. A call to
   `$typed.mono.entries@...1` was `Local` in the erased code and `Imported` in
   the typed (mconf `braced`, `inferType`; report `report`). On the host the
   same functions were hidden in the `optimized` exemption, because `normIn`
   also changed their Core.

## Changes

- `Codegen.normalizesLiterals` says when `normIn` runs; the optimizer's
  options use the same definition (`reuses`). The plan builds plain lets and
  substitutes literals as a separate pass (`literalLets`) only when that holds.
- `TypedLowering.typedFunctions` takes the emission's call table (the ready
  program plus the imported templates) and the typed lowering resolves calls
  against it first.
- `check_typed_lowering.py` has an RV32 leg: six programs (the
  typed_lower_s1 fixture, vector_reads, mconf, report, vecpipeline, swarm),
  default system, no refusal, full accounting, code identical to
  `FPR_NO_TYPED_LOWER=1`.
- `tests/LowerTyped.hs`: the literal let is kept when the target doesn't
  normalize.

## Results

| Sweep (151 programs) | Host | RV32 |
|---|---|---|
| compiling, code identical to `FPR_NO_TYPED_LOWER=1` | 145 / 145 | 128 / 128 |
| disagreement, refused | 0, 0 | 0, 0 (was 3 disagreements after the literal fix alone, and every program reaching the log functions before it) |
| class / emitted typed | 34,311 / 32,468 | 11,195 / 10,771 |
| `optimized` | 241 (278 before the call-table fix) | 84 |

The 23 RV32 programs that don't compile fail the same way with
`FPR_NO_TYPED_LOWER=1` (no `main`, posix-only primitives, 64-bit features).
`tests/typed_core/vector_reads.fpr` is identical to the escape build on all
eight targets.

Unit suites (43), corpus (host, RV64, RV32), baseline and baseline gate,
bridge, policy, compiler options, typed vectors, specialization, `make
stdcheck` and QOS guishell (2,527 of 2,635 typed; run with `FPR_HOME` at the
qos checkout and `FPR_PATH` at fprisc) pass. Compile budget unchanged:
+12.4 / +12.8 / +6.7% allocation, still red.

The 16 "same" functions in the slice 3 attribution were mostly this
call-table mismatch, not a rewrite. The `Mono` closure cases (let-bound
closures made direct calls) remain the main reason functions keep the erased
code.

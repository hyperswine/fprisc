# Type-directed case tests in native codegen (C1 Piece 1)

Date: 2 November 2026. Status: implemented; enabled by default for native
compilation, roll back with `FPR_NO_TYPED_CASE=1` (cache tag `-notypedcase`).
This lands C1 Piece 1 from the 2026-11-02 addendum of
[the unboxing and zero-overhead proposal](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md).
Touches codegen only; no runtime layout or `.abirev` change.

## Problem

Every constructor pattern test in Core (`CTagEq tid variant v`) other than
`Bool` (`tid = 1`, which already lowered to `OTruth`) previously lowered in
`Codegen.Lower` to `OTagTest tid variant v`. Across AArch64, x86-64, and
RISC-V, `OTagTest` emits a multi-branch sequence with two internal labels
(`tagno`, `tagdone`) that tests three things:

1. `(v & 1) == 0` (the value is not a tagged `Int` immediate),
2. `*(int32_t *)(v + 0) == tid` (the 32-bit `type_id` header word matches `tid`), and
3. `*(int32_t *)(v + 4) == variant` (the 32-bit `variant` header word matches `variant`).

On x86-64, testing `case xs of Nil -> ...` in `list_fold` (`std/list.foldGo`)
took 17 instructions (including `andq $1`, two memory loads at `0(%reg)` and
`4(%reg)`, two 32-bit immediate materializations, three conditional branches,
and an unconditional jump across `.Ltagno` / `.Ltagdone`).

For a `case` whose scrutinee type is a statically known nominal sum type, the
first two checks are redundant: the type checker guarantees that `v` is a
heap object (or static nullary singleton) of type `tid`, never a tagged `Int`
and never a value of another `type_id`. Only the 32-bit `variant` word at byte
offset `+4` can vary at runtime.

## Static nominal type ID partitioning

`Frontend.Desugar` assigns disjoint 32-bit `type_id` ranges:

| Category | `type_id` range | Runtime `type_id` test needed? |
| --- | --- | --- |
| `Bool` | `1` | No — already lowered via `OTruth` (`ldrsw` at `+4`) |
| `List`, `Result` | `2`, `3` | No — nominal builtin sum types (`OVariantTest`) |
| Nominal `Type (...)` ADTs | `0x20000000 .. 0x7EFFFFFF` | No — content-addressed nominal ADTs (`OVariantTest`) |
| Record shapes | `0x00010000 .. 0x0FF0FFFF` | **Yes** — row-polymorphic field projection and record update dispatch across candidate record shapes by `type_id` (`OTagTest`) |
| Single-constructor tuples / `Unit` / `Atom` | `0, 4, 5, 6, 10..14, 0x10000000+` | **Yes** — retained for `fieldWorkers` entry shape guards and foreign probe checks (`OTagTest`) |
| Runtime objects (`String`, `Vector`) | `9000+` | **Yes** — inline vector/string fast-path guards (`OTagTest`) |

When `polTypedCase` is enabled (`cgTypedCase`, default on unless
`FPR_NO_TYPED_CASE=1`), `Codegen.Lower` lowers `CTagEq tid variant v` with
`isStaticNominalTid tid` (`tid == 2 || tid == 3 || (tid >= 0x20000000 && tid < 0x7F000000)`)
to `OVariantTest variant x :: TVal -> TPred`.

## IR and target selection

`OVariantTest Int VId` is a pure typed-IR predicate operation (`TVal -> TPred`):

- **Verifier (`Codegen.Verify`):** checks `0 <= variant <= 2147483647`,
  expects `TVal`, yields `TPred`.
- **Evaluator (`Codegen.Eval`):** evaluates `RObj _ c' _` to `VPred (c == c')`
  and reports `Stuck` on non-constructor values.
- **Simplifier (`Codegen.Simplify`):** shares duplicate `OVariantTest`s within
  a basic block and drops unused definitions (`opEffect = Pure`,
  `clobbersRegisters = False`).
- **AArch64 (`Codegen.Target.A64`, `a64SelectionRev = 28`):**
  3 instructions, 0 internal branches, 0 internal labels:
  ```asm
  ldrsw xN, [xV, #4]
  cmp   xN, #variant
  cset  xR, eq
  ```
- **x86-64 (`Codegen.Target.X64`, `x64SelectionRev = 27`):**
  3 selected instructions (`movslq`, `cmpq`, `sete/movzbq`), 0 internal
  branches, 0 internal labels:
  ```asm
  movslq 4(%rV), %rN
  cmpq   $variant, %rN
  sete   %al
  movzbq %al, %rR
  ```
- **RISC-V (`Codegen.Target.RV`, `rvSelectionRev = 28`):**
  4 instructions (`lw`, `li`, `xor`, `seqz`), 0 internal branches, 0 internal
  labels.

In `tests/bench/unbox/list_fold.fpr`, the `Nil` test inside `std/list.foldGo`
drops from 17 x86-64 instructions and two internal labels (`.Ltagno0`,
`.Ltagdone1`) to 4 instructions (`movslq 4(%rdi), %rax`, `cmpq $0, %rax`,
`sete %al`, `movzbq %al, %rax`) before the block's `testq` / `jne`, lowering
`foldGo`'s `segmax` bound from 42 to 31 instructions.

## Measured

On the host (aarch64-apple-darwin, GHC 9.8.2 build of `./fpr`), the same
`tests/bench/unbox/list_fold.fpr` binary built with and without
`FPR_NO_TYPED_CASE=1`, 15 interleaved runs each: median 47.1 ms against
47.6 ms, a 1.1% difference. The static shrink is real and is the point of the
change (code size, WCET bound, and every `case` on a nominal sum type), but
this loop is a pointer-chasing walk over a 1M-cell list in which the variant
test is not the bottleneck, so the instruction count does not translate into
time here. The runtime win belongs to shapes where the test dominates, which
[the proposal](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md) reaches through
representation work (C2) rather than through this piece.

## Verification

- `tests/CompilerOptions.hs`: verifies `FPR_NO_TYPED_CASE=1` alters the
  codegen cache identity (`-notypedcase`).
- `tests/TypedIR.hs`: verifies `OVariantTest` lowering on `List`, preservation
  of `OTagTest` on record shapes and single-constructor tuples, `polTypedCase`
  rollback, and reference evaluator equivalence.
- `tests/check_typed_case.py` (registered in `tests/check_registry.py`):
  checks differential execution with and without `FPR_NO_TYPED_CASE=1` across
  `List`, `Result` (`|>?`), recursive nominal ADTs (`Tree`), and
  row-polymorphic records, and verifies emitted assembly on `x64`, `a64mac`,
  and `rv64`.

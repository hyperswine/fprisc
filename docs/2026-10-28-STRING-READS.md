# Guarded inline String reads

2026-10-28, codegen rev 136.

`strlen` and `charAt` were the last per-byte C calls in the managed
pipeline: byteloop spent a call, an argument marshal and a return per
byte on work that is two loads. They now lower as guarded typed CFG
fragments in the shape of the scalar vector reads
(`docs/2026-10-25-REGIONS-LOOPS-CALLS.md`): `Codegen.StringRead` plans
the fragment, `Codegen.Lower` emits it when the policy allows, and a new
`OIndexByte` op (one `add` on every selector) forms the byte cursor.

The fragment, for `strlen s`:

- `s` is a tagged Int -> call the original C entry;
- `s`'s header is not `(T_STR, 0)` -> call the original C entry;
- otherwise `len` is `OLoad TInt (OAddress s) 8`.

`charAt s i` adds `i >= 0` and `i < len` guards, then
`OLoadByte (OIndexByte (OAddress s) i) 16`. Every guard miss calls
`fpr_g_charAt_call2`/`fpr_g_strlen_call1` with the original values, so
the runtime keeps its check order and its exact trap texts — the
fragment never traps by itself. The layout constants (W64 `str_t`: len
at 8, bytes at 16, `T_STR = 9000`) are contracted by `_Static_assert`
against `runtime/fpr.h` in the unit suite.

The evaluator (`Codegen.Eval`) models the managed String memory the
fragments read — `OAddress`/`OIndexByte`/`OLoad`/`OLoadByte` over an
`RString`, and the two C entries with their check order and exact trap
texts — so TypedIR's semantic checks (`length counts bytes including
NUL`, the range trap text) run unchanged against the fast lowering.

## Boundaries

- Managed 64-bit hosted/QOS profiles only (`polStringFast`, on by
  default). Builtin/RV32 keep the C entry; a custom `primEntry` or a
  source function named `strlen`/`charAt` declines the plan.
- Control: `FPR_NO_STR_FAST=1` (`-nostrfast` in the option identity).
- One subtlety worth remembering: `calleeOf` refuses `strlen`/`charAt`
  (they sit in `foreignName`'s inline list), so the Lower hook builds
  the `Callee` from the HAL `Prim` entry's symbol directly and
  `StringRead.canRead` re-verifies the exact symbol.

## Verification

- `cabal test StringRead` (new): verified CFGs, C fallback on disable /
  Builtin / RV32, custom-entry and shadowing refusal, operand/trap
  order, the C layout contract.
- `tests/check_string_fast.py` (new, in the Base registry): boundary
  indices, empty string, both trap texts and their order, 1/4 harts,
  inlining on/off, fast on/off in one cache; emission differs on
  a64/x64/rv64 and not on rv32.
- `make unit-tests` (54 suites), `check_vector_fast.py`,
  `check_core_pipeline.py`: PASS.

## Measurement

`bench/2026-10-28-string-reads.json`: byteloop 1.12-1.15x (two paired
rounds, load 5-7). The loop's remaining per-byte cost is the tail-call
iteration itself, the two overflow-checked adds and the fuel tick —
exactly what the interval analysis (plan step 4.4, which can now see the
bounds guards it needs to discharge) and tick amortization (step 8,
bound measured in
`docs/2026-10-27-TICK-AMORTIZATION-BOUND.md`) address next.

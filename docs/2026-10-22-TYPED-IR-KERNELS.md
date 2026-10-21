# Typed IR: native callers of vector kernels, and inline F64

Date: 2026-10-22. Kind: implementation and measurement record.
Base: main `6ad6d05` (the [fib work](2026-10-22-TYPED-IR-FIB.md)).
Branch `typed-ir-kernels`, implementation commit `2585112`.

The [migration record](2026-10-22-TYPED-IR-MIGRATION.md) left two gaps
that kept code on the legacy path or made the typed path slower: a
function with a vector-specialisation site was declined whole, so its fused
column kernel survived; and every F64 operation was a runtime call where
the legacy generator expands it inline. This page closes the first for the
callers and the second for arithmetic, comparisons and literals.

## Vector kernels: the caller goes native, the kernel stays legacy

A kernel the legacy specialiser emits (`fpr_vspec_...`) is a function of
the generated-code ABI: the legacy caller stages its arguments and calls
it like any supercombinator (`Codegen.genT`, `knownCall`). So the typed
caller can do the same. `nativeSelect` now rewrites each specialisation
site, under exactly the legacy gate (`vecSpec`, the fusion, word-size and
float conditions, lexical shadowing), into an application of
`$vkernel:<symbol>` to the site's arguments, innermost sites first. The
lowering resolves that name to a new callee kind, `Generated <symbol>`: the
generated-code ABI under an explicit symbol, a safepoint call like a
local one. The unit then emits every kernel its native callers name, by
the same `requestSpec` key and symbol a legacy caller would register.

The kernels themselves are still legacy emission (the translator path).
Typed kernels remain open; see below.

Checked: `tests/check_typed_ir_coverage.py` builds the pipeline fixture for
a64, x64, rv64 and rv32 with the backend on and checks that `main` is
native, that the fused kernel is emitted, and that a native function calls
it; the native result equals independent arithmetic. The pipeline
benchmark's root is now 4/4 functions native (main was declined before).

## Inline F64

On the 64-bit word an F64 value is its IEEE bits in a `TVal`. Three IR
operations:

| Operation | Meaning | A64 | x86-64 | RV64 |
|---|---|---|---|---|
| `OFloatBin` | `+ - * /` on the bits, IEEE, no FMA | `fmov d16/d17`, `fadd`..., `fmov` back | `movq` to `xmm14/15`, `addsd`..., `movq` back | `fmv.d.x ft0/ft1`, `fadd.d`..., `fmv.x.d` |
| `OFloatCmp` | `< <= > >= ==` false on a NaN, `!=` true | `fcmp`, `cset` with `mi ls gt ge eq ne` | `cmp{lt,le,eq,neq}sd` mask (gt/ge swap operands), `movq`, `and $1` | `flt.d`/`fle.d`/`feq.d` (`!=` is `feq` then `xori`) |
| `OBits` | a literal's bits (`f64frombits hi lo`, the legacy `floatLitBits`) | `movz/movk` | `movabsq` | `li` |

Each operation is one selected instruction. The scratch floating-point
registers live inside that instruction's expansion only: no float register
is allocated, nothing floating crosses a call or a safepoint, so the
scheduler contract (no FP context saved,
[NATIVE-IR-CONTRACTS](2026-10-21-NATIVE-IR-CONTRACTS.md)) is untouched. An
inline F64 operation in tail position is a value, not a tail call of the C
entry. `FPR_NO_F64_INLINE=1` keeps the runtime calls, as for the legacy
generator. RV32 keeps the calls (its floats are boxed).

Checked: `tests/check_typed_ir_coverage.py`'s float V ABI test (400 edge
pairs: signed zeros, subnormals, infinities, NaNs, against C; F32/F64; ten
arguments; aggregates; a deep tail loop; 1 and 4 harts) passes with the
inline operations. `tests/check_float_inline.py` now runs its x86-64 leg
for the typed backend too: ten generated leaf functions under Rosetta, 0
mismatches over 1,280 pairs against C. Its harness gained a real hart
block (fuel at word 0, the stack window at words 57 and 58) because typed
functions check their stack on entry. RV64 floats run in CI's direct RV64
Linux runtime stage.

## Measurements

Apple M4, 31 alternating paired rounds, every output checked
([summary](evidence/2026-10-22-typed-ir-kernels/all-summary.md),
[raw](evidence/2026-10-22-typed-ir-kernels/all-results.json)). Median
paired ratio, typed-ir against legacy-best:

| Workload | Ratio | 95% interval | Faster pairs |
|---|---:|---|---:|
| floatcmp | **0.592** | 0.588..0.595 | 31/31 |
| nbody | **0.896** | 0.895..0.897 | 31/31 |
| helpers | 0.595 | 0.585..0.619 | 31/31 |
| sum | 0.634 | 0.629..0.639 | 31/31 |
| SHA | 0.910 | 0.908..0.917 | 31/31 |
| fib | 1.031 | 1.008..1.048 | 8/31 |
| pipeline | 1.066 | 1.051..1.079 | 5/31 |

Before this change floatcmp was 0.10 s against legacy's 0.06 s on this Mac;
it is now 0.03 s.

**Pipeline is still about 5% slower, and the cause is not established.**
Its internal timer covers only the fused kernel, and the kernel's
instructions are identical under both backends (its calls and body were
compared). A separate pipeline-only run
([summary](evidence/2026-10-22-typed-ir-kernels/pipeline-summary.md)) times
legacy and legacy-best identically (3.030 and 3.024 ms) and the typed build
at 3.199 ms. That points at code placement (the kernel's address and
alignment move when the functions before it change), but no alignment
experiment was run: forcing kernel alignment changes legacy emission and
belongs to its own change.

**Fib** moved from 1.017 (the fib page's run) to 1.031 here; nothing in
this change touches fib's code. Run-to-run variation of that size is
recorded, not explained.

## What is still open

- **Typed kernels.** The fused column kernels, the SoA, RVV and NEON forms
  and the unboxed `fpr_ufn_` clones are still legacy emission. Retiring the
  translators needs them in the typed IR.
- **Float registers.** Values still travel as bits in integer registers.
  Keeping floats in FP registers across instructions needs an FP allocation
  pool and, across safepoints, a context-switch change.
- **Kernel alignment** and the pipeline gap above.

## Validation (this Mac, arm64)

Before the tail-position fix: `check_typed_ir_coverage.py`,
`check_typed_ir.py`, `check_typed_ir_a64.py`,
`check_typed_ir_aggregates.py`, `check_typed_ir_rv.py`,
`check_registers.py`, `check_self_loops.py`, `check_workers.py`,
`check_reuse.py`, `check_float_inline.py`, `check_x64_vectors.py`,
`check_vector_pipelines.py` (also with the backend on),
`check_x64_local.py --require-execution` and the full `check_base.py` (105
jobs) passed. The float check with the backend on found the tail-position
gap; after the fix, `check_float_inline.py` (both legs),
`check_typed_ir_coverage.py`, `check_typed_ir.py`, `check_typed_ir_a64.py`,
`check_typed_ir_rv.py` and `check_typed_ir_aggregates.py` pass. Native
Linux x86-64 and the RV64 Linux runtime are CI's legs.

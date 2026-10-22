# Typed kernels, the rest: mapAs, write-back folds, F32, NEON, RVV, the GPU hook

Date: 2026-10-22. Kind: implementation and validation record.
Base: main `12b7d24` (the [record kernels](2026-10-22-TYPED-RECORD-KERNELS.md)).
Branch `typed-ir-retire`.

After the column and record kernels, the [retirement inventory](2026-10-22-TYPED-IR-RETIREMENT.md)
had six kernel forms still on the legacy emitter: `Vec.mapAs`, the
write-back fold, F32 columns, NEON maps, the RVV sum and the SoA fold's
GPU pair-sum hook. This page lowers all six through the typed IR. With it,
no vector kernel plan is refused by name under `FPR_TYPED_IR_BACKEND`;
strict mode still reports compiler errors and unbounded segments.

## 1. `Vec.mapAs` (`Kernel.lowerMapAsKernel`)

A layout-changing map keeps the legacy kernel's shape exactly: the input is
an Int, boxed or float column (the three representations the legacy guard
admits; a record vector goes generic), the output is built by the runtime
(`Vec.new`, or `Vec.newAs layout` with the layout string as an immortal
string object) and filled by one `Vec.push` per element, the callback is the
ORDINARY tagged function (`fpr_fn_<f>`: its own overflow messages, its own
fuel tick, nothing cloned), and the input is freed at the end. An Int word
is tagged on the way in; a boxed or float word is passed as it is. A failed
guard rebuilds the closure and tails into the runtime's `Vec.mapAs`.

## 2. The write-back fold

`Vec.fold f z (Vec.map g v)` is the pipeline kernel with the stages map `g`
then fold `f`: the fused loop stores `g(el)` back into the column and folds
over the stored value, returns `(acc, v)`, and its generic fallback is the
two-pass sequence (generic map, then generic fold) in source order. No new
builder: `typedKernelPlan` maps the `wfold@` plan onto `Kernel`.

## 3. F32 columns and inline F32

An F32 value is its 32 bits in the low half of the word (the runtime's
`bitsf`). Two IR operations, `OFloat32Bin` and `OFloat32Cmp`, inline the
F32 arithmetic and comparisons on the 64-bit targets the way the legacy
unboxed clones did (`fmv.w.x` / `fadd.s` ...), and an F32 literal
(`f32frombits`) is its bits (`OBits`):

| Target | Forms |
|---|---|
| A64 | `fmov s16, w`, `fadd s16, s16, s17`, `fmov w, s16` (zero-extends, as the legacy translation of `fmv.x.w`) |
| x86-64 | `movd %e, %xmm14`, `addss`, `movd %xmm14, %e` (zero-extends); `cmp{lt,le,eq,neq}ss` with the F64 operand rules |
| RV64 | `fmv.w.x ft0`, `fadd.s`, `fmv.x.w` (sign-extends, the legacy form; the runtime reads the low 32 bits) |

The kernel builders admit F32 elements, captures, accumulators and record
columns (kind byte 7, the float representation) on the 64-bit targets;
RV32 keeps its boxed floats and refuses by name. `FPR_NO_F64_INLINE=1`
keeps the F32 runtime calls too, as it does for F64.

## 4. NEON pairs (A64)

One IR operation, `OSimdPair`, maps the two lanes at an address in place
through a `SimdExpr` (the lane, literals, Int `+ -`, F64 `+ - *`), with the
legacy gate (`neonExpr`'s): a capture-free single map, a straight-line body,
an Int body of exactly one `+` or `-` (the stored lanes' 63-bit fit is then
the whole overflow test, checked after the store; a lane outside it traps
with the kernel diagnostic). The expression evaluates into `v17..v31`, the
verifier bounds it at those 15 registers. The kernel loop runs the pair
loop while two elements remain, each step charged both elements' callback
entry ticks at once (`OSafepointN`, rendered as one `sub x10, x10, #n`),
then the scalar loop takes the tail from where the pairs stopped. x86-64
and RISC-V refuse the operation; the planner only offers it on A64.

## 5. RVV sum strips (RISC-V V, `--rvv`)

Explicit RVV mode no longer keeps the legacy kernels: every kernel is typed,
and a capture-free Int sum fold (`\a b -> a + b`) is strip-mined through
three operations:

- `ORvvVlMax`: `vsetvli x0`, the lanes a register holds; the builder caps it
  at 64.
- `ORvvLanes addr n`: `vl = n`, the lanes loaded (`vle64.v v8`), and whether
  every lane is within `rvvLaneBound` (`vredmax.vs`/`vredmin.vs` against
  ±2^49 on RV64, ±2^17 on RV32).
- `ORvvSumLoaded acc`: `acc + vredsum`.

The legacy RVV sum had no overflow check. The typed strip is exact: with at
most 64 lanes each within 2^(bits-14) and the accumulator within
`rvvAccBound` (2^(bits-1) - 2^(bits-8), checked in the IR), no prefix of a
strip can leave the Int range, so the reduction equals the scalar fold in
every case where the scalar fold does not trap, and a strip that fails
either bound hands the rest of the vector to the scalar loop, whose checked
adds trap in source order. One safepoint a strip. The RVV map was already
disabled in the legacy emitter (its lanes had no overflow check); maps stay
scalar under `--rvv`.

## 6. The GPU pair-sum hook

A capture-free SoA fold of `acc + column0 + column1` (`isGpuPairSum`)
offers itself to `fpr_gpu_vec_fold_pair_sum` before its loop, as the legacy
fold did. The typed kernel calls a new runtime form,
`fpr_gpu_vec_fold_pair_sum_tagged(col0, col1, len, seed)`, which answers
the tagged Int sum when the hook took the fold and 0 when it declined (the
weak default), so no out-parameter address is needed in the IR.

## Counted safepoints

`OSafepointN n` charges `n` ticks in one sequence on all three targets
(`sub x10, x10, #n`; `subq $n, (%r10)`; `addi t4, t4, -n`); the evaluator
records `n` tick events. Only the NEON pair uses it.

## Tests

- `tests/check_typed_ir_kernels.py` (Base, CI): the kernels fixture gains
  the write-back fold (6 kernel CFGs, the oracle checks the stores and the
  fold on every target); `f32_kernels.fpr` with `f32_oracle.c` (700 F32
  map/filter/fold cases against C `float` arithmetic one rounding at a
  time, x86-64 under Rosetta and RV64 under QEMU with `imafd`; hosted 1 and
  4 harts); `pairsum_kernels.fpr` with `pairsum_oracle.c` (a hook that takes
  one length and declines the rest: both the hook's answer and the CPU strip
  are checked); `mapas_kernels.fpr` (hosted: legacy and typed agree, the
  typed root names the mapAs and write-back kernels); the NEON fixtures emit
  `ldr q16` and the lane operations under strict mode. The old "strict mode
  refuses an F32 kernel" check is gone with the refusal.
- `tests/TypedIR.hs`: the SIMD body rules (one Int op, no division, no Int
  op in a float body, the 15-register budget), the counted safepoint, the
  RVV lane signature.
- `tests/check_vector_kinds.py` (hosted NEON against a C IEEE reference and
  100 SIMD tails) and `check_vector_limits.py` (accepts the typed mapAs
  kernel as the witness) run under either backend.
- QOS `check-all.sh` legs: `vecfuse2` (the write-back fold on bare-metal
  RV64), the `--rvv` leg under QEMU with `-cpu rv64,v=true` (`vsetvli`,
  `vredsum`, `vredmax` in the image, `vecfuse2: OK`).

## Validation (this Mac, arm64; QOS `f9c00ae`)

- `tests/check_typed_ir_kernels.py --require-execution`, every leg run:
  the kernels fixture 6 CFGs with 700 cases and 4 trap cases on x86-64
  (Rosetta), RV64 and RV32 (QEMU); 1,500 record cases per target; 500
  mixed Int/F64 cases on x86-64 and RV64; 700 F32 cases on x86-64 and
  RV64; 100 pair-sum folds per target with the hook's answer taken once;
  mapAs and the write-back fold hosted against legacy; the NEON fixtures'
  emission; hosted results on 1 and 4 harts for every fixture.
- `check_vector_kinds.py` with the backend on: the hosted NEON map against
  its C IEEE reference and the 100 SIMD tails pass through `OSimdPair`.
- `check_typed_ir_coverage.py` (400 F32/F64 edge pairs against C, now
  through the inline F32 operations) and `check_float_inline.py` pass with
  the backend on.
- The F32 fixture's hosted result equals the legacy build's on 1 and 4
  harts; the pair-sum fixture's too.
- QOS `check-all.sh` with `FPR_TYPED_IR_BACKEND=mixed`: 162 of 162 in one
  run (the vecfuse2 write-back fold and the `--rvv` leg under QEMU's V
  extension among them: `vsetvli`, `vredsum`, `vredmax` in the image).
- `check_base.py`, every job: 106 of 106 with the backend on and 106 of
  106 legacy (after a `KernelIR.hs` constructor fix found by the first
  typed run).
- CI: dispatched with the commit.

Not verified: physical RISC-V V hardware (QEMU only), the GPU hook with a
real GPU implementation (the weak default declines; the oracle's hook
proves the path), native x86-64 or RISC-V timing. No timing was taken for
the new forms on this Mac either; the NEON and RVV code is the legacy
instruction shape, not a measured improvement over it.

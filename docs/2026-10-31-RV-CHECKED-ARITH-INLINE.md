# Direct RV: checked Int arithmetic inline, the C primitive as the slow path

Date: 31 October 2026. Kind: change record with equivalence argument and
emission evidence; runtime timings are not measured here. Base: main `1a09f01`
plus this change. `rvSelectionRev` 26 -> 27 (the cache identity changes).

## What changed

`OArith` on the direct RV selector (`Codegen.Target.RV.arith`, shared with
`OKernelArith`) previously boxed both operands and called the C primitive
(`fpr_prim_fn__x2b` ...) for every checked operation: about eight instructions
plus a runtime call, on the hot path, per `+`/`-`/`*`/`/` that the
difference-bound pass could not discharge. A64 (`Target/A64.hs` `arith`) and
x86-64 already compute inline with a fit check and re-enter the C primitive
only on the slow path. RV now does the same, using the sequence its own kernel
form has used since the vector kernels landed:

- fast path: raw `add`/`sub` (or `mul` + `mulh` sign check, or the explicit
  zero-divisor test then `div`), then the Int-domain fit check
  (`slli 1; srai 1; compare`), about seven instructions, no call;
- slow path: retag the ORIGINAL operands (`slli 1; ori 1`) and call the same
  C primitive, which owns the panic text and failure order.

`OArithU` (the difference-bound proof's output) is unchanged: it is already a
plain instruction for Add/Sub, and Mul/Div keep the call because the pass
produces only Add/Sub. Checks the interval pass discharges are still removed
entirely; this change is about the checks that remain.

## Why the two paths trap together

The IR guarantees `OArith` operands are in the Int domain (63-bit on RV64,
31-bit on RV32), so retagging reconstructs the primitive's exact arguments.
For each operation the fast-path failure condition is the primitive's trap
condition (`runtime/runtime.c` `fpr_prim_fn__x2*`):

| op | C primitive traps when | fast path branches to slow when |
| --- | --- | --- |
| `+`/`-` | `__builtin_*_overflow` or `!fits_int(r)` | the fit check on the possibly wrapped word |
| `*` | `__builtin_mul_overflow` or `!fits_int(r)` | `mulh != sext(mul)` or the fit check |
| `/` | `y == 0` first, then `!fits_int(r)` | the zero test first (it targets the slow path), then the fit check |

Boundary cases kept apart while writing this:

- An `x + y` whose true sum leaves the word entirely (exactly +-2^63) wraps to
  a value whose top two bits differ, so the fit check still fires; the
  operand domain (|x|, |y| <= 2^62) excludes every further wrap.
- A zero divisor branches BEFORE the divide: RISC-V `div` by zero returns -1
  instead of trapping, and -1 would pass the fit check.
- The most negative Int divided by -1 produces 2^62, which passes the word
  divide but fails the fit check; the primitive then reports `Int overflow`
  for `/`, its own text.

The slow path re-enters the primitive rather than trapping directly so the
panic text (which prints the operands) and the check order stay in one place.
`OKernelArith` keeps its kernel trap entries; its emitted sequence is
unchanged.

## Emission evidence

- `tests/bench/fib.fpr`, builtin RV64: `fib` segmax 66 -> 72, `ccalls` 1 -> 1
  (the remaining call moved to the cold block). The `n-1`/`n-2` guards are
  discharged by the interval pass and stay plain `sub`; the final checked `+`
  was `slli; ori; slli; ori; call fpr_prim_fn__x2b; srai` and is now
  `add; slli; srai; compare; branch` with the call in the cold continuation.
- `tests/bench/helpers.fpr`, builtin RV64: `lerp` segmax 58 -> 101 with the
  same four call sites, now cold. Static size grows per remaining checked
  site (about ten instructions: fast path plus cold block); the hot path
  stops paying the two tags, the argument staging, the call and the untags.
- Whole programs keep the same `call fpr_prim_fn_*` site count (the sites
  moved out of line), so the stubbed QEMU harnesses that provide their own
  primitive definitions still link.

## Verification

- `tests/SelectedIR.hs`: three new checks - the RV64 subtraction is inline
  with the fit check, the slow path re-enters `fpr_prim_fn__x2d`, and the
  native bound survives the cold block.
- `tests/check_riscv_scalar.py --bits 32` and `--bits 64` (QEMU, real
  runtime primitives): the `intMax Unit + 1`, `intMin Unit - 1`,
  `(intMax Unit) * 2`, `(intMin Unit) / -1` and `17 / 0` fixtures still
  produce the required panic text, in both indexed-memory modes, with
  primitive shadowing intact. RV64 locally needs the SoftFloat bridge
  (`FPR_SOFTFLOAT_ROOT`, built with `CC=riscv64-unknown-elf-gcc
  MARCH=rv64im_zicsr_zifencei MABI=lp64` and the cross `ar`).
- `tests/frame_emitter.py`, `tests/check_registers.py`: unchanged, pass.

## Not measured

- No runtime timings here: QEMU-user counts are not throughput, and this
  machine is not RV hardware. Physical-board timing (Tang Nano 20K, RV32)
  and hosted RV64 timing are the outstanding evidence; the expectation is
  the byteloop/sha-class gap narrows on every check the interval pass keeps,
  but that is a hypothesis until paired on/off timings exist.
- Code-size growth is quantified only on the fixtures above; a bounded survey
  of the stress corpus (`tests/tangnano20k_stress`) should accompany the
  board timing.
- The `mul` fast path adds `mulh` + compare; its latency on the in-order
  board core versus the C call is exactly what the board timing should
  attribute.

## Follow-ups

The outstanding evidence above and the items past this change are tracked in
[the zero-overhead follow-up inventory](2026-10-31-ZERO-OVERHEAD-FOLLOWUPS.md).

- `OArithU` Mul/Div still call the primitive; if the difference-bound pass
  ever widens past Add/Sub, they can reuse the same fast path.
- The tagged-domain algebra (`(a-1) + b` overflows the word exactly when the
  Int add overflows, `docs/2026-10-20-FIB-GAP-TO-C.md`) could shorten the
  fast path further on the tagged boundary paths; not taken here.

Reproduce: `python3 tests/check_riscv_scalar.py --bits 32` (RV64 additionally
needs `FPR_SOFTFLOAT_ROOT`); `cabal exec -- runghc -w -icompiler
tests/SelectedIR.hs`.

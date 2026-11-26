# Float maths in Sol, five new functions, and one answer on every target (27 November)

Kind: delivery record. Branch `sol-progressive`. Item 4 of the
[Sol review](2026-11-26-SOL-SCRIPTING-REVIEW.md) order (§5.4), maths part; bytes
and serial are not started.

## What was missing

- **Sol** had `Num.sqrt`/`floor`/`round`/`div` and nothing else. coscad wrote
  `sin`, `cos`, `tan`, `atan`, `atan2`, `asin`, `acos`, `exp` and `log` in Sol
  (`models/lib/num.sol`).
- **Native** had `F64.sin`/`cos`/`exp`/`log`/`log2`/`pow`/`sqrt`, from a
  freestanding implementation in `runtime/runtime.c`. No platform libm is linked
  on any target. It had no `tan`, `asin`, `acos`, `atan` or `atan2`.

## What changed

1. **Five new kernels in the runtime:**
   - `ftan_` reuses the sine/cosine reduction and divides once.
   - `fatan_` uses Cephes' reduction (tan 3π/8, 0.66) and rational approximation.
   - `fatan2_`, `fasin_` and `facos_` are built on `fatan_`.

   Against the macOS libm over 400,001 inputs each, the worst cases are: tan
   3 ulp (away from its poles), atan 1, atan2 2, asin 2, acos 2. Signed zeros and
   infinities follow the usual rules (`atan2 0 (-0) = π`).
2. **Native builtins** `F64.tan`/`asin`/`acos`/`atan`/`atan2` and the same for
   `F32` (computed in double and rounded once, like the other F32 functions).
   They are added to the builtin environment, the ARC entry table, the builtin
   machine's `arc.c`, and the representation and primitive tables.
3. **Sol builtins:** `Num.sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`,
   `exp`, `log`, `log2`, `pow`, plus `Num.bits` (a float's IEEE bits as an
   `Int`, native's `I64.ofF64Bits`). They are not wrappers over Haskell's libm:
   `sol-vm/Sol/FMath.hs` ports every runtime kernel operation for operation.
4. **No fused multiply-add in the runtime.** clang on arm64 fuses `a*b+c` by
   default, and x86-64 builds do not. `runtime.c` had 325 fused operations, 35 in
   `fsin_` alone, so `F64.sin` answered differently on arm64 and x86-64, and no
   unfused port could match it. `runtime.c` now turns contraction off
   (`#pragma clang fp contract(off)`, and the GCC equivalent).

   This changes native results on arm64 in the last bit or so, to the values
   x86-64 already gave. A first attempt put the pragma inside `#ifdef
   FPR_QOSAPP`, where it applied to QOS app builds only. The parity check below
   is what caught it.

## Proof

`tests/sol-checks/fmath-parity.sol` (push tier) builds `tests/fmath/parity.fpr`
natively and runs `tests/fmath/parity.sol` in Sol. Each prints the IEEE bits of
12 functions over 2001 inputs; that includes `sin` at arguments up to about
14,000, which exercises the reduction. The rows must be identical. They are: 0
differences in 24,012 values.

## Not done

- **coscad.** `models/lib/num.sol` can drop its trigonometry, `exp` and `log` for
  the builtins, but coscad pins Sol 0.13.1. That change waits for a release
  containing this work. The file also holds formatting helpers (`fixed`, `repr`,
  `trim`) and constants, so deleting it entirely, as the review's success line
  proposed, would also need those.
- **`std/math`** still defines `tan` as `sin / cos`. It is a committed std module
  (a hash change), and core spec Q21 merges it into the `F64` struct anyway.
- **Bytes and serial libraries**, the rest of item 4.

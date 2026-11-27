# pow to within an ulp, and four scripts that failed on their own (27 November 2026)

Kind: delivery record. Branch `pow-and-scripts`. These are the two follow-ups that
[2026-11-27-SOL-F64-STEP-2.md](2026-11-27-SOL-F64-STEP-2.md) found and did not change.

## pow

**Before:**
- `fpow_` (`runtime/runtime.c`) computed `exp(y * ln x)` in plain doubles. The rounding of
  `y * ln x` is an absolute error in the exponent, so the result's relative error grew with
  `|y ln x|`.
- `2.5 ^ 2.0` was `6.24999999999999`.
- Against the macOS libm over 2 million inputs, the worst case was 1,509 ulp.

**Now:** pow is computed in double-double, with error-free sums and Dekker products. There is
still no FMA, so arm64, x86-64 and Sol's port give the same bits.
- **Whole-number exponent below 2^40:** binary powering in double-double. The error it builds
  up is under n * 2^-104 < 2^-64, so the final rounding is the only one that matters. A power
  that is exactly representable comes out exact: `2.5^2`, `10^22`, `(-2)^3`, `3^-2`
  (correctly rounded). When an intermediate leaves [2^-969, 2^996] (where the low word would
  be subnormal or the split would overflow), it falls through to the general path.
- **Otherwise:** `ln x` as a hi+lo pair (the `atanh` series with `t = (m-1)/(m+1)` carried in
  double-double), then `y * ln x` as a Dekker product, then an `exp` whose argument reduction
  takes in the low word.
- **Unchanged:** NaN, infinities, zero and `x = 1`. A negative base with a non-integral
  exponent is still NaN (v1: no complex results).
- **Accuracy:** against the macOS libm over 2 million inputs (ordinary, wide-range, near-1
  bases with exponents to 1e9, and negative bases with integral exponents), the worst case
  is 1.000 ulp and no input is worse than 1 ulp.

`Sol.FMath.fpow` ports it operation for operation. `F32.pow` computes in double and rounds
once, so it improves too.

## The four scripts

### `tools/toolchain-files.sol`

- **Cause:** the module defined `readBytes`, which became a builtin in 0.16.0 (`143df4e1`). Its
  importers still type-checked, because their module names are qualified.
- **Fix:** renamed to `readFileBytes`, in the module and in the five files that call it through
  `F.readBytes`. All 21 importers type-check.

### `tests/sketch-paths.sol`

This hosts the native `tests/paths.fpr` in Sol. Two defects kept its `@Model.hp` literals as
plain strings:
- **`compiler/Frontend/Paths.hs`** (shared with native):
  - The literal's root was always taken to be its first dotted segment. A shape from a `use`d
    module is declared under a qualified name (`T.Model`), so `@T.Model.hp` looked up `T`. The
    root is now the longest dotted prefix that names a declared shape, ending in an upper-case
    segment. Codec literals (`@T.Msg`) accept a qualified name the same way.
  - The rewrite also skipped script statements (`> ...`); they are now included.
- **`sol-vm/Sol/Lang.hs` `renameTops`:** Sol splices a module by renaming its definitions. It
  renamed the shape but not the path literals naming it. A literal's upper-case root is now
  renamed along with its type (`Modules.reSelf` already did this for native).

It now prints exactly what `fpr run tests/paths.fpr` prints.

### `sol/lib/cli.sol` and `sol/lib/live.sol`

- **Cause:** both declare a type named like a builtin or preamble type: `cli.sol` its own
  `Option`, `live.sol` its own `Cmd` (and an `Ev` constructor `Msg`, which the preamble's `Cmd`
  also has). Imported, they are qualified (`CLI.Option`). As a root script they merged with the
  builtin:
  - exhaustiveness asked `case option of Option ...` for `Some` and `None`;
  - a value of one type would unify with the other.
- **Fix:** the root script now shadows. Each type or constructor the script itself declares
  under a builtin type name (`Option`, `Result`) or a preamble type or constructor name is
  renamed to `Main.<name>` throughout the root, path literals included
  (`resolveCoreBuiltins`, `sol-vm/Sol/Lang.hs`).
  - Types and constructors are compared within their own namespace, so a type `Msg` beside the
    preamble's constructor `Msg` is left alone.
  - The VM prints a constructor by its base name, so output does not change.
  - `None`, `Some`, `Ok` and `Err` keep the documented rule that a bare one is always the
    builtin.

## Checks

- **`fmath-parity`:** gains four pow columns:
  - integral exponents -30..30 over negative and positive bases;
  - a base from e^-685 to e^685;
  - a base near 1 with exponents near 1e9;
  - integral exponents beyond 2^40.

  Native and Sol are identical over all 16 columns x 2001 inputs.
- **`sol-surface`:** gains four cases, each of which failed before this work:
  - a script type shadowing `Option` and `Cmd`;
  - a path literal in a statement;
  - a path literal inside a `use`d `.fpr` module;
  - exact powers.
- **Native files with path or codec literals:** `fpr check` gives the same verdict as before
  on all of them (29 files across `examples/`, `std/` and `tests/`).
- **Rescan:** all 235 Sol scripts with `sol --asm`. No type errors remain. The other errors are
  the two deliberately bad examples (`bad_double`, `bad_leak`), and libraries that fail only
  when compiled as root scripts:
  - `sol/lib/build.sol`, `git.sol`, `webstyles.sol` and `tests/sol-checks/helpers.sol` each
    define a prelude value name (`exists`, `log`, `input`, `collect`). The NAMES rule refuses
    that on purpose ("rename yours"). Their importers type-check.
  - `std/std.sol` reports that its `Numeric` and `List` structs miss the `Arith`/`Functor`
    signatures.
  - These already failed before this work.
- **Suites:** compiler unit tests pass. Sol check suite (CI-style): 38 run, none unexpected; the extended `sol-surface` and `fmath-parity` also pass on their own.

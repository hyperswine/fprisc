# Exact Int and the 11-19..11-21 changes: review and follow-ups (22 November)

Kind: review with measurements, fixes landed, plan. Covers main from
`0230c8f1` to `9effc8a6` (v1.0 numeric slices 1–3, exact `Int`
`1695e4de`, 010 small immediates `6d94bc23`, the A64 encoder slice) and
the follow-up branch `fix/v1-followups`. Measured on the M4 Mac (arm64)
unless a target is named.

## What works

- Exact `Int`: values past the small range, floored `/` and `%`, mixed
  comparisons and demotion all agree with Python on arm64, x86-64 (macOS
  target under Rosetta) and bare-metal RV64 in QEMU; `tests/bigint.fpr`
  (26 checks), `tests/i64.fpr` (55), `tests/i32.fpr` pass on all three, and
  RV32 in the board suite after the fixes below.
- Small immediates: no wrong output anywhere tested; no measurable speed
  change except `bench/byteloop`.
- The Sol JIT after the A64 encoder slice: every `sol/examples` script gives
  the same output with `SOL_JIT=1` and `SOL_JIT=0`.

## Broken, fixed on this branch

| What | Cause | Fix |
|---|---|---|
| Every Sol script importing `std/map` (via `sol/lib/cli`, `sol/lib/http`) failed type checking: release packaging (`stage-toolchain`, `package-toolchain`, `compiler-licenses`, `package-fprmeta`), the board runner, `target-image`, `config-update` | `1ff2e47f` made `Option`/`None`/`Some` Core; Sol's module splice then captured the builtins a module only refers to (`std/map`'s `Option` became `CLI.Option`, its `None` met the preamble's `Cmd` `None`, `O.None` named nothing) | `.fpr` modules' references to Core builtins are marked at splice time; `resolveCoreBuiltins` (Sol.Lang) restores them, sends an unresolved `O.None` to the builtin as Modules.hs does for FP-RISC, and renames the preamble's `Cmd` `None` to `Cmd.None` so a bare `None` in Sol keeps meaning "no command" |
| `make bare-metal(-run)` on RV64 did not link since 11-14 | runtime `__builtin_clzll/ctzll/bswap64` need libgcc; the link used `-nostdlib` only | link libgcc, as the RV32 builtin profile already does |
| CI red since `1695e4de` (`result-sizes`, `CompilerOptions`) and two unit suites never reached (`NullaryConstants`) | tests expecting `Int` overflow to trap, scalar workers on by default, `Unit` as `fpr_unit` | tests follow v1.0; the scalar-worker cache tag now marks the opt-in (`-scalar`) so the default tag stays empty |
| RV32 board suite `numeric` | `I64.toInt` is total under exact `Int` | test updated (as `tests/i64.fpr` already was) |

## The slowdown

`1695e4de` lowers every `Int` `+ - * /` and ordering to `OArithVal` /
`OCmpVal` (TVal operands, inline tagged fast path, bignum slow path). The
passes that removed `Int` cost before — `Codegen/Interval.hs` turning
`OArith` into `OArithU`, string-scan versioning, raw loop-carried `Int`s,
scalar workers — recognize only the old `TInt` form, so they stopped firing.
Scalar workers were also turned opt-in in the same commit, rightly: they
pass `Int` arguments unboxed and an argument may now be a bignum.

29 programs (`tests/bench/*` with expected outputs, the eight CLBG programs,
the apps), best of three, all outputs checked:

| Compiler | Geomean vs `1ff2e47f` | worst |
|---|---|---|
| `1695e4de` alone | 1.27x | clbg nbody 2.67x, sim_vector 2.19x, floatcmp 2.15x |
| main `9effc8a6` | 1.28x | the same; small immediates add only byteloop 1.67x→2.07x |
| this branch | 1.20x–1.22x (two runs) | clbg nbody 2.15x, floatcmp 2.09x, sim_vector 1.86x |

What the branch does (A64 only): the exact operations learn which operands
are known small — `OTag` of a raw `Int`, which always fits — and skip their
tag tests, untagging and retagging. Both sides known small: the raw kernel,
the slow path taken only on leaving the small range. A literal added or
subtracted: one tag test and the add on the tagged word, overflow found by
one compare. Equality with a known-small side is one compare (a bignum is an
even pointer, never a small Int's odd word). A tag used only by these
operations is built only on their slow path. Boundary tests (`a + 1` at the
largest small Int, `b - 1` at the smallest, `* 7`, compares and equality
against bignums) agree with Python.

`Interval` and `StringScan` unit suites still fail: they test exactly the
optimizations exact `Int` turned off, and stay as the acceptance tests for
the work below.

## What is left: raw Ints proven small

The spec (§1.2) keeps raw machine words for locals proven small. The cost
that remains is a running value retagged at every step, because the slow
path may have made a bignum: `count + a + b + ...` in floatcmp, `a = i * 7`
then `a + 1 .. a + 6` as vector indexes in nbody, `n - 1` in fib.

1. Expose the fast path in the IR: lower `OArithVal` as a tag test
   (`TCondBr`), a raw `OArith` block and a slow-call block, so the raw
   value exists in the IR on the fast edge. Interval, string-scan
   versioning and the loop passes then see `TInt` again on that edge.
2. Smallness facts: a value is small on an edge after a successful tag
   test, after a raw op proven not to leave the range, and for literals and
   lengths. The interval pass needs the bound on the *other* operand too
   (`i < n` bounds `i + 1` only when `n` is small); the fast edge of
   `OCmpVal i n` supplies it.
3. Loop versioning on smallness, like string-scan versioning: test the
   loop-carried `Int`s once at entry and run a copy where they are raw.
4. Interprocedural ranges over call sites (whole programs are compiled):
   `pair i j` in nbody is only called with `0 <= i < j < 5`. With them,
   scalar workers can be re-enabled for parameters proven small.
5. The same cheap paths on RV and X64 (this branch changed A64 only).

## Older failures seen, not from these commits

- Nightly config differential: `loopcalls` and `vecinline` with
  `FPR_NO_REUSE` fail to build, every night since at least 11-16.
- `layout-raw`, `layout-raw-i64`, `reactor` fail on macOS (pass on Linux
  CI), also with the compiler from before these changes.
- `tests/bench/helpers.expected` disagrees with both compilers;
  `sol/examples/nn.sol` and `csvmatrix.sol` fail type/linearity checks.

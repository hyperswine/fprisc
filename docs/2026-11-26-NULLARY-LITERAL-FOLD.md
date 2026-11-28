# Nullary integer literals folded at their references (26 November)

Kind: implementation record. Branch `zero-cost-named-keys`, from `main` at
`f607eb59`. First half of step 2 of
[MVU alignment](2026-11-26-MVU-ALIGNMENT-INTENT.md).

## What changed

`keyR = 19.` is a nullary definition. The typed inliner refused every
nullary entry (`NullaryCallee`), so a reference such as `K.keyR`, or `keyR`
in its own module, compiled to a call whose result type the caller did not
know: a call, a tag test and the generic `==` path per guard.

`compiler/Core/Typed/Inline.hs` now records, per catalog snapshot, the
nullary entries whose whole body is an integer literal (the single clause
with no patterns and no guards that desugaring produces), and replaces each
`Int`-typed reference to one by the literal. It is reported as an applied
inline decision. The definition keeps its symbol, so exports and other
units still link.

Naming such a definition evaluates nothing, so no effect, trap or
allocation moves. The reference no longer pays the callee's entry tick; the
fuel charged is lower by that tick and never higher.

Only integer literals are folded. A nullary definition that computes
(`derived = limit + 1.`) stays a reference.

`codegenRev` 262 -> 263.

## Measurement

The benchmark from the MVU page, macOS arm64 (M4), median of 15 process
runs, 3,000,000 dispatches:

| dispatch style | before | after |
|---|---|---|
| literal patterns | 12.4 ms | 12.3 ms |
| guards against constants in the same module | 22.0 ms | 12.9 ms |
| constants from another module, plus `K.ctrl K.keyC` | 44.3 ms | 13.6 ms |

The compiled `f` has no call to a `keyX` entry. Linux x86-64 and the QOS
targets were not measured.

## Checks

- `make unit-tests` passes. `tests/TypedInline.hs` gained two checks: a
  literal is folded and reported, and a computing nullary definition stays a
  reference with the literal's own symbol kept.
- The Sol regression checks pass on macOS arm64
  (`sol tests/run.sol --jobs 6`, push tier, exit 0, no known-failure
  entries hit), including `compile-budget`, `cost`, `std-golden` and
  `eq-cheap`. `compile-budget` reports std-live and pos1 far under their
  recorded baselines ("record the new baseline"); that was not compared
  with `main` here.

## Later the same day: constant calls and `std/keys`

- **Constant arithmetic.** `Codegen.Simplify` has a new pass,
  `fold-constant-arithmetic`: exact Int `+`, `-`, `*` of two literals becomes
  the literal when both operands and the result are below 2^28 in magnitude
  (inside the tagged range of the 32-bit targets, so the fast path could not
  have overflowed on any width). `K.ctrl K.keyC` now compiles to
  `const 4046`. `codegenRev` 264.
- **`std/keys`.** One module holds the evdev codes and the modifier encoding
  (`shift`, `ctrl`, `ctrlShift`, `alt`), the superset that qos `appwire` had.
  `std/game` re-exports the names it had (`keyEsc = K.keyEsc.`); a re-export
  is itself folded to a literal in the first inline round, so a reference
  through `std/game` folds too. Registered in `compiler/Safety.hs` and the
  allow-list review; `tests/std/keys.fpr` covers the values, the helpers,
  the re-exports and named-guard dispatch.
- **Measurement** (same benchmark and machine): literal patterns 12.3 ms,
  same-module constants 12.9 ms, `std/keys` across `use` 14.1 ms, through
  the `std/game` re-export 14.1 ms. The compiled function has no call to a
  key entry.
- **Checks.** `make unit-tests` passes and the push-tier Sol checks pass
  again on the complete change (112 passes, no failure, no known-failure
  entry hit). The six qos apps of its CI type-check for `qx64` with this
  compiler.

## Not done

- **Guard runs as a switch.** A run of `k == literal` guards on one
  scrutinee is still a chain of comparisons, and each inlined `ctrl` keeps
  its entry tick. This is the remaining 1-2 ms against literal patterns.
- **The qos copies.** `programs/mods/appwire.fpr` and `sdk/qos/desktop.fpr`
  still carry the table; they can use `std/keys` once qos pins a compiler
  that has it. terra-ii still matches raw codes.
- Linux x86-64, the QOS targets and the nightly tier were not run.

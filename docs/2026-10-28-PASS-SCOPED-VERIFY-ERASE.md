# Pass-scoped verification and erasure in the linked pipeline

2026-10-28, codegen rev 137 (unchanged: emitted assembly is byte-identical).

Item 3 of the [compile-speed plan](2026-10-27-COMPILE-SPEED.md) (§2.2):
every pass in the `Linked` pipeline re-verified the whole program and every
`replaceClosed` re-erased every definition, seven passes per compile. Each
pass now reports exactly which definitions it rewrote; verification and
erasure run only for those.

## Mechanism

`ClosedProgram` (`compiler/Core/Typed/Pipeline.hs`) carries a fifth field,
`closedTouched :: S.Set String` — the names of definitions whose closed
form the producing pass actually rewrote. The flag is derived per pass,
never by comparing trees:

- `planVectorReads`: `VectorRead.planReads` returns `(Expr, Bool)` via a
  `Writer Any` walk; the flag fires only on the
  `LetPattern`/`VectorReadPair` rewrite.
- `normalizeProgram`: `Normalize.normalize` returns `(Function, Bool)`;
  `normalizeClosed` lifts it through `Close.mapClosedChanged`.
- `inlineProgramsWithDecisions`: `Inline.inlineClosedWithDecisions`
  returns `(ClosedFunction, [Decision], Bool)`; the flag is the per-function
  serial delta (an inlining fired), or `propagate` rewrote, or `hygiene`
  renamed. When no flag fires the pass returns the input `ClosedFunction`
  unchanged, skipping its rebuild and import restriction entirely.
- `fusePrograms`: `fuseClosed` returns `(ClosedFunction, [FusionNote], Bool)`;
  the flag is whether the pass inserted fused code (`M.null added`).
- `specializeProgramsWithDecisions`: conservative — every non-elided
  definition is marked touched.

Two supporting constructors in `compiler/Core/Typed/Close.hs`:

- `mapClosedChanged`: per-definition transform returning
  `(ClosedFunction, Bool)`; an unchanged definition passes through with its
  existing verification, a changed one is verified atomically as before.
- `mergeClosedLibrary`: the unverified import merge, so a pass that changed
  nothing does not re-verify the import closure it re-derives
  (`importClosedLibrary` is still merge + verify where a rewrite happened).

`verifyLinkedStep` (Pipeline.hs) replaces the per-pass whole-program
re-check. Every `ClosedFunction` already arrives verified by the transform
that built it (`mapClosed`/`rewriteClosed`/`closeFunctionWith`), and the
input program is invariant across the pipeline, so what remains per pass
is: closed/source owner keys match, cross-definition code-label and
binder-identity uniqueness over **all** definitions, and — only for touched
definitions — the root-interface check against the source and
`verifyProgramCalls`.

`replaceClosed` (`compiler/Compiler/Native/Core.hs`) erases only
`closedTouched` definitions via `eraseDefinitions`; untouched definitions
carry their erased entries over from the previous program
(`M.restrictKeys p kept`). Erasure uses per-definition fresh name supplies
starting at 0, so a partial erase is byte-identical to a full one.

The inline driver also early-exits on a fixed point: a round in which no
definition was touched rebuilds the same catalogue and walks the same
bodies to no effect, so the remaining rounds are skipped (this was §3.7 of
the [redundant-work review](2026-10-28-REDUNDANT-WORK-REVIEW.md)).

## The approach that failed: structural equality diffing

The first attempt derived `Eq` on the typed AST and diffed definitions
after each pass. A time/allocation profile of the qos build
(`fpr-prof +RTS -p`, 2026-10-28 15:44) showed the comparisons dominating
the compile:

| Cost centre | % time | % alloc |
|---|---:|---:|
| `$fEqScheme_$c==` (Type.Syntax) | 34.0 | 0.0 |
| `$fEqClosedFunction` (Core.Typed.Close) | 27.7 | 21.8 |
| `$fEqRow_$c==` (Type.Syntax) | 4.3 | 0.0 |
| `$w$c==` (Type.Syntax) | 1.8 | 0.0 |

≈68% of total compile time in derived `Eq` — comparing the `Type`
annotations carried at every `Expr` node costs about as much as
typechecking, and the diff ran several times per pass. The ABBA pair
agreed: 61.3 GB allocated vs the old pipeline's 52.4 GB, 53-63 s vs 31-42 s
CPU. Every added `Eq` instance was reverted; passes report their changes
instead.

## The bug the fixed-point exit exposed

The inline driver runs up to N rounds and stops early when a round touches
nothing. The first flag-driven version kept only the **final** round's
touched set — and the final round is the empty fixed point, so the
accumulated rewrites of rounds 1..N-1 were marked untouched. `replaceClosed`
then carried the **stale** erased bodies forward while the closed program
held the new ones, and the region rewrite failed with
`region rewrite: unbound generated references: $fuel` on
`FPR_NO_SPEC=1 fpr run tests/base/specialization_alloc.fpr`. The `go` loop
now accumulates touched names across rounds
(`M.intersectionWith accumulate`, `t <> prev`): the erasure boundary diffs
against the program as it was before the whole inline pass, not before the
final round. All four combinations of `FPR_NO_SPEC` × warm/cold were
re-verified after the fix.

## Measurement

Apple M4, macOS aarch64, GHC 9.8.2, warm unit cache, qos
(`programs/main.fpr --target=qa64`), paired ABBA with `+RTS -s`;
old = the pre-change binary. Raw logs in
[bench/2026-10-28-pass-scoped-verify-erase.json](../bench/2026-10-28-pass-scoped-verify-erase.json).

| Round | loadavg1m | old CPU s | new CPU s | ratio | old alloc GB | new alloc GB |
|---|---|---|---:|---:|---:|---:|
| A (16:23) | 1.6-2.1 | 16.668 / 16.693 | 12.605 / 12.408 | 1.32-1.35x | 36.49 | 28.68 |
| B (19:14) | 3.4-6.9 | 22.682 | 16.692 | 1.36x | 36.49 | 29.12 |

Round A predates the touched-accumulation fix (the fix changes tracking,
not the transform; it returns ~1.5% of the saved allocation). Round B is
the shipped binary: **1.36x CPU, −20.2% allocation**. Round B's second
adjacent pair (24.10 vs 24.19 s) is excluded: the new binary's two runs
differ by 45% CPU at identical allocation (64 bytes apart), so machine
contention dominated that pair.

Compile-budget ratchet re-recorded (`tests/compile_budget.json`):

| Fixture | before | after | delta |
|---|---:|---:|---:|
| hello | 1.706 GB | 1.436 GB | −15.8% |
| std-live | 31.72 GB | 27.89 GB | −12.1% |
| pos1 | 76.84 GB | 65.74 GB | −14.4% |

## Byte identity

- pos1 `.s`: sha256 `698fd2935763063d5c98168f2e532af73c705b1cc95a00770ec1fc33b8c8be6c`
  for the old binary and three separate new builds.
- qos root `.s`: sha256 `6bd5615467bbf1a703cd05664da22908df71c66de56ccd3525b678795521bbb4`
  for both arms of both ABBA rounds; all 49 unit `.s` files byte-identical
  when paired by prefix.

## Correctness

`make unit-tests`: 33 suites pass. All 149 `check_base` jobs pass
(including `check_specialization` with `FPR_NO_SPEC=1`, the configuration
that exposed the accumulation bug). The compile budget passes at the
re-recorded values.

## What remains

- Specialize still marks every non-elided definition touched; it could
  report per-definition serial/callback deltas like the inliner does.
- Erasure could run once lazily at the region/codegen boundary instead of
  per pass, now that partial erasure is correct; the passes between never
  read the erased program.

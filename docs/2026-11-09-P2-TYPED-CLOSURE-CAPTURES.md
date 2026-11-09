# P2 typed lowering: local closures over any arrow-free capture

9 November 2026. Follows the
[typed closures and vectors record](2026-11-09-TYPED-CLOSURES-AND-VECTORS.md),
which asked for the attribution sweep to be re-run before claiming closure
exemptions gone, and the [RV32 record](2026-11-09-P2-TYPED-LOWERING-RV32.md).

## Attribution after the captured-list rule

`FPR_TYPED_LOWER_OPTIMIZED=1` over the 151-program sweep (host, posix), compared
with the slice-3 attribution:

| kind | slice 3 | captured lists (rev 205 + RV32 fix) | this change (rev 206) |
|---|---|---|---|
| single-use let sunk, a closure value | 167 | 159 | 47 |
| dead let removed, a closure value | 24 | 26 | 24 |
| same (call-table clones) | 16 | 0 | 0 |
| single-use let sunk (`normIn`) | 28 | 27 | 27 |
| let with 2-3 uses differs | 17 | 25 | 25 |
| other (dead plain lets, application shape) | 5 | 3 | 3 |
| classified | 257 | 240 | 126 |
| `optimized` in the notes | 258 | 241 | 126 |

The captured-list rule moved 8 functions. The call-table clones went with the
RV32 fix. A temporary trace of the refused local closures showed why the rest
stayed: their captures are a `Wire` (derived codecs, 38 + 66 `codec` /
`stateCodec` lambdas), a `Decoder`, a `Store`, a record or a function. None is
`plain` or a list of `plain`.

## Change

`Core.Typed.Callback.localClosure` admits a capture that is non-linear (as
before) and whose type is closed and reaches no arrow, directly or through a
nominal type's constructor fields (`arrowFree`, read from the `TypeContext`
constructor schemes, recursive types cut by a seen set). A named type with no
constructors in that table (abstract or foreign) proves nothing and is admitted
only if `plain`; `List` keeps its explicit case, its element checked as the type
argument. The reasoning:

- The direct call passes each capture as an argument instead of storing it in a
  closure object. For a closed, arrow-free type the ownership shape
  (`Ownership.TypeShape.linShapeT`) describes the value exactly, nominal ones
  included, so ownership sees the same non-linear value either way. The erased
  `Mono` already makes this call in emitted code, for every capture.
- An arrow's shape is `LU` whatever its environment holds (TypeShape's own note:
  callable capture multiplicity is still compiler work), and an open variable
  can become linear. Those captures keep the closure, as before: the existing
  `an arrow type does not prove the callback environment unrestricted` and
  `unused closures without capture ownership proof remain in the graph` cases
  are unchanged and pass.

A binding the rule admits is also marked `removable`, so `trimCallbacks`
deletes it when a later rewrite removes its last use (before this, the first
attempt turned 112 sunk lets into 112 dead ones: the direct call was made, the
dead closure stayed).

New unit cases (`tests/TypedCallbacks.hs`): a nominal capture holding an Int
calls directly with no closure binding left; a nominal holding a function keeps
its closure. Codegen revision 206.

## Results

- `optimized` 241 -> 126; typed 71,175 -> 71,337 functions in the sweep's
  per-program sum (s1 75,769, refused 0).
- Assembly identical to `FPR_NO_TYPED_LOWER=1` on all 145 compiling host
  programs and all 128 compiling RV32 programs; the 6 host and 23 RV32 failures
  are the same programs as before (no `main`, posix-only).
- 43 unit suites, typed-lowering corpus (host, RV64, RV32 leg), pipeline
  baseline and baseline gate, signature bridge, policy D1/D2, compiler options,
  typed vectors, specialization differential, stdcheck: pass. QOS guishell
  2,527/2,635 typed, no disagreement (unchanged).
- Budget unchanged and still red: hello +12.4%, std-live +12.8%, pos1 +6.8%.

The code-identity sweep compares typed against erased lowering of the same
callback output, so it doesn't by itself test the callback change; the runtime
checks (stdcheck, specialization differential, baseline behaviour contracts)
do.

## What is left in `optimized`

- 47 sunk closure lets: 42 are `G.locals` path-literal lambdas whose capture
  is a record of `get`/`set`/`enc`/`dec` functions, 5 `pageOf`. They need a
  rule for arrow captures, which needs closure capture multiplicity in the
  ownership shapes first.
- 24 dead closure lets, the same set as slice 3 (`rebuildCmd`, `withItem`,
  `putItem`, ...), not yet examined.
- 27 `normIn` sinks and 25 multi-use lets: the Core optimizer, not `Mono`.

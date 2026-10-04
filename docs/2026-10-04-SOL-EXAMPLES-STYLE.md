# Sol examples in the intended style

Date: 2026-10-04. Kind: implementation record. Applies
[STYLE-DIRECTION](2026-10-03-STYLE-DIRECTION.md) and
[STYLE](2026-09-01-STYLE.md) to `sol/examples`; companion to
[ideal examples](2026-10-02-IDEAL-EXAMPLES.md), which did the same for native
Base programs.

## Why

Ten Sol examples no longer compiled. Most failures were one shape that the
exhaustiveness check now refuses: a guard on `xs == []`, then a body `case`
with only the cons arm. `dash` ended its guards on the complement of the one
before, which the checker cannot see. A few signatures were more general than
their definitions. `todo2` pinned a `base` from before the 0-based change.

Fixing them by adding catch-all arms would have compiled but kept the
problems the style direction names. They were rewritten in the style instead:
bboard, dtree, mandel, physics, prolog, terra, todo, todo2, pos and dash.

## What the style versions do

**Syntax.** Every traversal is a `List` fold, map, filter, find or range,
usually as a `|>` pipeline. No hand-written list recursion remains. MVU
`update` (and terra's `step`) is one clause per message, guarded where it
branches. Choices are guard clauses rather than nested `case`. Tuples
destructure in clause heads.

**Constraints.**

| Example | Contracts | Measures | `unsafe` left |
|---|---|---|---|
| bboard | `sKey` row 1..30 and side 0..1, `holeLetter` side and column 1..5, `padL` width >= 0 | none needed | none |
| dtree | | `build` by depth; `predict` and `showT` structurally on `Tree` | none (was 14) |
| mandel | `rowOf` row >= 0 | existing `mand` | none |
| physics | | | `fly`, `flyN`: integrate until y < 0, which no integer measure states; noted at the definition |
| terra | `slotAt` and `setAt` lane 0..2 | | none (was 42) |
| prolog, todo, todo2, pos, dash | | | none |

**Input boundaries.** A precondition is for programming errors, not for
rejecting input. Browser payloads are parsed with `Try.parseInt` and a bad
one is refused rather than allowed to panic the update:

- pos: `buy` with a non-number or a position outside the catalog is logged
  (`Print`) and ignored. It used to panic in `!`.
- todo, todo2: `toggle` with a non-number is logged and ignored. It used to
  panic in `Str.parse`. An out-of-range row still toggles nothing.
- terra: `play`/`attack` with a non-number log "no such card"/"no such lane";
  an attack lane outside 0..2 logs "no such lane" before the lane contract
  applies. An empty payload is now refused instead of read as 0.
- bboard: a netlist line that cannot be placed (fewer than two nodes, an
  unsupported kind) is reported under `-- skipped --` instead of dropped.

**One name per meaning.** `sol/lib/base.sol` gains `indexed` (Sol has no
`List.indexed`), `firstOr` and `say`, replacing copies in four examples.
Examples use `base.pI`, `base.nl`, `base.max0`, `base.boolInt` and
`base.removeAt` instead of local copies. `todo2` is re-pinned to
`base#f9616700c2a16d11`.

## Verification

The originals no longer compile, so they cannot stay as running references
the way `examples/ideal/` keeps them. Instead, each rewrite was compared with
a minimally patched copy of its original (catch-all arms and `unsafe`
markers only) on the same inputs:

- bboard, dtree, mandel, physics and prolog print identical output, and
  bboard is identical on a netlist that fills the board.
- todo, todo2, pos, dash and terra (two scripted games, 820 lines) give
  identical `update` results and rendered views for whole message sequences.

The one behaviour change in that comparison is a fix. When every part on a
power net fails to place, the original crashed in the rail wiring; the
rewrite skips that rail.

`tools/sol-examples-check.py` keeps this true. It runs each example from a
temporary copy and compares against `tests/sol-examples/`:

- the scripts' output, plus bboard on a malformed netlist and a full board;
- the apps' message traces, ending with malformed payloads that must be
  refused without a panic;
- six violated contracts, which must panic naming the function;
- three measure mutations (descent removed from `predict`, `build`,
  `showT`), which must be refused.

Its golden files were written by the style versions after the comparison
above. `--examples DIR` runs another copy, which is how the final round of
changes was checked against the previous commit. `tools/sol-library-check.py`
still passes with the new `base`.

## Corrections to the STYLE catalogue

[STYLE](2026-09-01-STYLE.md) is dated and not edited, so these supersede its
repository catalogue:

- Sol does expose `List.take` and `List.drop`. mandel's `takeN`/`dropN` and
  terra's `takeN` are gone.
- `base` has no `takeN`. dash uses `base.pI` and `List.take`.
- bboard uses `base.boolInt`, `base.firstOr` and `base.say`; `List.append` is
  written `+`.

## Checker limits met

These shaped the code. Each is noted where it applies.

- **A measure covers self-recursion only, and a `case` arm cannot hold
  bindings.** dtree's `build` used to go through `tryNode` and `splitNode`.
  To be measured it is one function, so the split is computed before the
  purity test. On a pure node that scan is wasted work, not a wrong answer.
- **Structural measures need the descent in a body `case`.** dtree's
  `predict` lost its pattern-headed clauses. This matches the native finding
  in IDEAL-EXAMPLES.
- **Structural measures on a user ADT work in Sol.** `(t : Tree | measure t)`
  is accepted and enforced: removing the descent is refused.
- **Conjunctions in a contract must be infix:** `k >= 0 and k <= 2`. Prefix
  `and (...) (...)` is "outside the decidable fragment", and `,` is not
  accepted in a contract (it is in a guard).
- **Field access on a parenthesized expression does not parse:**
  `(mk 3).y` is refused; bind it first.
- **Sol checks contracts at run time and ignores resource bounds** (as
  IDEAL-EXAMPLES records), so no `work`/`alloc` bounds were attempted.

## Not done

- No resource bounds (above).
- physics keeps its two `unsafe` integrators.
- The browser payloads are still strings. A typed message sum would make the
  check static, but it depends on the View protocol, not the examples.
- `tools/sol-examples-check.py` is a standalone tool like the other
  `tools/sol-*-check` scripts, not part of `tests/check_base.py`, which covers
  native Base.

## Later the same day: bboard's core logic

A review of the placer found that its output could say OK for a board that
was wrong. `sol/examples/bboard.sol` changed, and its three goldens with it:

- A strip takes at most 3 component pins. Two of its five holes stay free
  for wires, so a jumper or rail wire can no longer find the strip full.
  A wire end that has no hole is never counted as a connection.
- The supply is the first voltage source whose negative node is 0. A
  current source, a second supply, and a supply not referenced to node 0
  are listed under `-- notes --` and not wired to the positive rail, which
  two supplies would have shorted.
- Both pins of a part sit in one column, as the header always said.
- The checks are computed from the placements, the netlist and the wires
  that landed: all parts placed, no strip with two nets, no hole used
  twice, every net's strips joined by its jumpers, ground and the supply
  on their rails. Each can fail; the full-board golden shows two failing.
- Every rail wire end is drawn, and cells widen to the longest label.

Not modelled, and said in the file's header: parts with more than two
pins, a DIP across the centre gap, pin pitch other than two rows, and the
body of a part over the row between its pins.

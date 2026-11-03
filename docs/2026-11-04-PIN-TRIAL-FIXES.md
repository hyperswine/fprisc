# Two fixes from the QOS pin trial

Date: 4 November 2026. Kind: fix record. Base: main `79fdf1f`.
Found by the QOS pin trial (qos branch `fprisc-pin-trial`,
`docs/2026-11-03-FPRISC-PIN-TRIAL.md`), which moved the QOS pin from
1a09f01 to 2d3b9d6 and to 15bad00. Two QOS checks newly failed at both
pins, and both traced to the compiler.

## 1. Typed case tests trusted a type that `receive` cannot promise

**What broke.** [Type-directed case tests](2026-11-02-TYPED-CASE.md) (C1
piece 1, 78000b8) lowered a constructor test on a nominal sum type
(`List`, `Result`, any `Type (...)`) to a check of the variant word at +4
alone, on the grounds that the type checker guarantees the scrutinee is
an object of that type. It does not, for received values: `receive` is
`Int -> a`, typed by its use, and a message of another type arrives
unchanged. std/mvu's port relies on exactly that:

```
portStep me q =
  received = receive me;
  ...
  next = case m of
      PDrain from -> ...
    | PBarrier from -> ...
    | _ -> m :: q;
```

Event tuples such as `("note", ...)` share the port with `PDrain` and
`PBarrier`. A tuple's variant word is 0, which is `PDrain`'s, so the
port answered `from` (a string pointer) and QOS's pathnotes check saw a
dead actor. A received `Int` was worse: the test read memory at the
tagged integer's address.

Repro (prints `other` with the fix and with `FPR_NO_TYPED_CASE=1`; printed
`PA` at 2d3b9d6 and 15bad00):

```
Q = Type (PA Int | PB Int).
main =
  me = myself 0;
  _ = send me ("x", "y");
  m = receive me;
  r = case m of
      PA x -> "PA"
    | PB x -> "PB"
    | _ -> "other";
  print r.
```

**Fix.** `OVariantTest` now takes the type id and gives `OTagTest`'s
answer for every value: an Int is no match, and the type id must match.
What it keeps from piece 1 is a single header load: the type id (+0) and
variant (+4) are compared as one little-endian 64-bit word
(`Codegen.IR.headerWord`), where `OTagTest` loads and branches on each
word separately. RV32 keeps two 32-bit loads.

| `Nil` test in `foldGo`, x86-64 | instructions | internal branches |
|---|---:|---:|
| `OTagTest` (`FPR_NO_TYPED_CASE=1`) | 17 | 3 |
| piece 1 as landed (unsound) | 4 | 0 |
| now | 11 | 1 |

The Int-bit branch is always predicted, so the cost over the unsound
version is a few cycles of straight-line code. Piece 1's own measurement
found no runtime difference on `list_fold`; the size win is smaller than
recorded there. A sound branch-free form needs a readable dummy address
for the Int case on every target and was not worth it here.

Making the variant-only test sound would need the compiler to know which
values can come from a message. That is whole-program provenance through
function arguments and data structures, and separately compiled units
(std/list's `foldGo` can be handed a received list) defeat it.

**Tests.** `tests/check_typed_case.py` adds three received-value cases
(a tuple, an Int, and a tuple against `List`'s constructors), each run
with the pass on and off and required to print `other`, and asserts the
Int check survives in the emitted assembly on x64, a64mac and rv64.
`tests/TypedIR.hs` checks the evaluator agrees with `OTagTest` on an Int
and on another type's object. `codegenRev` 152; selection revisions
`a64` 31, `x64` 30, `rv` 31.

## 2. Interval discharge searched every path

**What broke.** QOS's `tests/guishell.fpr` compiled in about 50 s up to
830fd11 and never finished from bd45ece
([C2 and interval upgrades](2026-11-03-BUILTIN-TYPE-SPEC-AND-INTERVAL.md)),
stuck in `discharge-proven-checks` on guishell's `main` (195 blocks, 78
conditional branches, mostly diamonds). `FPR_NO_INTERVAL=1` avoided it.

**Cause.** `Codegen.Interval` derives bounds from difference facts
`a - b <= c`. Its three searches (`ubWith`, `lbWith` and the `walk` in
`diffUBWith`) enumerated every simple path through the fact graph,
carrying a seen-set per path. Before bd45ece the facts were few and
mostly unrelated. The transitive `diffUB`, the arithmetic step facts and
the join intersection made the graph dense enough that the number of
paths grew exponentially. `closeOnce`, at every join edge, also paired
every fact with every other fact.

**Fix.** The searches are shortest-distance relaxation over the fact
graph (`distances`): from the nodes improved in the last round, until a
fixed point or as many rounds as there are nodes. A walk's sum is a valid
bound whether or not the walk is simple, so the answers are those of the
old search, except where contradictory facts form a negative cycle (an
unreachable block), where every bound is vacuously sound. `closeOnce`
indexes facts by source.

| guishell unit, warm cache | time |
|---|---:|
| `FPR_NO_INTERVAL=1` | 26.2 s |
| interval on, before | killed at 200 s (the trial: still running at 1500 s) |
| interval on, now | 26.1 s |

The pass still discharges checks on guishell (the output is 211 lines
shorter than with it off).

**Tests.** `tests/Interval.hs` adds a ladder: guards `a_i < a_{i+1}`,
`a_i < b_{i+1}`, `b_i < a_{i+1}`, `b_i < b_{i+1}` for 30 rungs, then
`a_0 < b_30`, which holds along 2^30 paths and must thread. The suite
passes in about 6 s; with the old `Interval.hs` it was still running when
killed at 90 s. `tests/check_interval.py` passes.

## QOS re-check

With this tree as `FPRISC_ROOT` (qos main 0bf8bee):

- `./qos.py run tests/pathnotes.fpr` prints the expected
  `pathnotes: OK notes=Third note|Fourth one n=4 cap=2 ...` line.
- `tools/guishell-check.py` (the Main Profile leg) passes all its claims
  in 13 min 23 s, with both passes on.

The full check-all sweep was not re-run.

## Not done

- The trial's other oddity (with `FPR_NO_TYPE_SPEC=1` also set, the
  guishell build stalled in 3 of 4 runs) was not chased separately; the
  interval pass was on in those runs.
- The QOS pin itself is not moved here; that is a QOS change, held for
  the SDK 0.4.0 candidate.

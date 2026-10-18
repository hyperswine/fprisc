# Autodrop: a body that IS the bare `case <receive> of`

Date: 2026-10-19. Kind: compiler fix with measurements. The pass is `autoDrop`
in `compiler/FPRISC.hs`; the gap was found by the ARC table churn session
(docs/2026-10-18-ARC-TABLE-CHURN.md), which left it as a follow-up.

## The gap

Autodrop's shape 5 (`case receive me of ...` as the direct scrutinee) and
shape 5b (`case receiveFromRes me a of Ok m -> ...`) were matched in two
places: as a statement (`k = case receive me of ...; ...`) and as a block's
final expression (`goStmts n [] fin`). `goE`, the entry for a clause body, only
descended into an `SBlock`; any other body was returned untouched. So a
function whose whole body is the case, with no preceding statement, was never
visited:

    ponger self = case receive self of (who, n) -> send who (n + 1) >> ponger self.

That is `tests/bench/pingpong.fpr` and `xpingpong.fpr` verbatim, and also the
prelude's `parWorker` (the fork-join worker behind `par2`). Every message
these received stayed a live Arc entry. The same ponger written as
`m = receive self; case m of ...` got `drop m` and was fine, which is how the
leak went unnoticed: it depended on surface syntax, not on what the function did.

## The fix

`goE` now treats a non-block body exactly as a block's final expression:

    goE n e = case e of
      SBlock ss fin -> ...
      _ -> let (ss', fin', ns) = goStmts n [] e
            in (if null ss' then fin' else SBlock ss' fin', ns)

For a bare shape 5 body this binds the scrutinee to a fresh root
(`_autodrop_root_ponger_0 = receive self`), rewrites the case over that
variable and lands `drop` at each arm's start (shape 2), wrapping the result in
a block. For a bare shape 5b body the `drop m` lands in the Ok arm when every
use of `m` is borrow-shaped, as before. A body that matches neither comes back
unchanged, so no other program's code moves. The change is reported like every
autodrop insertion: `./fpr build -v` now prints

    autodrop: ponger: inserted `drop _autodrop_root_ponger_0` into 1 case arm(s)
    autodrop: parWorker: inserted `drop _autodrop_root_parWorker_0` into 1 case arm(s)

The `parWorker` line is new for every program (it is prelude code): each
`par2` task's request root is now dropped by the worker instead of surviving
until the worker actor is reaped.

## Measured

Both benchmarks, built with `--with tests/arc_churn/arcprobe.c` and the ARC
gauges printed after the result; before = the compiler at 3e44148 in the main
checkout, after = this branch. One run each; `maximum resident set size` from
`/usr/bin/time -l`, xpingpong on `FPR_HARTS=4`.

| program | compiler | arc_cap | arc_grows | arc_hwm | arc_live at exit | resident |
|---|---|---|---|---|---|---|
| pingpong | before | 2,097,152 | 11 | 1,000,000 | 1,000,000 | 101.5 MB |
| pingpong | after | 1,024 | 0 | 1 | 0 | 3.75 MB |
| xpingpong (4 harts) | before | 2,097,152 | 11 | 1,000,000 | 1,000,000 | 101.4 MB |
| xpingpong (4 harts) | after | 1,024 | 0 | 1 | 0 | 3.65 MB |

The table never grows: with one entry live at a time the churn stays inside
the 1,024-slot start (the compaction rule of the 2026-10-18 page).

## Benchmarks

`python3 tools/bench.py pingpong` and `FPR_HARTS=4 python3 tools/bench.py
xpingpong`, fastest of 7 and of 15 runs, on a machine whose load average sat
between 3.6 and 12.7 (other sessions were building):

| benchmark | fastest, before (2026-10-18 page, 3e44148 + this branch's runtime) | fastest, after (7 runs) | fastest, after (15 runs) |
|---|---|---|---|
| pingpong | 447 to 449 ms | 500.8 and 785.8 ms (two invocations) | 691.6 ms |
| xpingpong, 4 harts | 1,062 to 1,068 ms | 1,054.6 ms | 1,046.0 ms |

xpingpong is unchanged. pingpong's fastest run moved by 250 ms between two
invocations minutes apart, with medians of 697 and 937 ms, so the spread is the
host's load, not the inserted drop; the 2026-10-18 page measured the ponger
with a manual `drop` (pp-drop) at the same time as without one. Both
benchmarks were already 2.65x and 4.2x over `bench/baseline.json` before this
change (the baseline is stale for other reasons, see that page), and the
ratchet still reports them SLOWER; the baseline was not re-recorded here. A
quiet-machine rerun of pingpong is the one measurement this page owes.

## Regression test

`tests/base/autodrop3.fpr` (run by `tests/check_base.py`) has both bare shapes:
the bench ponger verbatim driving 100,000 round trips, and `takeRes`, whose
whole body is `case receiveFromRes me w of Ok m -> ... | Err e -> 0`, driving
1,000 spawned workers. The check asserts the two `-v` notes and, through the
`arcprobe.c` gauges, `arc_live = 0` at exit on one and four harts. Before the
fix the same program ends with 101,000 live entries.

## Not covered

- Only the clause body is visited. A bare `case receive ...` nested inside an
  arm, a lambda or an `if` branch is still not an autodrop site, the same as
  before this page; a receive there needs the manual `drop`, and the law's
  audit (docs/2026-08-25-MEMORY.md) still applies.
- `bench/baseline.json` was not re-recorded, and pingpong was not timed on a quiet machine; see the benchmark section.

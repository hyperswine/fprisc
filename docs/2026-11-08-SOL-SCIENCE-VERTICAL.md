# Sol science vertical: CSV -> Matrix -> robust fit -> mixed-series chart

Date: 2026-11-08.
Kind: delivery record for the measured end-to-end workflow that defines the
"Python for data" story proposed after the daily-scripting roadmap
completed. The [library-module cache](2026-10-29-SOL-INCREMENTAL-PRELUDE.md)
named as the next step had already landed (verified separately); this is
the next item.
Host: macOS arm64 (darwin 27.2.0), GHC 9.8.2.

## What the vertical is

`sol/examples/csvplot.sol` — the notebook shape in one script transaction:

1. Generate 40 weeks of sensor readings (seeded LCG `rand.sol`; exact ints;
   every 13th week +150) and write them through `Matrix.toCsvHeader` as a
   transactional CSV.
2. Read the CSV back (`fromCsvHeader`), extract the (week, reading) column
   pairs (`mapRows`).
3. Least-squares fit by one exact-int fold and one division; an iterated
   3-sigma outlier rule (fit -> mark -> drop, until stable); refit on the
   survivors.
4. Chart data, both fit lines and the rejected points in ONE SVG via the
   new `P.chart`, written transactionally beside the CSV.

Measured end to end: **98 ms** wall on this host (generation, CSV round
trip, two fits, robust classification, SVG render) — interactive-prototyping
fast. `tools/sol-science-check.py` (registered in Base) replicates the LCG
and the arithmetic in Python and asserts the printed statistics EXACTLY
(the naive left fold is replicated explicitly: Python's builtin `sum` is
Neumaier-compensated since 3.12 and differs from `List.fold` in the last
ulp), the CSV bytes, and the SVG structure (2 polylines, 40 markers, 4
legend entries).

The output tells the story the workflow is for: the all-data fit reports
slope 3.470 (dragged from the true 3.0), the clean fit recovers
y = 12.206 + 3.0005 x with sigma 3.09 against injected anomalies at weeks
[12, 25, 38].

## Library gap filled: P.chart (mixed-series chart)

`P.line`/`P.scatter` each render a one-series SVG and only same-shape
`P.series` combined several — a scatter-plus-fit-lines chart, the shape
every data workflow wants, could not be assembled. New:

```sol
# each spec: (title, asLine, pts); slot colors follow the fixed palette
# across kinds; axes span the union; legend lists every series
svg = P.chart "weekly sensor" [
    ("readings", False, pts), ("fit (all data)", True, la),
    ("rejected", False, bad), ("fit (clean)", True, lc)].
```

Specs are plain tuples with polymorphic points, matching the existing
library idiom — a tagged-constructor design was tried first and is the
wrong fit here: `Numeric` is not a type name (the inexact type is `F64`),
and floats inside containers hit the render restriction, so a
`Series = Type (SLine ...)` payload cannot say what it holds. While wiring
it, `chartBounds` also replaced the direct `ptsBounds`/`allBounds` calls,
which panicked on an empty series; `P.line`/`P.series`/`P.scatter`/`P.chart`
now render empty series as contributing nothing instead. plotdemo's five
committed SVGs are byte-identical after the change.

## Language findings from writing the vertical

Each of these cost a compile cycle; they are recorded so the next library
author does not pay them again:

- **Eval binds do not persist across `>` evals.** `txn_iso.sol`'s cross-eval
  `d` is a top-level definition, not an eval binding. A multi-stage
  workflow is one eval chain (which also makes it ONE transaction).
- **Spliced constructors cannot be pattern-matched** — qualified patterns
  are a parse error ("expected simple lowercase identifier") and bare names
  do not resolve ("unknown constructor"). Module Types work in expression
  position (`CLI.Option`); case analysis on them does not. Same-module
  patterns work. This is a real composability gap for the
  "modern, composable" goal; a qualified-pattern parser fix is the open item.
- **Lambdas take no `_`** (`fn x -> ...` only; `fn _ ->` is a parse error),
  and fold argument order is `f acc x` with the ACC first.
- **A bare effect cannot precede `;`** — every mid-chain statement binds
  (`p1 = print ...`), matching SEMANTICS.md §1.
- **`@path` literals are bare paths**, no quotes or interpolation.
- **`Numeric` is not a type name** in `Type` declarations (see above);
  `Int`/`String` and lowercase variables are.

## Battery

| Check | Result |
| --- | --- |
| `tools/sol-science-check.py` (new) | OK, exact statistics |
| `tools/sol-output-check.py` | 26 checks passed |
| `tools/sol-library-check.py` | 127 checks passed |
| `tools/sol-examples-check.py` | 21 checks passed |
| `tools/sol-fs-check.py` | 103 checks passed |
| `tools/sol-repl-check.py` | 11 checks passed |
| `tools/sol-io-check.py` | 84 checks passed |
| `tools/sol-library-cache-check.py` | PASS (347 differential cases) |
| `tools/sol-txn-check.sh` / `sol-safety-check.sh` / `sol-scripts-check.sh` | OK |
| `tools/sol-effects-check.py` | Both legs PASS |

plotdemo SVGs byte-identical (checked by git diff after a rerun).

## Remaining limits

- One vertical is one vertical: matrices are 2-D, there is no broadcasting
  or N-D array API, no median/sort in the prelude (which a MAD-based robust
  scale would need — the contamination-fraction limit of plain 3-sigma is
  documented in the example), and plots are still SVG-text only (no PNG).
- The suite asserts exact float strings; a renderer change that preserves
  values but not digits will need the expectations regenerated.
- Hosted CI remains the standing gap from the milestone records.

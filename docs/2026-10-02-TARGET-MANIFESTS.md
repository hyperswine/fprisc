# Target manifests: from ops to time, under stated assumptions

Date: 2026-10-02. Kind: implementation record. Stage 3 of
[2026-10-02-RESOURCE-BOUNDS.md](2026-10-02-RESOURCE-BOUNDS.md).

```
fpr build --manifest=manifests/pi4-qos-v2.fprt prog.fpr
```

A manifest is a small text file, one key per line, naming the three
versions a judgement is made against and binding what the program cannot
know about its target:

```
name        pi4-qos-v2
compiler    edfbaac
runtime     3c02b82
hardware    "Raspberry Pi 4, 1.5 GHz, one hart"
ns_per_op   1.3                      # worst-case nanoseconds per abstract op
coefficient omega 12                 # a named coefficient a bound may use
primitive   print 2000 0             # a primitive's work and alloc bytes
budget      main 5ms                 # a function's time budget
assume      "no cache model; single hart; no interrupts"
```

[`Manifest.hs`](../compiler/Manifest.hs) reads it; a malformed line is an
error naming the line. Nothing in a manifest is measured by the compiler. It
is a document someone signs, and the report prints its name and assumptions
beside every number it produces.

## What the manifest does

- **Prices primitives.** `primitive print 2000 0` turns `ω(print)` into 2000
  ops in every derived cost before any check, so a declared bound over a
  function that prints can be judged, and the judgement is only as good as
  that line.
- **Binds coefficients.** A bound may say `work count <= omega * n + 5`.
  Without a manifest that is a compile error naming `omega`; with
  `coefficient omega 5` it is checked as `5·n + 5`, and with `omega 4` it is
  `OVER (n: derived 5, declared 4)`. The program states the shape, the
  target states the number.
- **Judges budgets.** For each root function the report prints its work; a
  function whose work closes to a number gets a time, `ops × ns_per_op`, and
  if the manifest budgets it, a verdict:

```
target host-test: compiler edfbaac, runtime -, the development host; 1.3 ns/op
assumptions: single hart, no cache model, no interrupts
  double    work 1 ops → 1.3 ns
  main      work 2292 ops → 2.98 µs   PROVEN within budget 5 µs
  total     work <= 19·(len xs + 1) + 8   (parametric; × 1.3 ns)
```

  A budgeted function whose work is still parametric is `UNPROVED against
  budget` with the advice to bound its parameters; one that still depends on
  an ω names it. `OVER` and `UNPROVED` against a budget are compile errors,
  so the build is the gate: the ratchet script is no longer the only one.

## What it deliberately leaves out

Time per allocation is not modelled separately: an allocation is one op
like any other, and `ns_per_op` has to be chosen as a worst case over the op
classes the program uses. Cache effects, other harts and interrupts are
exactly what `assume` lines are for. A parametric bound is reported with its
factor, not multiplied through: `(5·(n + 1)) × 1.3 ns` is more honest than a
rational coefficient the reader has to undo. `alloc` has no budget yet;
stage 4 gives it one in terms of live memory.

`--manifest=` implies `--cost`. The spelling is `--manifest`, not
`--target`, because `--target=` already names the ISA.

## Tests

`tests/check_cost.py` with `tests/manifests/host.fprt` (placeholder
figures, not measurements): the pipeline's `main` is 2292 ops, 2.98 µs,
PROVEN within 5 µs and OVER against the 1 µs of `host-tight.fprt`;
`bound_coef.fpr` is refused without a manifest, PROVEN with `omega 5` and
OVER with `omega 4`; a manifest with `ns_per_op fast` is refused naming the
line.

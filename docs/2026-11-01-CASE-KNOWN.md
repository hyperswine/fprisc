# Case of known constructor in typed Core (A1)

Date: 1 November 2026. Status: implemented; enabled by default for native
compilation, roll back with `FPR_NO_CASE_KNOWN=1`. This lands A1 from
[the zero-overhead proposal](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md).
No representation, ABI or language change.

## What it does

`Core.Typed.CaseKnown` is a per-function typed-core pass over closed programs.
Closure conversion lowers `case e of ...` to
`let s = e in match-tail s alternatives`, with `s` a fresh binder used only as
that scrutinee. After inlining, `e` often ends in a constructor, for example an
inlined `half x = if ... then Some (x / 2) else None`. The pass pushes the
alternatives into the leaves of `e` (through `let`, sequence, `if` and nested
match tails) and, at each leaf that is a constructor application, tuple or
nullary constructor, selects the first matching alternative statically. Fields
are bound by `let` in field order, so the constructed value never exists:

```
case (if c then Some (x / 2) else None) of Some y -> A | None -> B
==>
if c then (let y = x / 2 in A) else B
```

Evaluation and trap order are kept: field expressions are evaluated by the same
bindings, in the same order, before the chosen alternative; a field matched by
a wildcard is still evaluated (as a sequence) if it is not a trivial value.

## When it declines

The case is left untouched, never partly rewritten, when:

- any leaf of the scrutinee is not a known constructor (a call, a variable);
- a selected pattern is nested (`Some 3`), or the case has guards;
- two leaves would select the same alternative. Alternatives are moved, never
  copied, because typed-core verification requires unique binder identities.
  A join point for the shared alternative is a follow-up;
- no alternative matches a leaf (the fallback is a runtime failure).

A top-level variable pattern (`v -> ...`) rebinds the whole value, so the
value is still built; that case is correct but gains nothing.

## Placement

After callback specialization and inlining, before vector reads, normalization
and vector fusion (`Compile.hs`). Only definitions the pass rewrites enter the
existing verification and erasure path. The flag is part of the build-cache
identity (`-nocaseknown`).

## Evidence

- `tests/check_case_known.py` (registered with the Base checks): output,
  exit code and stderr are identical with the pass on and off for a set of
  programs (Option, wildcard, whole-value bind, nested pattern, shared
  alternative, tuple, trap order); allocator requests are pinned per program;
  the emitted code differs between modes.
- Gate, `tests/bench/unbox/option_loop.fpr` (20 M iterations): allocator
  requests 10,004,885 -> 2 (the remainder is runtime start-up).
- Time, median of 9 interleaved runs, whole process: `option_loop` 98.7 ms ->
  63.5 ms (1.55x). The proposal's 10-20x estimate assumed C's 8 ms; what is
  left is the loop's checked arithmetic, one `$fuel` tick per call and the
  ordinary start-up, which are separate follow-ups (one tick per loop
  iteration). `tuple_loop` and `tree_sum` are unchanged: their scrutinee is a
  parameter, so scalar replacement across the call (A2) is what they need.

- Differential sweep over `tests/`, `tests/bench/unbox/`, `examples/` and
  `examples/ideal/` with the pass on and off: 101 buildable programs identical
  in exit code, stdout and stderr (one `elapsed_us` timing line differs); 40
  fail to build identically in both modes (device targets). The Base suite
  passes except `tests/check_compile_budget.py`, which already failed before
  this change; the pass adds about 5 MB to `hello`'s compile peak residency
  (38 -> 43 MB) and under 1% allocation.

## Follow-ups

- Join points (or renamed copies) for alternatives selected by several leaves,
  such as two `Some` returns of one helper.
- Nested patterns and guards.
- A2: scalar replacement of loop-carried tuples and records.

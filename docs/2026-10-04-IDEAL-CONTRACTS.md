# Ideal examples: ownership, preconditions and measured replay

Date: 2026-10-04. Kind: implementation record. Compiler base revision:
`da365684309cebb36c8236c7ddb3855c95339f1f`, codegen 34. Adds to
[ideal examples](2026-10-02-IDEAL-EXAMPLES.md).

Two additional style rewrites make the language's constraints visible in normal
code, rather than only in deliberately broken compiler fixtures:

- `examples/ideal/buffer.fpr` rewrites `tests/linpap.fpr` with an explicit
  application linear carrier, `Samples 1`, named read/edit ownership transfers,
  measured bounded construction, element-count/index preconditions, explicit
  release, and a vector map/filter/fold compute pipeline.
- `examples/ideal/transitions.fpr` rewrites `tests/precond.fpr` with one clause
  per event, guards proving internal positive-amount preconditions, measured
  event replay, and eight proven work/allocation declarations. Invalid events
  leave the model unchanged; broken internal invariants carry runtime blame.

The buffer reproduces `linpap: x=5 y=10 z=108`. The transition example reports
`amount=75,7 hist=5 avg=30,0`. The expanded ideal suite compares every transition
with the original and independent arithmetic, and checks vector computation at
empty/singleton/larger sizes with negative, zero and positive multipliers.

Negative tests deliberately violate the count/index/amount contracts, reuse or
alias an owner, remove both recursive descents, and understate replay work.
Each must fail for the corresponding contract, linearity, measure or bound.
The complete eight-example suite joins `tests/check_base.py`.

## Boundaries exposed

Structural descent still uses a small body case; pattern-headed recursive
clauses are not yet supported by the measure checker. The buffer's count
contract lives at construction's boundary, keeping checks out of the recursive
loop. Vector primitives contribute opaque costs, so the buffer claims measured
termination and ownership, not a proven complete memory or time budget.
Index lower bounds are contracts; actual vector length remains a runtime bound.

The transition core proves abstract work and allocation bounds; printing and
the dynamic bump wrapper remain opaque. Contracts do not prove integer
arithmetic free from overflow. None of these examples claims producer
certification, native-code isolation or hardware WCET.

## Verification

The expanded `python3 examples/ideal/check.py` suite passed on macOS arm64,
including all eight builds, proven declared bounds, original application
comparisons, localhost HTTP checks and the added refusal tests. The final named
vector callbacks passed the same suite. Python syntax checks and Git whitespace
checks also passed. The complete Base suite was not rerun in this example-only
slice; its new entry invokes the independently executed ideal suite.

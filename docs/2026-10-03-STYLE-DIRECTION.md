# The intended style, and shifting the tree towards it

Date: 2026-10-03. Kind: position and plan. Applies from revision `b269247`.
Builds on [2026-09-01-STYLE.md](2026-09-01-STYLE.md) (source conventions),
[2026-10-02-IDEAL-EXAMPLES.md](2026-10-02-IDEAL-EXAMPLES.md) and
`examples/ideal/README.md` (the style demonstrated on complete programs),
and [2026-10-02-RESOURCE-BOUNDS.md](2026-10-02-RESOURCE-BOUNDS.md) (one
measure language, the cost pass, bounds in signatures).

## Why this page

Preconditions, measures, resource bounds and guarded clauses were core to the
original idea of the language: a small, clean functional language in the
SML/Elm family where most of a typical program is function clauses, guards,
contracts and `|>` pipelines rather than deeply nested code.

In practice most of the tree was written to make each example or module work,
not to use those features. The checkers have therefore been exercised mainly by
their own fixtures, and their rough edges were found late. `examples/ideal/`
showed on six complete programs that the style holds up and where it still
chafes. This page makes that the default direction: new code is written in the
style, existing code gains style versions, and what the checkers cannot follow
becomes the compiler's work queue.

## What the style is

It is not a separate paradigm. It is a presentation of ordinary functional
programs plus an optional layer of constraints.

**The syntactic half** applies to any program that is a set of functions:

- clauses select by the shape of the input (one clause per event, message or
  result constructor);
- guards state when a clause applies -- pattern matching and `if` made
  legible;
- pipelines (`|>`) show data flow left to right; they are composition and
  currying, nothing more;
- functions are named for domain meaning, per 2026-09-01-STYLE.

**The constraint half** is where the language says more than other functional
languages do:

- value preconditions on parameters, `(n : Int | n >= 1)`, for internal
  invariants;
- `measure` on recursion that terminates, instead of `unsafe`;
- `work`, `alloc` and `size` bounds on pure cores, checked during native
  compilation;
- `Result` at every external boundary. A precondition violation is a
  programming error with named blame; it is not how ordinary user input is
  rejected.

The constraint half is gradual. Code without it is plain functions and still
compiles. The aim is not that every line carries a contract; it is that the
places where contracts matter carry them, and that the checkers prove most of
them statically.

### Where the constraints pay off, and where they do not

They pay off most in discrete, integer-heavy code with clear invariants: data
transformation, validation, protocols and state machines, MVU `update`,
routing decisions, ledger rules, std containers.

They pay off least in I/O glue, in float-heavy numeric and graphics code (the
predicate fragment is integer-only), and wherever correctness lives in the
outside world rather than in values. Those places use the syntactic half and
`Result`, and leave the rest.

### Mutation and boundaries

Imperative code with local mutation is often the easiest way to write a driver
or to fix a problem in place. The style accommodates it with one rule:

> Mutation is fine wherever it cannot be observed. The moment it becomes
> observable, it becomes a message or a commit.

The tree already follows this in three places: a linear `Vec` is mutated in
place because nothing else can see it; an actor's loop state changes every
iteration behind its mailbox; a Sol script mutates freely and the world sees
one commit. So the style is required at boundaries -- between actors, at
module interfaces, at commit points -- not inside every function. A driver is
an actor that pokes registers imperatively inside and exposes messages with
preconditions outside; a hot loop can live in the builtin profile.

### Seams for cross-cutting changes

The imperative way to add a cross-cutting concern (logging, a compatibility
shim, a new feature that touches many paths) is to patch every site. The
style's way is a seam: one place everything already flows through, where a
layer wraps a function. MVU's single `update`, a supervisor, implicit ops
records and a default `LiveReload` handler are seams. The cost of the style is
designing seams up front; MVU is the default program shape partly because it
provides the main seam for free.

## The shift

From this revision:

1. **New std modules and examples are written in the style by default.**
   Contracts on internal APIs, `Result` at external input, measures instead of
   `unsafe` wherever recursion terminates, bounds on pure cores.
2. **Existing programs gain style versions alongside the originals**, as
   `examples/ideal/` did, with a check that compares behavior. The original
   stays as the reference until the style version is at parity.
3. **What the checkers cannot follow is recorded, not worked around
   silently.** Each workaround in a style version (a wrapper to avoid an
   inserted check, a `case` kept instead of a pattern-headed clause) is noted
   next to it and listed below, so it becomes compiler work.

### Next targets

In rough order of how well each fits the style and how much it would exercise
the checkers:

- **std containers and parsers**: `std/map`, `std/set`, `std/json`,
  `std/kvlog`. Measured traversals, size bounds on producers, contracts on
  indices and counts. Every program depends on these, so bounds proved here
  compose everywhere else.
- **A routing decision core** (the planned router's `route`): a few clauses,
  guards, a precondition on prefix length, a pure decision function with a
  small constant work bound. Nearly an ideal specimen.
- **POS ledger rules and the Logbook update**: the larger live-browser
  comparisons that `examples/ideal/README.md` names as future work.
- **QOS services' `update` functions**: message clauses with preconditions on
  their payloads, once the typed endpoint protocol settles their message
  shapes.

### Measuring the shift

`examples/ideal/check.py` joins the regular suite. For each style program the
suite records, as a ratchet next to `bench/baseline.json`:

- obligations discharged statically versus runtime-checked;
- functions still marked `unsafe`, and recursive functions with a verified
  measure;
- pure functions with proven `work`/`alloc`/`size` bounds versus those whose
  cost is opaque.

These numbers should only move in one direction. A regression points at a
specific checker weakness or a specific piece of code.

## Known friction to drive compiler work

From `examples/ideal/`:

- Structural measures need the measured parameter to stay a plain variable,
  with descent in a body `case`; the pattern-headed clause
  `lsum (x :: rest) acc = ...` is refused.
- Recursive value contracts are not always discharged from fallthrough facts:
  a loop with `n >= 0` and `measure n` got a runtime check at its recursive
  call, which made its work cost opaque. The examples wrap the measured loop
  in a contracted boundary instead.

From the 2026-09-30 discussions of the precondition pass; each needs a test
against the current tree before it is treated as confirmed:

- Arithmetic in arguments: with the fact `n > 0`, the obligation
  `n - 1 >= 0` is neither a bare variable comparison nor a constant, so it is
  runtime-checked. Moving constants across the comparison before matching
  would discharge most recursive calls.
- Upward propagation: an undischarged obligation becomes a runtime check at
  its call site; it is never lifted into the enclosing function's contract.
  Inferring contracts callee-first, stopping at exported functions, handlers,
  `main` and first-class uses, would move checks to the edges where values
  enter.
- First-class uses: checks are inserted where a contracted function is applied
  by name. Passed as a value (`List.map validate xs`) or partially applied, its
  contract may not run. Pipelines lean heavily on passing functions, so this
  matters most for the style itself.
- Results carry no facts: there are no postconditions in the native pass, so
  `max 1 x` is not known to be positive afterwards. Refined result types would
  let facts flow out of calls as well as into them.

## Tooling as the view

Because the style is a view of ordinary functions, tooling can show much of it
for code that was not written in it: inferred contracts, measures found for
recursion that already terminates, and proven bounds, as editor annotations
and in the obligation report. Writing a constraint explicitly then pins it
down rather than being the only way to get it. A useful side effect: the
places where the checker cannot follow the code are usually where a reader
struggles too, so checker failures double as legibility feedback.

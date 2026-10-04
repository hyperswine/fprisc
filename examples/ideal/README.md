# Writing FP-RISC in the intended style

Eight working programs exploring the language as small functions, clauses,
guards, preconditions, measures and left-to-right pipelines. Four rewrite
complete applications; four rewrite existing contract, ownership and cost fixtures.
The originals remain available as behavioral references.

| Program | Reference | What the rewrite demonstrates |
|---|---|---|
| [wc.fpr](wc.fpr) | [wc](../wc.fpr) | A Result boundary, a pure counting pipeline, and a positive-width formatting contract |
| [report.fpr](report.fpr) | [report](../report.fpr) | Named transformations, grouping/sorting pipelines, clause-based option/result handling, nonnegative byte quantities |
| [todo.fpr](todo.fpr) | [todo](../todo.fpr) | One clause per event, guarded transitions, pure command-producing updates, a bounded selection function and measured UTF-8 backspace |
| [service.fpr](service.fpr) | [service](../service.fpr) | Routes expressed as clauses and guards, Result-based configuration validation, a worker-count contract and bounded concurrent digests |
| [measure.fpr](measure.fpr) | [measure fixture](../../tests/measure.fpr) | Verified recursion, a checked factorial boundary, work/allocation bounds, and an allocating traversal with a live-memory bound |
| [buffer.fpr](buffer.fpr) | [linear ownership fixture](../../tests/linpap.fpr) | Explicit `Samples 1`, single-owner read/edit pipelines, measured construction and vector map/filter/fold |
| [transitions.fpr](transitions.fpr) | [precondition fixture](../../tests/precond.fpr) | Message clauses, guards discharging contracts, measured replay and proven work/allocation bounds |
| [pipeline.fpr](pipeline.fpr) | [pipeline fixture](../../tests/cases/bound_pipeline.fpr) | A range/map/sum pipeline whose work bound composes through std/list |

## Run them

From the repository root:

```sh
./fpr run examples/ideal/wc.fpr examples/wc.fpr
./fpr run examples/ideal/report.fpr examples /tmp/ideal-report.json
./fpr run examples/ideal/todo.fpr /tmp/ideal-todo.json
./fpr run examples/ideal/service.fpr --port=8080 --workers=2
./fpr run examples/ideal/measure.fpr
./fpr run examples/ideal/pipeline.fpr
./fpr run examples/ideal/buffer.fpr
./fpr run examples/ideal/transitions.fpr
```

Todo uses the same keys and JSON format as the original. Service exposes the
same endpoints, configuration file and environment variables. Report writes
the same document, with the current timestamp. The measure fixture originally
returned a string from `main`; its script version prints that result explicitly.

## The style, concretely

The event or request selects the clause; a guard states when it applies;
a pipeline shows the transformation:

```fpr
update (Term.Key Term.Delete) m =
  {m | items = removeAt m.at m.items} |> clampAt |> changed.

removeAt at items =
  items |> List.indexed |> List.filter (notSelected at) |> List.map itemOf.
```

External input stays fallible. `validWorkers 0` returns `Err`, so configuration
errors produce a useful CLI message. After validation, the internal API states
its invariant:

```fpr
digests : (workers : Int | workers >= 1) -> String
  -> {status : Int, headers : List (String, String), body : String} .
```

A precondition violation is a programming error with named blame. It is not
the mechanism for rejecting ordinary user input.

The pure numerical cores also promise resources:

```fpr
fact : (n : Int | n >= 0) -> Int -> Int
  | work fact <= 5 * n + 6 | alloc fact <= 0 .
fact n acc = factGo n acc.

factGo : (n : Int | measure n) -> Int -> Int
  | work factGo <= 5 * n + 5 | alloc factGo <= 0 .
factGo n acc | n <= 0 = acc.
factGo n acc = factGo (n - 1) (acc * n).
```

The boundary contract avoids inserting repeated checks into the measured loop.
These are termination and resource guarantees; they do not prove absence of
integer overflow or correctness of the factorial result for arbitrary inputs.

## Check behavior and the guarantees

```sh
python3 examples/ideal/check.py
./fpr build --cost examples/ideal/measure.fpr -o /tmp/ideal-measure
./fpr build --cost examples/ideal/pipeline.fpr -o /tmp/ideal-pipeline
./fpr build --manifest=tests/manifests/host.fprt examples/ideal/pipeline.fpr -o /tmp/ideal-pipeline
```

`check.py` builds all eight programs in a temporary workspace and compares:

- wc stdout/stderr against the original for empty, Unicode, CRLF and missing inputs;
- report JSON and console output, excluding the timestamp and elapsed time,
  plus missing-directory, write and usage failures;
- Todo models, command kinds and rendered rows throughout an event trace,
  plus Unicode backspace, save success/failure and corrupt JSON;
- live service HTTP responses, store ownership, digest results, shutdown and
  invalid configuration against the original;
- the numerical outputs against the original fixtures;
- five deliberately violated contracts, a nondecreasing measure and an
  insufficient work bound. Each must fail.

The suite uses temporary localhost listeners; environments that prohibit
listening need permission to run that part. It cleans up its processes and
files. It checks Todo's pure update/view and executes save commands; it does
not drive an interactive terminal session.

## What this establishes, and the remaining limits

The application structure needs no module-wide `unsafe base` escape. Imported
standard-library effects still rely on the compiler's explicit trust policy;
the examples do not certify the runtime, actor protocols or library runners.

Native compilation proves the resource declarations in measure, pipeline and
Todo's selection function. The I/O programs do not claim whole-program WCET:
printing, networking and library callbacks still contribute opaque costs.
`host.fprt` supplies placeholder prices under stated assumptions, so its time
verdict is a demonstration, not a hardware measurement.

The map/sum pipeline relies on std/list's declared result sizes, which the
current pass labels as assumptions. Live bounds count pool cell bytes under
the current allocation model; they are not an entire process RSS/stack bound.
Sol shares value preconditions and measures but currently ignores resource
bounds; these examples and their verification target native Base.

Two rough edges surfaced while writing these:

- Structural measures currently require the measured parameter to remain a
  plain variable and its descent to occur in a body `case`. The equivalent
  `lsum (x :: rest) acc = ...` clause is refused. The two list traversals keep
  one small `case` rather than adding an unsafe marker.
- Recursive value contracts are not always discharged from fallthrough facts.
  A factorial loop with both `n >= 0` and `measure n` inserted a runtime check
  at the recursive call, making its work cost opaque. A contracted boundary
  around the measured loop closes the bound without hiding that limitation.

The larger live-browser examples (logbook and POS) remain future comparisons.
These eight establish the style on complete smaller programs and expose the
places where the compiler or libraries still make it awkward.

## Ownership and contracts together (2026-10-04)

`buffer.fpr` uses an application-specific linear type:

```fpr
Samples 1 = Type (Samples (Vector Int)).

adjust : (i : Int | i >= 0) -> Int -> Samples -> Samples.
```

A read returns `(value, successorOwner)`; the old binding cannot be reused.
`finish` frees the vector explicitly. The compute path is also an ownership
pipeline, exercised for empty, singleton and larger inputs:

```fpr
build 10 |> evenOnly |> scale 3 |> total
```

This computes 90 using Vector map/filter/fold. It does not imply those operations
fuse or provide a whole-pipeline memory/WCET bound. The element-count contract
is `0 <= n <= 4096`; index contracts state the lower bound, while Vec.get still
checks the actual upper bound. Custom `1` types and `Vector a` are linear without
adding a special arrow notation to each signature. Automatic cleanup remains
available in the language; this example shows explicit ownership completion.

`transitions.fpr` keeps invalid event payloads at a fallible/guarded input
boundary. Positive increments/decrements call contracted internal functions;
the guards discharge their obligations. Event replay has a structural measure
and proven bounds `work <= 31 * len events + 31` and
`alloc <= 48 * len events + 48`. These bounds concern the abstract compiler cost
model, not elapsed time, and the contracts do not prove integer overflow absent.

The suite compares both rewrites with their original fixtures and independent
references. It checks vector arithmetic, every state transition, invalid events,
contract blame, owner reuse and aliasing, nondecreasing construction/replay, and
an insufficient replay bound. `tests/check_base.py` now runs this suite so these
examples remain exercised alongside compiler regressions.

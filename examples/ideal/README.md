# Writing FP-RISC in the intended style

Six working programs exploring the language as small functions, clauses,
guards, preconditions, measures and left-to-right pipelines. Four rewrite
complete applications; two rewrite the existing measure and cost fixtures.
The originals remain available as behavioral references.

| Program | Reference | What the rewrite demonstrates |
|---|---|---|
| [wc.fpr](wc.fpr) | [wc](../wc.fpr) | A Result boundary, a pure counting pipeline, and a positive-width formatting contract |
| [report.fpr](report.fpr) | [report](../report.fpr) | Named transformations, grouping/sorting pipelines, clause-based option/result handling, nonnegative byte quantities |
| [todo.fpr](todo.fpr) | [todo](../todo.fpr) | One clause per event, guarded transitions, pure command-producing updates, a bounded selection function and measured UTF-8 backspace |
| [service.fpr](service.fpr) | [service](../service.fpr) | Routes expressed as clauses and guards, Result-based configuration validation, a worker-count contract and bounded concurrent digests |
| [measure.fpr](measure.fpr) | [measure fixture](../../tests/measure.fpr) | Verified recursion, a checked factorial boundary, work/allocation bounds, and an allocating traversal with a live-memory bound |
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

`check.py` builds all six programs in a temporary workspace and compares:

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
These six establish the style on complete smaller programs and expose the
places where the compiler or libraries still make it awkward.

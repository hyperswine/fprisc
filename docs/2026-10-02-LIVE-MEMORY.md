# Live memory and persistent loops

Date: 2026-10-02. Kind: implementation record. Stage 4 of
[2026-10-02-RESOURCE-BOUNDS.md](2026-10-02-RESOURCE-BOUNDS.md), the part
that follows from the runtime's actual memory model; the rest is listed
under "not done" below.

## The model the numbers follow

An actor's pool is reclaimed when the actor dies or at an explicit boundary
(`Sys.poolReset`, `Sys.arena`, a `Sys.loopWith` step). Nothing else frees.
So for a function, `live` is `alloc`: every byte it asks for is resident
until a boundary the function itself does not own. The report prints `live`
only where it differs from `alloc` or is declared, because printing an equal
number everywhere would be noise.

Where it differs:

- **`Sys.arena g`**: g's allocations are torn down with the arena. The
  caller's pool receives the closure cell (24 bytes) and a copy of the
  result, whose size the pass does not know (`ω(?len)`). `live` during the
  call is g's allocation plus those two; `alloc` to the caller is only
  those two. The arena is how a bounded `live` is bought for unbounded
  scratch work.
- **`Sys.loopWith v s step`**: a persistent loop. Its total work is not
  bounded by anything in the program (it runs until the step says stop), so
  the function's work is the opaque `ω(loop:Sys.loopWith)`. What is bounded
  is one step, and the report says so on its own line:

  ```
  run       work  <= ω(loop:Sys.loopWith) + ω(heapUsed) + …
            live  <= ω(?len)·2 + <one step's alloc> bytes
            per step (Sys.loopWith): work <= …, alloc <= … bytes
  ```

  `live` is one step's allocation plus the state, held at most twice during
  the hand-over, as `docs/2026-10-01-LOOPWITH.md` describes.

`| live f <= e` is a fourth declarable bound, checked like `work` and
`alloc`, part of the committed interface, and substituted by callers.

## Not done, and why

- **Linear data is not credited.** A consumed `Vector` or `Handle` is dead
  at its consuming use, but its bytes live in the runtime, not in Core
  cells, so the pass has nothing to subtract. When vector primitives carry
  declared `alloc`, linearity can credit them back.
- **`Sys.poolReset` is a side effect at a point**, used by `std/mvu` at the
  frame boundary. Modelling it means knowing which allocations happened
  before it on every path. The arena primitives are the structured version
  and are modelled; a program that wants a provable `live` should use them.
- **Record-field sizes** are known by position (`len m.#2`), not name, so a
  resident bound on an MVU model is written over parameters, not fields.
- **MVU per-turn budgets** fall out of what exists: declare `work`/`alloc`
  bounds on `update`, `view` and `subs`, and a manifest budgets them as root
  functions. What is missing is the runner's own contract (`std/term`'s
  `loop` and `std/mvu`'s frame loop are `unsafe` recursion), which would let
  `main`'s row read "per frame: work update + work view + c". That needs the
  runner to declare its per-turn cost in terms of its callbacks, which the
  bound language can express (`work step`) once the runner is written with
  named function parameters rather than a record of them.

## Tests

`tests/check_cost.py`: `live_bounds.fpr` proves `live build <= 24 * n + 24`
(one 24-byte cons cell per step) and reports `scratch`'s arena with
`ω(?len)` for the copied result; `tests/base/loopwith.fpr` reports a
`per step (Sys.loopWith)` line and `ω(loop:Sys.loopWith)` for `run`.

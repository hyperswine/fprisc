# Resource bounds in signatures: what exists, what is missing, a staged plan

Date: 2026-10-02. Kind: proposal. Nothing here is implemented.
Follows item 4 of [2026-10-02-TOOLING-SEMANTICS-AUDIT.md](2026-10-02-TOOLING-SEMANTICS-AUDIT.md).

## The goal, restated as checkable claims

```
f : (a : Int) -> (b : Int) -> Int
  | work  f <= 12 * a + 40
  | alloc f <= 16 * a
  | live  f <= 64 .
```

A build for `<FPRISC.v1, QOS.v2, Hardware.v2>` reports, per function, one of:
proven within budget, proven over budget, unproved under these assumptions.
A strict profile refuses the last two. Upper bounds, not equalities: `==` is
rarely true of a worst case and never useful to a caller.

Units are the first decision and must be explicit. `work` is abstract
operations (the unit `StdCheck.hs` already counts); a target manifest turns
it into time. `alloc` is bytes requested over the call, compositional and
easy. `live` is peak resident bytes, harder, and the one that matters on a
Pi or a P4. Stack depth is a fourth quantity, now cheap to bound because the
VM and native both replace frames on tail calls.

## What already exists

| Piece | Where | What it gives |
|---|---|---|
| Termination measures | `Safety.hs` | For a self-recursive function: a measure expression, a decrease of at least k per call, a floor from guards. That is an iteration count, `ceil((measure(entry) - floor)/k) + 1`. |
| Cost algebra | `StdCheck.hs` lines 440-470 | `Cost = CN | CP param | CO ω(f) | CAdd | CMul | CMax | CDivC`, a simplifier, closed forms for measured self-recursion, `Fold lo hi` bounded by range, opaque ω for unsafe callees, `fpr stdcheck` exits 1 on failure. Operates on a separate Int-only lowering of one file. |
| Safepoint distance | `Codegen.wcetAnnotate`, `tools/wcet-ratchet.sh` | Max IR instructions between fuel safepoints per function, per target. Exact, deterministic, already a ratchet. Bounds latency to preemption, not whole-call work. |
| Measured runtime costs | `tools/runtime-costs.py`, `docs/2026-10-01-RUNTIME-COSTS.json` | Allocation about 4.2 ns, a message about 133 ns on this host, with logical ledgers (alloc requests, bytes, copies). Keyed to a compiler/runtime revision. This is a target manifest in embryo. |
| Typed vectors and layouts | `Infer.hs`, `Codegen.hs` | Element types and byte layouts are known statically, so `alloc` per push, per `Mk`, per record is computable. |
| Linear types | `lcheck` | A linear value is consumed exactly once, so its memory is dead at that point: `live` is computable exactly for linear data. `Sys.loopWith` already runs a long loop in O(1) memory by this reasoning. |
| Tail calls | native `knownCall`, Sol `TailCall` | Tail recursion is O(1) stack in both profiles; non-tail recursion depth is iterations times frame size, both known. |
| Recursion schemes | `Vec.map/filter/fold`, `foldRange`, `Sys.loopWith`, JIT kernels | Iteration counts are the container length. The bound is provable once in the prelude. |

What does not exist: a cost pass over the real typed Core, cost in the
signature grammar, cost in module interfaces, a target manifest format, and a
build mode that instantiates and judges.

## Why nothing composes today

Three checkers hold three pieces of the same fact and disagree.
`Safety.hs` accepts `measure (lim - i)` with a floor from a case guard;
`StdCheck.hs` only accepts a parameter decreasing by a literal and so calls the
same function uncertifiable. `wcetAnnotate` counts instructions but has no
iteration counts. Nothing writes a cost into an interface, so an import is
always ω. The grammar refuses `| work f <= ...` (correctly, since this
morning: before, it would have been silently dropped).

## The staged plan

Each stage is useful alone, has an acceptance test, and does not need the
later ones. Order matters: 0 unlocks 1, 1 unlocks everything else.

### Stage 0. One measure language

Make `Safety.measureCheck` the only termination checker, and have it return
the iteration bound as data: `(measureExpr, k, floor)` per function. Delete
`StdCheck`'s syntactic `p - k` rule and consume that triple. Extend measures
to mutual recursion with a lexicographic or summed measure over the SCC.

Acceptance: `tests/measure.fpr` (all three measure kinds) gets a cost equation
from `fpr stdcheck`; today `sumTo` fails there. Mutual `ping`/`pong` with
`measure n` is accepted by both.

### Stage 1. A cost pass on the typed Core

New `Cost.hs` after inference, preconditions and safety, over the same Core
the code generator sees, not a separate lowering. One transfer function per
construct:

| Construct | work | alloc |
|---|---|---|
| literal, variable | 0 | 0 |
| arithmetic, comparison, projection | 1 | 0 |
| `Mk`, record, cons, `Vec.push` | 1 | payload bytes from the layout pass |
| `case` | scrutinee + max over arms | max over arms |
| `let` | sum | sum |
| known call `g args` | `work g` with g's parameters substituted by the argument size expressions | likewise |
| measured self-recursion | iterations (Stage 0) times the body with the recursive call removed | likewise; plus frame size times depth for non-tail recursion |
| call through a parameter `f` | the variable `work f` | `alloc f` |
| unsafe callee | ω(g) | ω(g) |
| foreign/C callee | declared bound (below) or ω | likewise |

Sizes: an `Int` parameter is its value, as now. A `List a` or `Vector a`
parameter has size `len p`. A record's fields are projections. This is the
same vocabulary measures already use, which is why Stage 0 comes first.

`live` in Stage 1 is the conservative bound `alloc` plus frames. Stage 4
tightens it.

The pass emits every function's equations in `fpr build` output under a flag,
as information, before any of it is enforced. Imported modules contribute
their own equations through the unit interface (next stage), so ω appears only
for genuinely unsafe or foreign code.

Acceptance: `fpr build --cost prog.fpr` prints `work count <= 7 * n + 3`
for the measured countdown, with no ω; the same for a program that calls it
through an import.

### Stage 2. Bounds in signatures and interfaces

Grammar, after the result type and before the terminator:

```
f : (a : Int) -> (b : Int) -> Int
  | work f <= 12 * a + 40
  | alloc f <= 16 * a .
```

Right-hand sides: integer linear and polynomial expressions over the named
parameters and their sizes, `work g` / `alloc g` of a parameter of function
type, and `ω g` naming a specific unsafe function the author accepts as
opaque. No free coefficients at this stage: `omega * a` with an unbound
`omega` is a parse error, as it is today, until Stage 3 gives it a meaning.

Checking: the pass derives the equation, simplifies both sides, and proves
`derived <= declared` for all parameter values in the precondition's domain.
For linear and polynomial forms over nonnegative sizes this is coefficient
comparison. Anything else is unproved and says so.

Declared bounds become part of the module interface, like types. `fpr commit`
compares them: a larger bound is a major change. Callers use the declared
bound, not the derived one, so a module can keep an implementation slack.

Foreign declarations (signatures with no definition, the HAL contract) must
carry bounds or are ω: `blkWrite : ... | work blkWrite <= 4000 .` This is
where the runtime's measured ledgers enter as declarations a human signs.

Acceptance: a declared bound smaller than the derived one is refused naming
both; a program importing a bounded module gets a closed form with no ω; a
commit that widens a bound is classified major.

### Stage 3. Target manifests and judgement

A manifest is a small file identifying the three versions by name and by
hash, and binding:

- nanoseconds per abstract op, as a worst case, per op class (an Int op, a
  comparison, a projection, an allocation, a message), taken from
  `tools/runtime-costs.py` runs on that hardware plus a stated safety factor;
- the frame size and safepoint policy of that compiler revision;
- the bounds of every foreign primitive that revision of QOS supplies;
- what is excluded: cache effects, other harts, interrupts, blocking I/O.

```
fpr build --target=manifests/pi4-qos-v2.json prog.fpr
  main          work <= 3.2 ms      PROVEN  (budget 5 ms)
  render        work <= 0.9 ms      PROVEN
  parseConfig   work <= ω(Json.parse) * 1  UNPROVED: Json.parse is unsafe
```

Named coefficients become legal here: `work f <= omega * a` where `omega` is
declared in the manifest, not invented by the program. A program may declare
`cost omega.` to say the coefficient is the target's business.

`segmax` from `wcetAnnotate` joins this report as the preemption-latency
column; it already has the right shape and a ratchet.

Acceptance: the same program judged against two manifests gives two
verdicts; an unproved function names the ω or the missing primitive bound.

### Stage 4. Live memory and persistent programs

`live` tightened with what linearity knows: a linear value's bytes leave the
bound at its consuming use; an arena step (`Sys.loopWith`) resets the loop
body's allocations to zero at each iteration; ARC data is bounded by `alloc`
unless the author declares otherwise. Mailbox capacity enters as a declared
bound on an actor's queue.

For MVU this gives the thing a persistent app actually needs: `update` and
`view` each have per-turn `work` and `alloc` bounds, the model's size has a
bound, and the queue has a capacity, so the whole app has a `live` bound
without pretending the event loop terminates.

Acceptance: `Sys.loopWith` loop proven O(1) live; an MVU app from `std/mvu`
reports a per-frame budget and a resident bound.

## What this deliberately does not promise

Wall-clock time on real hardware with caches and other harts. The manifest
makes the assumptions explicit and the number is an upper bound under them;
it is not a cycle-accurate WCET. Tabling and GPU tiers are speedups and never
enter a bound; JIT is the same op count under a different manifest. A
callback whose cost is unknown stays a variable in the equation, which is
honest and often all a caller needs.

## Order of work and size

| Stage | Touches | Size |
|---|---|---|
| 0 | `Safety.hs`, `StdCheck.hs` | days |
| 1 | new `Cost.hs`, hooks in `Compile.hs` and `Sol/Main.hs`, layout sizes from `Codegen.hs` | one to two weeks |
| 2 | parser (`TSig` gains a bound list), `Infer.hs` interface, `Modules.hs` unit interface, `Commit.hs` | one week |
| 3 | manifest reader, `Build.hs` report, `tools/runtime-costs.py` output format | days |
| 4 | `Cost.hs` live rules, `std/mvu.fpr` signatures | one to two weeks |

Stages 0 and 1 are the ones that change what the language is; the rest is
surface. Do 0 first: it is small, it removes a contradiction that exists
today, and every later number depends on it.

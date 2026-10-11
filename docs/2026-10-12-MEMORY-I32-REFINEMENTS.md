# Memory growth by design, an I32 type, and refinements in the type

Date: 2026-10-12. Kind: review with proposals. Applies from revision
`e32e533`. Evidence: a source and documentation reading of `compiler/`
(`Infer.hs`, `Precond.hs`, `Safety.hs`, `Cost.hs`, `Arc.hs`,
`Representation.hs`, `Compile.hs`), `runtime/`, `std/mvu.fpr`, and the pages
cited below. The original review used source reading only; the implementation
checkpoint below records the subsequent executable checks.

Status: Proposal A has a first implementation: value-state turn regions,
bounded-by-default MVU library loops and automatic regions for recognized
value-state recursive receive loops. General mutable/higher-order recursion,
precise Base ARC, I32 and refinement types remain proposals.

Three topics, independent of each other:

1. Why memory keeps growing in long-lived programs, and what would make
   bounded memory the default rather than a pattern each actor must apply.
2. An `I32` type mirroring `I64`, for wasm `i32`, RV32 targets and bit-exact
   32-bit arithmetic.
3. Moving preconditions into the type, with automatic propagation in both
   directions, and the refactoring that requires.

---

## 1. Memory growth is mostly structural

### What the recent fixes have in common

Growth has been found and fixed repeatedly:

| Where | Retained | Fix | Page |
|---|---|---|---|
| pshell frame-per-actor renderer | slabs, stacks, ACBs per frame | grant recycling, stack pool, persistent worker + `Sys.poolReset` | QOS history, Aug |
| Unit codegen | one svcCall request root per frame | `autoDrop` applied to units | Aug 20 |
| `I64` loop | a 24-byte cell per result (1.9 GB per 10M steps) | `Sys.arena` around the loop | 2026-10-05-I64 |
| QOS Main MVU driver | 31.9 MB / 436 slabs over minutes | `std/mvu` `runScoped` | qos 2026-10-11-PI4-MEMORY-SOAK |
| QOS Graphics owner | 2.3 MB / 36 slabs | transfer persistent state, reclaim each turn | same |
| Logger | request tuples and snapshot lists | explicit drops, `Sys.loopWith` | 2026-10-11-LOG-MEMORY |

The implementation bugs among these (recycling, the ACB ledger, unit
autodrop) are fixed. What remains is one shape that keeps recurring.

### The cause

In the Base profile an actor allocates into its own pool, and **nothing in
the pool is freed individually**. Backing memory returns when the actor dies
or when the pool is reset (`Sys.poolReset`, `Sys.arena`, `Sys.loopWith`,
`runScoped`). Reference counting applies only to values that escape the
actor (message roots, `sendArc`), and `drop` releases a received root, not
the values reachable from it.

Consequences:

- A short-lived actor is always fine: death reclaims everything.
- **A long-lived actor that allocates per iteration grows linearly, even when
  its live state is constant.** The Pi soak measured 31.9 MB held by the MVU
  driver against about 25 KB of live data.
- Every fix so far is an opt-in pattern for one actor. The default still
  grows, so each new long-lived service reintroduces the problem until it is
  noticed. That is why growth looks random: it is one class appearing wherever
  the pattern was not applied.

Separately, "uses more than expected" is mostly fixed granularity rather than
leaks: 64 KiB minimum grants, 256 KiB stacks, per-actor control blocks, slab
sizes, and boxed `I64`/`Word`/`Addr` cells.

### The target

Two properties, and nothing else:

- **A value that can no longer be reached is freed** (reference counting does
  its job, per value, not per actor).
- **Everything else is bounded by construction:** linear vectors updated in
  place, double-buffered frames, and long-lived state whose size is part of the
  program's declared state.

### Proposal A (short term): region per turn as the default

Make every long-lived receive loop reclaim per turn, in the runtime, without an
opt-in:

1. Each turn (one received message, or N of them) allocates into a turn
   region.
2. At the turn boundary the state carried to the next turn is copied out
   (`runScoped` and `Sys.loopWith` already do exactly this), and the region is
   reset.
3. Messages sent during the turn are promoted as now; received roots are
   dropped at the boundary unless retained into the state, which copies them.

This is a generational collector with an explicit nursery. Cost is
proportional to live state per boundary, and memory is bounded whenever state
is bounded. `runScoped` becomes the only MVU behavior; `Sys.loopWith` becomes
what a recursive receive loop compiles to.

Open points:

- **Identifying the loop.** A tail-recursive function whose body receives is
  the shape; a compiler pass can mark it, as `autoDrop` marks destructured
  roots. Loops it cannot recognise keep today's behavior and are reported.
- **State with mutable storage.** `runScoped`'s contract excludes externally
  aliased mutable vectors. Linear vectors in state are moved, not copied;
  anything aliased needs explicit handling or a refusal.
- **Boundary frequency.** Per message is simplest; every N messages trades
  copy cost against peak memory. Make it a declared policy.

### Implementation checkpoint: value-state loops and default MVU

`Sys.loop : a -> (a -> (Bool, a)) -> a` runs each callback in a fresh scratch
region. `True` continues with the returned state; `False` returns that state
to the caller. The runtime copies the next state into an independent transfer
slab before tearing down the scratch region, releases the previous transfer,
and copies the final result into the caller's pool. The caller's allocations
and callback captures stay alive. Heap use depends on the largest turn and
live state, rather than the number of turns; transferring state costs time
proportional to its size. The cost report exposes a per-step estimate and
leaves unknown state sizes symbolic rather than claiming a numeric bound.

The initial state, returned state and callback captures may not contain a
`Vector`; each case has a named runtime refusal. Mutable buffers still use
`Sys.loopWith` with its explicit storage-identity contract. This does not
establish ownership for unsafe foreign pointers. Received ARC roots still
need `drop`/autodrop; copying a state does not release its received root.

`MVU.run`, `runLive`, the game façades and watched runners now reclaim their
driver temporaries every frame. `runScoped` and `runLiveScoped` remain as
compatibility aliases. The render worker carries its callback as value state
through its own turn loop. Event ports keep each received message into owned
queue state, release the received root, and reclaim each receive turn. This
also reclaims list spines after drains. A queue or model that grows without
limit still consumes unbounded memory: this change is reclamation, not an
application-state or admission budget.

Cancellation now walks an actor-owned chain of active scratch scopes before
recycling its stack. It tears down nested `arena`, `loop` and `loopWith`
regions and releases their transferred state, independently of any pending
external request cleanup. This adds an ACB field and advances the shared
native ABI to **6**; rebuild native kernels and applications together.

### Compiler checkpoint: ordinary recursive receive loops

`compiler/ReceiveTurns.hs` recognizes tail-recursive groups that receive
messages, including mutual recursion and receives through imported helpers.
The pass runs after source checking and lambda lifting, before function
specialization and inlining. It preserves the public function type and
entry point. Receive entries get a private step; a tail call to the next
entry evaluates its arguments strictly, left to right, and returns a closure
carrying only the live next-entry arguments. A private runtime trampoline runs
these steps through the same region engine as `Sys.loop`. A terminating branch
copies its ordinary result back into the caller's pool. State bundling
accommodates the native wide argument convention without adding an argument
to a wide call; capture-free/zero-argument entries use Unit state.

Compiler-generated clause/case joins and source helpers between receive
entries are direct calls inside the current turn. Their temporary callback,
message and Vector values are not copied as persistent state. Private joins
are identified by lowering provenance, not a function-name convention, and
retain their shared control-flow DAG. Ordinary lifted lambdas still need
checked evidence if they are themselves receive entries. Public helper entry
points keep their original calling behavior.

A least-fixed-point liveness analysis omits unused parameters, including those
only forwarded around a recursive group. Strict argument effects still run,
and mutable storage still must be consumed before the boundary.

This applies only when live entry parameters and returning results have closed,
first-order value type evidence: supported scalar values, lists, results,
tuples, closed records and recursively checked non-linear nominal types.
An infinite actor's polymorphic bottom result is allowed when every terminal
path of every group member, including private joins, is a saturated call
inside its recursive group or a compiler trap;
there is then no returning result to copy.
Loop-carried Vectors, linear nominal types, functions/callback captures, open
or polymorphic state, non-tail recursion, escaping/partially applied recursive references,
and missing evidence keep their existing behavior. Existing explicit region
management also stays in control. In particular, this is a first automatic
pass, not a claim that arbitrary recursion is now bounded. Regions bound
temporary lifetimes; an accumulating list or growing model still grows.

Use `FPR_RECEIVE_NOTES=1` or `--cost` to see transformed groups and reasons
for leaving recognized groups unchanged, including the specific live parameter
or result that lacks value evidence. `FPR_NO_RECEIVE_TURNS=1` restores
the previous pool behavior for comparison; it has a separate assembly cache
identity. The generated code requires the matching runtime's private
`$receiveLoop` import. Code generation revision is **39**; the ACB layout
remains ABI 6; the expanded pass uses assembly cache tag `rt3pc1`. Cost analysis sees the transformed Core and leaves trampoline
work/copy sizes opaque until it can derive them, so it cannot silently reuse
a pre-transformation numeric cost bound.

Received ARC roots still follow `drop`/autodrop and copy-on-retain rules.
The region pass does not manufacture ownership evidence for an unrecognized
root use or keep a borrowed message alive across another receive. Its runtime
graph checks also refuse a Vector that unsafe code smuggles into a continuation
despite the checked source type.

`tests/check_receive_turns.py` exercises one million ordinary recursive receives
under a 64 MiB heap, final-state/caller survival, stable received roots, mutual
case branches, nominal state, argument effect order, imported helper receives,
wide state and cache isolation, and cancellation after transferring state.
It also reproduces pool growth with the pass disabled and checks that mutable,
functional, non-tail and explicitly managed loops are reported unchanged.
`tests/base/receivecoverage.fpr` also covers zero arguments, shared clause/case
joins with shadowed captures, dead forwarding slots, argument effects, and
temporary callbacks/linear vectors used and released within a turn.
`tests/base/mvutextmemory.fpr` checks 20,000 text-renderer requests and released
ARC roots. MVU Ev/Sub fields are now concretely typed, while the generic render
payload contract remains intact; the renderer explicitly keeps/drops its
received root before handing a request to its helpers.

These checks passed on macOS ARM64 and Linux ARM64. The ordinary million-message
fixture also passed on the physical Pi 4 with one/four workers and a 64 MiB
heap (about 8.3 seconds, 1,920/2,048 KiB peak RSS). A reduced 10,000-message
fixture linked and ran on four-hart RV64 QEMU. QOS native boot, Portable MVU,
real plugin reloads and the ARM64 Linux real-GL Main harness also passed.
The Main harness includes Files/Logs scrolling, onboard apps, refusal paths,
two boots and graceful shutdown. The separate Pi Main-session checks for
the preceding library-default commit are recorded in QOS's
`docs/2026-10-12-PI4-DEFAULT-TURN-MEMORY.md`.
The complete Base regression suite and the symbolic cost checks also passed.

`tools/runtime-costs.py` now pairs primitive-only (`receive_turns: false`)
and default turn-region (`receive_turns: true`) message measurements. The
primitive baseline retains its exact copy ledger; the default also counts
continuation/state transfers. Its last worker boundary may race cancellation,
so it reports the observed overhead rather than asserting one exact count.
Use `--receive-turns=off` for comparable primitive calibration. Prior recorded
throughput numbers do not establish the cost of the new default.

### Executed library acceptance checks

Executed acceptance checks:

- `tests/check_loop_state.py`: one million turns under a 64 MiB heap on one
  and four harts; caller/captured strings and final state survive; caller
  allocations stay below 4 KiB per run and retained global heap below 4 MiB.
  Bare actor handles preserve identity and remain live through `loop`/`arena`.
  Initial, returned and captured vectors receive named refusals. Killing 256
  more blocked actors inside all three nested scope forms retains under
  4 MiB after warmup.
- `tests/check_arena_migration.py`: nested regions and both loop forms preserve
  caller state across observed migration on four harts, plus the one-hart case.
- `tests/check_mvu_reload.py`: ordinary `run` completes 20,000 frames under
  64 MiB on one and four harts, with under 4 MiB additional retained heap and
  live caller/callback strings. The same workload exhausted that heap before
  this change. Reload ordering, accepted environment state across boundaries,
  legacy façades, the scoped alias and production ticks also pass. Event ports
  complete 20,000 FIFO fill/drain batches with stable ARC-root counts.
- Cost reporting exposes a `Sys.loop` scoped-step estimate. External request
  cleanup still runs when an actor parked inside an arena is killed.
- The value-state fixture also links and runs 10,000 turns on RV64 QEMU with
  four harts. QOS Portable's MVU engine and real plugin reloads pass on one and
  four harts; QOS Native links and boots to its launcher.
- A fresh ARM64 Linux build passes the real QOS GL shell harness on four
  harts: Files/Logs scrolling, onboard clock/browser, refusal paths, pointer
  protocol and state across two boots, with matching rebuilt plugins.
- The complete Base regression suite passes, including admission rollback,
  fixed heaps, logger bounds, actor teardown and live module replacement.

These library checks assert heap reclamation. The compiler checkpoint above
covers recognized handwritten recursive receive loops; unsupported loops keep
the previous pool behavior. Precise per-value ARC and fixed admission for
scratch regions remain separate work. QOS records the actual application
coverage and subsequent Pi residency/workload measurements in
`docs/2026-10-12-RECEIVE-TURN-COVERAGE.md`.

### Proposal B (long term): precise ARC in Base

The builtin profile already has per-value ARC (`--arc`, `Arc.hs`): ownership
inserted into lifted Core, exact managed-field metadata per allocation, and
worklist destruction with no recursion or extra allocation. Extending it to
Base in the Perceus style (Koka, Lean 4) gives the target directly:

- values are freed at their last use;
- a uniquely owned value is updated in place ("functional but in place"),
  so the functional style runs as mutation with constant memory;
- actors are single-threaded, so counts are non-atomic; cross-actor escapes
  keep using the existing send promotion.

The missing pieces are already named in 2026-09-18-BAREMETAL-BUILTIN: owned
closures and partial applications, representation-polymorphic functions,
last-use moves, borrowed parameters and reuse. The 2026-09-29 audit calls
ownership unification the largest remaining design task; this is that task.

A and B compose: with B in place, A's boundary copies little because most
garbage is already freed, and A remains the guarantee for code B cannot
analyse.

### Diagnosis until then

The existing counters (grow counts, pool snapshots, live ARC roots) separate
three kinds of growth:

| Grows with | Likely cause |
|---|---|
| time, at constant state | a long-lived loop without per-turn reclamation |
| number of actors spawned | per-actor residue (control blocks, stacks, grants) |
| number of messages | received roots not dropped, or ARC holders retaining |

### Tests

- A soak leg per long-lived std service and QOS service, with an allocation
  bound, as the Graphics regression already has (100,000 frames under 2 MiB).
  New services join the list or fail review. This is the ratchet.
- For A: a receive loop with constant state and per-message garbage must hold
  a fixed number of slabs over 1,000,000 messages with no opt-in.
- For B: `Mem.liveAllocations`-style counts at zero after `main` for the Base
  suite, as `ARC_CHECK=1` does for builtin.

---

## 2. An I32 type

### Why

- **wasm `i32`** is the most common wasm value type. An interpreter needs
  exact wrapping 32-bit arithmetic, unsigned operations and reinterpret casts.
- **RV32 targets** (the Tang Nano 20K SimpleRisc core) refuse `I64` and
  `F64` by name (`Compile.hs`: "profile builtin RV32: F64 and I64 require a
  64-bit value ABI"). `Int` is 31 bits there, and `Word` is 32 bits but has
  no multiply, divide, signed comparison, arithmetic shift, rotate or bit
  counts.
- On 64-bit targets, `Int` arithmetic followed by masking works but is easy
  to get wrong and does not wrap signed values correctly without care.

### The type

`I32` mirrors `I64` in [2026-10-05-I64](2026-10-05-I64.md), at 32 bits:

| Group | Operations |
|---|---|
| operators | `+ - * /` (signed, truncating), `%` (dividend's sign), `< > <= >=` (signed), `== !=`; `^` refused |
| unsigned | `I32.divU remU ltU gtU leU geU`, `I32.strU` |
| bits | `I32.and or xor not neg`, `shl shr sar rotl rotr` (count modulo 32), `clz ctz popcnt` (to `Int`) |
| with Int | `I32.ofInt` (wraps: low 32 bits); `I32.toInt` (always fits, sign-extended); `I32.toIntU` (zero-extended) |
| with I64 | `I32.ofI64` (wrap), `I32.toI64`, `I32.toI64U` (wasm `i64.extend_i32_s/u`, `i32.wrap_i64`) |
| with F32/F64 | `I32.toF32/toF64` and unsigned variants; `I32.ofF32/ofF64` and unsigned variants as `Result` (truncate; refuse NaN and out of range); `I32.ofF32Bits`/`toF32Bits` |
| text | `I32.str`, `strU`, `hex`, `parse` |

Division by zero and `INT32_MIN / -1` panic, as for `I64`. No literals:
`I32.ofInt 5`. `I32` never mixes implicitly with `Int`, `I64` or `Word`.

Two choices differ from `I64` on purpose: `I32.ofInt` **wraps** rather than
refusing, because every wasm `i32` producer wraps and the common use is
"take the low 32 bits"; and `toInt` is total, since every `I32` fits in `Int`
on 64-bit targets (on RV32 see below).

### Representation

- **64-bit targets:** unlike `I64`, an `I32` can be **unboxed**. Store it as a
  tagged `Int` holding the sign-extended value: 32 bits fit in 63 with room to
  spare, so it can never be mistaken for a pointer (the hazard that forced
  `I64` to be boxed). Each operation computes in 64 bits and re-normalizes
  (sign-extend from bit 31). No allocation, no arena needed in loops. The
  type is distinct at compile time; at run time it is an `Int` whose value is
  always in range.
- **RV32 targets:** a tagged `Int` is 31 bits there, so an `I32` cannot be
  one. Use the `Word` representation: an untagged 32-bit word, unboxed under
  ARC and boxed in manual-ownership builds as `Word` already is. `toInt`
  becomes `Result Int String` on RV32 for values outside 31 bits; the
  signature can be the `Result` form everywhere for portability, with the
  64-bit implementation always returning `Ok`.

This makes `I32` the natural integer for the on-board wasm interpreter, and
on RV32 it supplies the operations `Word` lacks. `I64` on RV32 remains a
separate question (a pair of words with carry), not part of this proposal.

### Where it lives

Following `I64`: the type and signatures in `Infer.hs`; `I32` in operator
resolution for operators, `%`, `==`, `str`/`print`; primitives in
`runtime/runtime.c` outside the 64-bit-only section; render and equality as
`Int`. On 64-bit targets most operations can be emitted inline (add, mask,
sign-extend) rather than as calls, which also avoids the call-per-operation
cost noted in 2026-09-30-SUGGESTIONS.

### Tests

`tests/i32.fpr` mirroring `tests/i64.fpr`: wrap at both ends, `INT32_MIN / -1`,
unsigned compare and divide at the boundary, shifts and rotates at counts 0,
31, 32 and 63, `clz/ctz/popcnt` of 0 and -1, every conversion at its limits,
parse refusals; a typing leg that `I32` does not mix with `Int`, `I64` or
`Word`; an allocation leg that a 10-million-step `I32` loop allocates nothing
on 64-bit targets; and the same suite under builtin RV32.

---

## 3. Refinements in the type, with propagation

### Where it stands

- Preconditions are a separate pass (`Precond.hs`) after inference. A
  predicate on a parameter becomes a fact inside the function. At a call the
  callee's predicate is substituted and proved from local facts (own
  preconditions, the clause's guards, `case` arms, literal lets), or a runtime
  check with blame is inserted **at that call site**.
- Nothing propagates upward. An obligation the caller cannot prove never
  becomes part of the caller's contract; the programmer must write it.
- Nothing propagates out of results: there are no postconditions in the
  native pass, so `max 1 x` is not known to be positive afterwards.
- Proof is by constant evaluation, a bound per variable and syntactic
  matching. `n - 1 >= 0` from `n > 0` is not proved; earlier clauses' failed
  guards are not used.
- A contracted function passed as a value (`List.map validate xs`) or
  partially applied may not have its contract checked.
- Measures (`Safety.hs`) and cost (`Cost.hs`) are separate passes again;
  `Cost.hs` does compose bounds up the call graph automatically.

### The direction: Liquid-style refinements over HM

A refinement becomes part of a type: `x : {v : Int | v < 5}`. Inference stays
two-phase:

1. HM inference exactly as now finds base types. The unifier never sees
   predicates, so rows, kinds and operator resolution are untouched.
2. A refinement phase attaches a predicate to every integer-typed position
   and solves constraints between them.

Signatures, hover, the obligation report and module interfaces then carry one
type with two layers instead of a type plus a separate contract list.

### Propagation

**Upward (callers inherit callee requirements).** Process the call graph
callee-first. An undischarged obligation that mentions only the caller's
parameters joins the caller's inferred precondition instead of becoming a
check. Stop at boundaries, which keep a runtime check at entry:

- exported functions, actor message handlers, `main`;
- functions used as values (this closes the first-class bypass: the check
  moves into the function itself);
- recursive groups without a written contract.

**Downward (callees inherit caller facts).** A function's parameter
refinement becomes the join of what all its callers pass. This is sound only
in a closed world: functions that are not exported, not used as values and
not live-reloadable. Where the join is too weak, `Mono.hs`'s specialization
could clone per refinement, as a deliberate choice rather than by default.

**Out of results.** A result refinement (`abs : Int -> {r : Int | r >= 0}`)
is inferred like any other position, so facts flow out of calls as well as
into them.

### The solver: abstract interpretation, not SMT

The predicate fragment (comparisons over `+ - *` of variables and literals)
is small enough for a fixpoint over a numeric abstract domain:

- intervals per variable, plus difference bounds `x - y <= c` (the octagon
  domain) so relations such as `i < n` survive;
- a fixpoint over the call graph in both directions;
- widening for recursion, with verified measures supplying better bounds
  where they exist.

It is decidable and deterministic, which keeps the existing rule that the line
between proved and checked must not depend on solver behavior.

### Higher-order code

`List.map validate xs` requires refinements on type variables: instantiate
`a` in `(a -> b) -> List a -> List b` with `validate`'s refined parameter, so
each element passed must be proved to satisfy it. This is the part needing the
most care, and it is what makes pipelines (central to the intended style)
checked rather than bypassed.

### Refactoring this requires

1. **One representation.** Preconditions move from the signature-side
   contract list into the type representation used by `Infer.hs`'s output and
   the module interface. The surface syntax `(n : Int | n > 0)` is unchanged.
2. **One fact engine.** `Precond.hs`'s fact collection (guards, case arms,
   literal lets), `Safety.hs`'s floor derivation for measures, and `Cost.hs`'s
   bound composition share one abstract domain and one walk, instead of three
   separate views of the program. Measures become refinements on a recursive
   call's argument (`measure` decreases and stays non-negative).
3. **Interfaces carry refinements.** `fpr commit`'s compatibility check
   compares refined signatures; a weakened postcondition or strengthened
   precondition is a major change. Live reload's interface gate compares them
   too.
4. **Inferred contracts on exported functions are written down.** The compiler
   refuses an exported function whose inferred precondition is not written in
   its signature, and prints the exact line to add, so an internal edit cannot
   silently change a module's interface.
5. **Rows get rigid variables.** `checkDeclared` already skolemizes type
   variables; row variables are still matched by unification, so a signature
   promising `{w : Int | r}` can be silently narrowed by a body that also
   reads `h`. Add rigid row constants with the same probe. Independent of
   refinements, but part of the same "the declared type is the contract" work.
6. **Update the `Infer.hs` header**, which still says signatures are matched
   by unification rather than checked for generality.

### Order of work

1. Refinements in the type representation, no new inference (refactor 1, 6).
2. Upward propagation and result refinements over intervals (with refactor 4).
3. The shared fact engine (refactor 2); measures expressed as refinements.
4. Downward propagation for closed-world functions.
5. Refinements through type variables for higher-order code.
6. Interface comparison of refinements (refactor 3) and rigid rows (5).

Step 2 alone should remove most inserted runtime checks in `examples/ideal/`.

### Tests

- The `examples/ideal/` ratchet from 2026-10-03-STYLE-DIRECTION: discharged
  versus runtime-checked counts may only improve.
- `n - 1 >= 0` from `n > 0` discharged; a fallthrough clause knows the
  negation of earlier guards; `max 1 x` known positive.
- Upward: a two-level call chain where only the outer function is exported
  gets one entry check and no internal checks; removing the written contract
  from the exported function is a compile error naming the line.
- First-class: `List.map positive [1, -1]` fails at the element, natively and
  in Sol.
- Downward: an unexported helper called only with guarded arguments has no
  internal checks; adding an unguarded caller reintroduces them.
- Rows: a body reading an undeclared field of an open-row signature is a
  compile error at the signature.

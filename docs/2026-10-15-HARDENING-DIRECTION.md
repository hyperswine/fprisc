# Hardening and graceful recovery: the direction

Date: 2026-10-15. Kind: direction. Follows the edge-case battery
([2026-10-11-EDGE-CASES.md](2026-10-11-EDGE-CASES.md)), its fixes, and the
overflow decision ([2026-10-12-INT-OVERFLOW.md](2026-10-12-INT-OVERFLOW.md)).
Those made failures honest: refusals by name, traps instead of wraps,
bounds on requests. This page is about what comes after honesty: a
failure that the program can survive, and a tool that feels robust because
of it. Seven items, in the order they should be done; the first two turn
this month's traps and refusals into recoverable events rather than
better-worded deaths.

## 1. Failure containment: a trap kills an actor, not the machine

Today `fpr_cpanic` ends the whole process in a Base program; only inside a
QOS loaded image does `fpr_actor_fail` isolate the actor. The Int overflow
traps inherit that: one bad add in a worker takes a server down.

- Every trap becomes an actor failure on the posix machine as in a loaded
  image, with actor 0 the one exception (it is the program).
- **Death carries a reason.** The states register names this gap: a watcher
  learns an actor died, not why. The exit notice carries the panic text and
  the tag of the message being handled.
- **Links and monitors as std.** `std/actor` has watchers; a
  `std/supervisor` with restart strategies (one-for-one, rest-for-one, a
  restart budget per window) makes the existing fail-stop into recovery.
  S99qosp does this at process level on the Pi; the actor level is where
  graceful recovery lives.
- **State that survives a restart.** Value-state regions and Qlog durable
  commits are the substrate: a supervised actor restarts from its journal,
  as logbook already replays.

## 2. A deadline on every wait

The registers repeat "no wait has a deadline": the Files owner's waits,
`receiveFrom`, the Poller reader (`readMs` bounds nothing there), the
deadlock detector that notices after two seconds. Rule: every blocking
primitive has a `Within` form, and every std server-side wait uses one with
a stated default. A stuck peer becomes `Err "timed out"` for the caller to
handle, not an actor held for ever. The register's wait list is the
checklist.

## 3. Errors for input, panics for programmer error

The library mostly does this (JSON, HTTP, `toInt`, `wireInt`), but the line
is not written down, and some primitives still panic on data: `chr 256` is
a named panic, and a byte-making function given a value from input could
answer Err. An audit of std for "panics reachable from outside input" is a
register section of its own. Fuzzing the decoders (JSON, HTTP headers, the
wire codec, the terminal escape parser, Config) finds the rest; the edge
battery is the seed corpus.

## 4. Backpressure the caller can see

`Static n` mailboxes refuse by name and `send` answers Err when full, but a
`Dynamic` mailbox grows until memory and most std servers use `sendSure`.
Bounded mailboxes with a stated refusal (503, "busy") in the HTTP server,
the Files owner and the live websocket path turn memory exhaustion into a
visible answer. Per-actor memory budgets on the existing admission complete
it.

## 5. Observability at the moment of failure

The error ring and the persist hook keep last words. Missing is a
structured crash report: actor id and name, the message being handled,
mailbox depth, stack depth, and the deadlock detector's wait graph (who
waits on whom, not "deadlock"). Printed on every fail-stop, it makes the Pi
and Star64 kinds of hunt hours instead of days.

## 6. Tests that find the next class of bug

- The edge battery and the power-cut harness in CI, not by hand.
- Fault injection: short reads, EAGAIN storms, allocation failure at a
  chosen call, a clock that jumps. The runtime has most of the hooks.
- A soak ratchet (the planned memory one) and a scheduling-replay mode so an
  actor race reproduces deterministically.
- Differential tests like `inlineprims` for every inline fast path;
  sanitizer builds for the posix machine, not only builtin.

## 7. The compiler's side

Bounds in signatures ([2026-10-02-BOUNDS-IN-SIGNATURES.md](2026-10-02-BOUNDS-IN-SIGNATURES.md))
and the propagated refinements ([2026-10-12-MEMORY-I32-REFINEMENTS.md](2026-10-12-MEMORY-I32-REFINEMENTS.md))
are the answer to a whole class: a `(n : Int | 0 <= n < 256)` parameter
makes `chr` total and moves the check to the caller's evidence. Smaller
wins in the same spirit: shrink what `unsafe` is needed for; fold literal
arithmetic at compile time and refuse an overflowing fold.

## Order of work

Death reasons; actor-level trap isolation on posix; `std/supervisor`; the
`Within` sweep. Then 3 to 7 as the registers' open items are closed. Each
step gets its states-register entry before its code, as the actor and
mailbox entries did.

## Progress (2026-10-15)

Item 1, the first two parts, are done (fprisc main): **death carries a
reason** (`acb.why`, written before DEAD; `receiveFromRes` answers `Err
"dead actor: <why>"`; a kill says `killed`; a return stays `dead actor`),
and **a trap ends the actor, not the machine** on every machine with the
actor runtime: `error`, the Int overflow traps (the C primitives, the
inline guards, the vector kernels) and division by zero go through
`fpr_trap`, which is `fpr_actor_fail` for any actor but 0. The states
register has the **Failed** entry; `tests/base/deathwhy.fpr` is the test.
Not done: the plane's copy of the actor API (qos) still answers the bare
reason; other primitive refusals (`charAt` out of range, `chr`) are still
machine panics, pending item 3's input-vs-programmer-error audit.

Item 1's third part, **`std/supervisor`**, is done the same day: a monitor
per child (an actor parked on `receiveFromRes`, so the reason above is
what it reports), the three restart strategies, a restart budget per
window, and past it the supervisor kills its children and fails by name,
so the program or a supervisor above hears `dead actor: supervisor: ...`
and decides; `lookup` finds a child's current handle within a budget.
`tests/std/supervisor.fpr` drives all of it. State that survives a
restart is the child's own business (its journal, its durable fields).

Item 2, the **`Within` sweep** (same day): `std/actor` gained
`askSureWithin`; the waits a std client makes on a std owner now carry a
stated budget, past which the caller fails by name instead of waiting for
ever (the outcome of the request is unknown, as the deadlines page says):
std/journal's `append` (10 s, `appendWithin`), std/kvlog's `put get keys
size` (10 s) and `compact` (60 s), std/store's requests to its front and
shards (10 s), std/live's register requests (10 s). Not swept: the owners'
own `receive` (a server waits for mail by design), the poller's wait on
its host thread (the idle wait itself), and MVU, readiness and task, which
had their `Until` forms already.

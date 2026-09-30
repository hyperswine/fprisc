# Failure honesty: the small defects first

Date: 2026-09-30. Kind: implementation record.

The recent audits ([tooling](2026-09-29-TOOLING-SEMANTICS-AUDIT.md),
[native](2026-09-29-NATIVE-IDEAL-AUDIT.md), [Sol effects](2026-09-30-SOL-EFFECTS.md),
and QOS's `docs/2026-09-29-QOS-ARCHITECTURE-AUDIT.md`) share one class of
defect: something reports success, or picks an answer, when it should not.
This batch fixes the ones that were small and independent. Each has a test
that fails on the old behaviour. The QOS half is recorded in
`../qos/docs/2026-09-30-FAILURE-HONESTY.md`.

## Compiler

### Ambiguous operators are a compile error

`resolveSites` (compiler/Infer.hs) used to sort the candidate globals for an
operator site and take the first, so renaming a structure could change which
`+` a program called. The audit's probe printed `11,22` or `99,88` depending
only on the structures' names.

`namedOpTargets` and `namedOpTargets2` now return every candidate. One
candidate resolves the site as before. Several are a type error that names
them all:

    (+) is ambiguous for V2: Alpha.+, Zulu.+ all implement it -- keep one in scope or call the one you mean by name

A same-type site prefers the candidates whose second parameter is also that
type (`V2 -> V2 -> V2` over `V2 -> Int -> V2`), because that is what the
site's types say. This rule is not tie-breaking by name.

Tests: `tests/cases/op_ambiguous.fpr`, `op_ambiguous2.fpr` (refused, both
names reported), `op_unique.fpr` (one implementation per site; prints 2337),
in `tests/check_cases.py`.

Not changed: the audit's other resolution gaps. Mixed-type requirements are
still not preserved through generic inference; for example, `3 * (V2 + V2)`
with the inner sum unannotated still fails to unify. There is still no
explicit scoped-overload profile.

### `--stdcheck` exits non-zero on a proof failure

`runStdCheck` returns whether every obligation was proven or guarded, and
`fpr stdcheck` / `fprc --stdcheck` exit 1 when it was not. Before this change
it printed `stdcheck: FAILED` and exited 0, so it could not gate a build.
Tests: `tests/cases/stdcheck_ok.fpr` (0) and `stdcheck_fail.fpr` (1), in
`tests/check_cases.py`.

### A64: the specialized `Vec.filter` stays inside the shared IR

`emitFilterSpec` (compiler/Codegen.hs) used `s10` and `s11`. The shared RISC
IR that A64 and X64 lower from has only `s0`..`s9` (A64 maps `s1`..`s9` to
x19..x27 and keeps x28 for the hart), so `tests/fvec2.fpr` did not compile on
A64 (`A64: unmapped register s10`). The kept count is now `s7` and the
element is `s9`. Both registers were already free in that loop. The frame
saves `s0`..`s9`. `codegenRev` is 10, so cached units are rebuilt.
Test: `tests/check_base.py` builds and runs fvec2 natively (`kept=999`,
the same result as the RISC-V run).

## Runtime: a request/reply that answers

### `receiveFromRes me a : Result m String`

`receiveFrom me a` waits for a message from `a`. If `a` ends first, the wait
never finishes. `receiveFromRes` returns `Ok m`. It returns the static
`Err "dead actor"` once `a` has ended and nothing from it is still queued. A
message sent just before the sender ended is still delivered.

Death wakes exactly the actors waiting on the dead one:

- A waiter stores `watch = a` and increments `a->watchers` before
  `block_unless` marks it BLOCKED and re-checks its predicate. The predicate
  now includes "`a` is DEAD".
- An actor that ends, through a body return in `trampoline` or through
  `kill`, stores DEAD (seq_cst) and then reads `watchers`. It walks the actor
  ledger only when that count is non-zero, and wakes each actor whose
  `watch` points at it.

Either the waiter's re-check sees DEAD, or the dying actor sees the count and
finds the waiter. An actor with no watchers pays one load when it dies.
Both fields are appended to `acb_t`. The routed table gets
`receive_from_res`, appended to `fpr_sched_t`. A QOS kernel and its process
images must therefore be rebuilt together, as for any runtime change.

Test: `tests/base/deadpeer.fpr` (in `check_base.py`) covers a reply, a sender
already dead, a sender that dies while waited on, and 3,000 rounds of
reply-then-exit and exit-silently on 1, 4 and 8 harts. Every reply arrives
and every silent exit is an `Err`. Nothing hangs.

### `Sys.nextId : Unit -> Int`

A per-image counter that never repeats. It supplies correlation ids.

### `fpr_pid_live(pid)` (C, for QOS's loader)

Counts the actors of process `pid` that could still run its code: those
that are not DEAD, and those that are DEAD but still switched in on a hart
(`running`). QOS's native loader treats the process slot as reusable only
when this count is 0.

### The Sol shim has the same primitives

`fpr sol` runs FP-RISC programs on its own actor shim (Haskell threads), and
`std/mvu` reaches `std/actor`, so the shim got `receiveFromRes` and
`Sys.nextId` (compiler/Sol/{Infer,Preamble,VM}.hs). An ending actor wakes
every mailbox, and a spurious wake just re-checks. `send` to an ended
actor now answers `Err "dead actor"`, as the native runtime does. Before,
the shim answered `Ok` and dropped the message.

### std/actor: `call`, `callSure`, `reply`, `sendAwait`, `awaitFrom`

    call me a q    -- Ok r | Err "mailbox full" | Err "dead actor"

The request is `(me, id, q)` with a fresh `Sys.nextId`, and the reply is
`(id, r)`. The wire is tuples, not a declared type, so separately compiled
units such as QOS plugins agree on it. `call` behaves as follows:

- It checks the send, so a refused request is an answer.
- It waits with `receiveFromRes`, so an ended service is an answer.
- It takes only messages from the service, so an event from another actor
  stays queued.
- It drops a reply whose id is not this request's. Such a reply belongs to
  an earlier request whose caller stopped waiting.

The reply is kept (copied out) and the message released, as `boundary`
does. A server destructures `(from, id, q) = m`, so auto-drop still applies
to the message, and answers with `reply (from, id) r`. `callSure` waits for
room instead of reporting a full mailbox. `sendAwait` / `awaitFrom` give
the same send check and death answer on a wire with no id, for services
that send the caller nothing but replies (QOS's storage `Rpc`).

Limit: a message from the service itself that is not a reply is not detected.
Messages are untyped at run time, and a single-constructor match cannot
test for a different shape. A service that also sends its callers events
needs a separate endpoint for them.

Test: `tests/std/call.fpr` (in `check_std.py`).

## Sol: the commit tells the truth

These implement G1 to G4 of [SOL-EFFECTS](2026-09-30-SOL-EFFECTS.md):

- **G2: a failed remove fails the run.** `replayEffs` reports a file
  effect that did not reach its goal state separately from a failed
  deferred command. The receipt says `FAILED: a file effect did not reach
  its goal state`, later queued commands are skipped, and the run exits 1.
- **G1: a torn replay keeps its locks.** `withLocksHold` releases the locks
  on success and on failures before the commit point. Once the journal is
  written, an exception leaves the lock dirs owned by the dying pid. The
  next contender's dead-owner reclaim redoes the journal, so no committed
  result mixes old and new files. A redo that fails during reclaim puts the
  dead owner's lock back instead of dropping the fence. The startup redo
  holds its locks the same way.
- **G3: one journal per run.** The journal is
  `<script>.soljournal.<pid>.<nonce>`, a sibling file, so there is no shared
  directory to race on. At startup every journal of the script whose owner
  is dead is redone, including one whose pid was reused by this run. A live
  owner's journal is left alone, and the older single `<script>.soljournal`
  is still honoured.
- **G4: `print` is direct, `log` is transactional.** `log v` (preamble;
  `/dev/log` in the VM) joins the transaction: it is discarded with a
  retried or panicking attempt and emitted once, after the commit, only when
  every effect reached its goal state. On a failed commit the log lines are
  withheld and counted on stderr. Log lines live beside the effect log, not
  in the journal, so a redo by another process never prints this run's
  lines. `print` is unchanged: it happens when called and repeats on retry.

Tests: `tools/sol-txn-check.sh` legs 6 to 9 (a failed `rmdir`, a replay made
to fail on its second file and then read by a different script, two
concurrent runs of one script with the first killed mid-commit, and
`SOL_FORCE_RETRY=2` with one `print` and one `log`).
`tools/sol-safety-check.sh` now injects its journal-write failure by making
the script's directory read-only. A directory named after the journal cannot
be used for that any more, because the journal name is per run.

Not changed: the smaller points in SOL-EFFECTS (mode/symlink preservation in
`writeAtomic`, `Deferred a`), and `log` to a path. `log` goes to stdout only.

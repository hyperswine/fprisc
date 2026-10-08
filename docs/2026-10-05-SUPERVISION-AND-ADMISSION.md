# Supervision and admission: the rules today, and the open questions

Kind: questions for decision, with the facts they rest on. Written
2026-10-05, before phase 3 of `2026-10-04-C-REDUCTION-PLAN.md` moves the
policy of a failing actor and of spawn admission out of C. Nothing here is
decided. Where a question has an obvious default it is marked
**Suggested**; that is a proposal, not a decision.

Paths: `runtime/` and `std/` are this repository; `Q/` is `../qos`.

## Part 1: when an actor fails

### How an actor ends today

| Cause | Ends | Logged | Who learns |
|---|---|---|---|
| a primitive that cannot complete (`fpr_actor_fail`: fixed heap exhausted, a function of another image in a send, disk offline/timeout/I/O error, NIC stalled or absent, a non-owner calling the network bridge, ...) | the actor | `actor failed: <why>` (error ring) | its watchers: `Err "dead actor"`, no reason |
| `fpr_actor_fail` in the boot actor (id 0) | the machine | panic | - |
| `fpr_actor_fail` in a loaded process | that process actor (routed through `fpr_sched->fail`) | as above | the launcher: "process failed: dead actor" |
| the language's `error` | **the machine**, from any actor | panic | - |
| stack overflow (the `fpr_stack_max` ceiling, or no memory to grow) | the machine | panic | - |
| heap exhaustion in an ordinary pool | the machine | panic | - |
| plain `spawn` cannot get a stack, buckets, a channel block or rings | the machine | panic | - |
| `kill a` | the actor (at its next safepoint if running elsewhere) | nothing | its watchers, no reason |
| the body returns | the actor | nothing | its watchers |
| the deadlock detector (all harts idle, nothing can wake anyone) | the machine | dump to the raw console, then panic | - |

How others learn of a death: `receiveFromRes`, `receiveRes` and the
`std/actor` calls (`call`, `callSure`, `awaitFrom`, ...) answer
`Err "dead actor"`; `send` to a dead actor answers the same; `Sys.alive a`
polls. Nothing is SENT on a death: there is no notification to a parent or
a monitor, and the `parent` field is read only by diagnostics. Plain
`receiveFrom` from a dead sender waits forever. The reaper runs one cleanup
hook per actor (`fpr_actor_cleanup_set`; a second one panics), returns the
memory, and tells the QOS loader when a pid goes quiet so the image can be
freed.

### Supervision that already exists, service by service

- **Files** (`Q/std/fs.fpr`): a stable owner with a replaceable Qlog child.
  A transport failure kills the child and answers the request with an
  error, with no replay; the NEXT request starts a replacement, once; if
  that fails the owner latches offline. Quiesce latches shutdown. "Demand-
  driven ... rather than a background crash loop."
- **Network** (`Q/std/net.fpr`): one owner installed by compare-and-swap.
  "A failed owner stays installed and is never replaced or replayed."
- **Block I/O v2**: a disposable worker plus a relay that turns the
  worker's death into a `Result`; cancel kills the worker and answers
  "outcome unknown".
- **The block HAL**: offline is terminal; reprobing is "a separate
  administrative act" that does not exist yet.
- **System boot** (`Q/programs/system.fpr`): a service that fails to start
  is logged offline and boot continues. No service is ever restarted.
- **The loader**: a refused load is rolled back, not retried.
- **Hosted panics**: `fpr_panic_persist` writes `sys/panic` so that "a
  crash-restart loop stops destroying its own evidence".

So the existing rule, written nowhere as one: **fail-stop, tell whoever is
waiting, never replay, restart only on demand and only once, latch
offline after that.**

### Found while writing this down

- **A killed actor that is BLOCKED is never reaped.** `a_kill` marks it
  dead and wakes its watchers but does not wake or queue IT, and the
  reaper only runs on actors the scheduler dequeues. Measured: 2,000 actors
  that end normally needed 123 fresh channel-block carves; 2,000 killed
  while blocked in `receive` needed 250 -- one per eight actors, none
  reused. Their stacks, pools and channel blocks leak. This is a C
  mechanism bug, independent of any policy, and any supervisor that
  restarts things would hit it on every restart. **Suggested:** fix first.
- `kill` checks nothing: any actor may kill any other, including actor 0.
- `fpr_actor_fail` cuts its message at 199 bytes without a mark
  (`char msg[200]`); the stack-overflow message at 127.
- The memory-admission page says an occupied cleanup slot makes
  `spawnHeap` refuse; the code panics ("actors: nested external request").

### Open questions

**S1. Which failures should end only the actor?** Today `error`, stack
overflow, ordinary heap exhaustion and a failed plain spawn halt the
machine, from any actor. `Q/docs/2026-10-02-FAILURE-INJECTIONS.md` calls
`error` "deliberately a panic". Should any of them become fail-stop of the
one actor (with the machine panicking only in actor 0, as
`fpr_actor_fail` does)? Each one moved changes what a program can
survive, and makes the supervisor's job bigger. **Suggested:** stack
overflow and heap exhaustion first (they are resource failures, like the
ones that already fail-stop); keep `error` a panic until there is a
reason to catch it.

**S2. What does a death carry?** Watchers get the static string
`"dead actor"`; the reason goes only to the log. Options: keep the reason
on the dead actor so `receiveFromRes` can answer
`Err "dead actor: disk offline"`; or a structured `Dead reason` value; or
leave it. The reason would be held until the actor's last watcher has
read it. **Suggested:** carry the reason as a String.

**S3. Should a death be SENT to someone?** Today it is only observed by
whoever is already waiting. Options: (a) nothing new; (b) a monitor --
`Sys.monitor a` sends one message to the caller when `a` ends, with the
reason; (c) the parent always hears; (d) one system supervisor hears every
death. (b) needs a list of monitors per actor, which the current single
`watch` slot is not. **Suggested:** (b), with the supervisor as an ordinary
monitor.

**S4. Who restarts what?** Options: (a) no general supervisor -- each
service keeps its own policy, as Files and the network do, and std offers
helpers; (b) a supervisor library (`std/supervise`) that a service uses for
its own children, with declared strategies (one-for-one, give up after N);
(c) a system supervisor that restarts registered services. The design note
on the Base library puts supervision helpers in packages, not in minimal
Base. **Suggested:** (b), with the existing rule as its default strategy:
on demand, once, then latched offline.

**S5. What state does a restarted actor start with?** Every service today
refuses to replay. Is that the rule for all restarts (fresh state, callers
told their request failed), or may a service declare that its requests are
idempotent and may be retried? **Suggested:** never replay unless the
service declares it.

**S6. How is a crash loop stopped?** If anything restarts automatically:
how many restarts in how long before giving up, does the interval grow,
and what does "giving up" mean (latch offline, tell the parent, panic)?
The answer must be a run-time parameter, not a constant.

**S7. Who may kill, monitor or supervise whom?** `kill` is unchecked today,
and the network's "stop" and the block service's "administrator" are a
check on the caller's handle -- "a cooperative message convention", not
a boundary. Options: the parent (spawner) only; the same pid only; a
capability handed out at spawn. Should actor 0 and the system services be
unkillable by applications? **Suggested:** at least refuse killing actor
0, the memory actor, the log actor and the interrupt router; decide the
rest with S8.

**S8. Processes.** A loaded process's root failing is reported to the
launcher as "dead actor". Should the launcher get the reason (S2), restart
the app (S4), and should a PANIC inside a process -- which today appears
to halt the machine, because a process image has its own copy of the panic
path -- end only that process? (Unverified; needs a test.)

**S9. What may the failing path itself do?** `fpr_actor_fail` runs in the
failing actor, from C, often inside a device primitive. To tell a
supervisor it must send a message, which may allocate (the reason) on a
pool that may be the very thing that ran out. Options: a pre-reserved
cell per actor for its death notice; a staging area like the log's (fixed,
overflow counted); or the reaper sends it from the hart loop. And if the
supervisor is dead or its mailbox full: fall back to today's behaviour
(log, kill, wake watchers)? **Suggested:** the reaper sends it, from the
hart loop, as an Int-and-staged-string like the log.

**S10. Bootstrap.** Actor 0, the memory actor, the log actor and the
interrupt router must not need the supervisor to start, and the supervisor
must not need any of them to report its own failure. If the supervisor
itself fails: panic, as actor 0 does?

## Part 2: admission -- who gets how much at spawn

### The rules today

A1. **Plain `spawn`, `spawnOn`, `spawnCap` are not admitted.** They take
an ACB, a stack, buckets, the entry copy and a channel block one at a time,
and any failure halts the machine ("spawn: buddy has no free block", "no
memory for a bucket array", "no memory for a channel block", "no memory for
the mailbox rings").

A2. **`spawnHeap bytes f` is all-or-nothing.** In order: the reply cell,
the cleanup hook, the grant (`bytes` plus the slab header), the stack, the
buckets, the channel block, the entry copy, the ACB; then the child is
published. Any failure rolls back everything in reverse and answers
`Err "fixed heap: admission denied"`. Bad arguments answer `"bytes must be
positive"`, `"entry must be a function"`, `"grant too large"`. A failed
spawn changes no counter and no ledger.

A3. **The grant covers only the child's heap.** Stack, mailbox, channel
block, entry copy and ACB are not charged to it. Overrunning it fails the
child alone (`"fixed heap: local grant exhausted"`); a scratch arena inside
it is refused (`"scratch arenas require separate admission"`); a reset
while data has escaped is refused (`"reset blocked by escaped data"`).

A4. **The only check is "does the buddy have a block".** There is no
total, no per-process, per-app or per-actor budget. The memory actor owns
the buddy and applies no policy beyond availability.

A5. **Escaped data keeps its grant alive.** A value that leaves a fixed
heap keeps the whole grant until every reference and borrow ends.

A6. **The mailbox is separate from memory.** `spawnCap Static n` never
grows; `Dynamic n` doubles to `RING_MAX` (2^20), then sends fail. `n` is
rounded to a power of two and clamped to 8..2^20 **silently**. On QOS's
shared plane the mode and size were **silently ignored** until 2026-10-08;
they now go through the plane's actors table (`2026-10-08-PLANE-TABLES.md`,
tested by `Q/tools/mailbox-process-check.sh`). `spawnHeap` always gets the
default static ring of 64.

A7. **Stacks grow without admission** from 128 KiB (256 KiB in QOS apps)
by doubling, to `fpr_stack_max` (1 GiB; `FPR_STACK_MAX_MB`, read once at
start, a bad value silently ignored). Hitting it halts the machine.

A8. **`Sys.spawnApp`** gives a fresh pid and adopts the image, with no
heap admission. A QOS process image gets one buddy block at load
(`"no memory for the image"`), and then "a process may grow without
count". Manifests grant namespace paths only; they say nothing about
resources.

A9. **Who can change what:** build flags (`FPR_STACK_SZ`, `FPR_SLAB_SZ`,
QOS's `QOSSTACK`/`QOSSLAB`), environment variables read once
(`FPR_HEAP_MB`, `QOSP_ARENA_MB`, `FPR_STACK_MAX_MB`), and spawn arguments.
Nothing is adjustable at run time. (The block service's time budgets are
the one versioned, run-time, creator-only configuration in the tree.)

A10. **Bootstrap:** actor 0 is built statically; the memory actor is
spawned the ordinary way, pinned to hart 0, and takes its own memory
directly; a process's root is spawned by the loader, not admitted.

Sol's `spawnHeap` always answers `Ok` and enforces nothing.

### Recorded elsewhere

`2026-10-03-MEMORY-ADMISSION.md` leaves open "one combined region or a
declared total actor budget", and says the memory policy owner is still the
C memory actor. `2026-10-02-ACTOR-MEMORY-LIFECYCLE.md` asks for "an
explicitly reserved non-parking mechanism" for boot, interrupt and reaper
paths. `../qos/docs/2026-10-03-RESOURCE-ACCOUNTS.md` (a draft, not
implemented) proposes system -> app -> actor accounts where "spawning
children cannot manufacture capacity", escaped data stays charged to the
original account, and a limit cannot be lowered below what is outstanding.
`2026-10-02-RESOURCE-BOUNDS.md` proposes tying the compiler's `live` bounds
to mailbox capacity.

### Open questions

**Q1. Should every spawn be admitted?** Plain `spawn` halts the machine
when memory runs out. Making it answer instead changes its type (it returns
an actor today) or needs a second form. Options: `spawn` stays as is and
`spawnRes` answers a `Result`; or `spawn` fail-stops the SPAWNER instead
of the machine (S1). **Suggested:** the second -- no API change, and the
spawner is the one that asked.

**Q2. What does a grant cover?** Only the heap today. Should it be a
composite -- heap, stack ceiling, mailbox, the control blocks -- so a
declared budget is the actor's whole footprint? The memory-admission page
says a fixed total "is credible only when none of those hidden paths can
obtain uncharged backing memory": stack growth, mailbox growth, message
slabs and the ARC table all can today.

**Q3. Against what is a request checked?** Only buddy availability.
Options: (a) leave it; (b) the RESOURCE-ACCOUNTS hierarchy -- the machine,
then each app/process, then each actor, where a child's grant comes out of
its parent's; (c) a machine-wide reserve kept back for the system services
so an app cannot starve the log actor or the memory actor.
**Suggested:** (c) now, (b) when there is a manifest field for it (Q8).

**Q4. Who sets the rules, and when?** Today: build flags, environment
variables read once, spawn arguments. Moving them into an admission actor
makes them messages. Who may send them -- the creator (as the block budgets
do), pid 0, a capability? Versioned like the block budgets, so a stale
change is refused? Can a limit be lowered below what is outstanding (the
draft says no)?

**Q5. Silent clamps.** The mailbox size is rounded and clamped silently,
and a bad `FPR_STACK_MAX_MB` is ignored silently (the shared plane honours
the mailbox policy since 2026-10-08). The bounds rule says limits are never
silent. Refuse instead? **Suggested:** refuse a size outside 8..2^20 and a
bad environment value by name.

**Q6. Growth after admission.** Which growth is admitted, and against
which budget: stack doubling, Dynamic mailboxes, outgoing message slabs,
the ARC table, a process's `loader_grow_memory`? "Fixed" already means no
further backing during ordinary execution; is "growable" an explicit
initial and maximum for each, as the lifecycle page proposes?

**Q7. Who pays for escaped data?** Today the child's grant stays alive
until the last reference ends. The draft charges it to the original
account. Should the receiver be able to take ownership (and the charge)?

**Q8. Processes and apps.** There is no per-process budget and the
manifest has no resource fields. Should a manifest declare memory (and
mailbox, stack) the way it declares paths, granted or refused at launch by
the same prompt? Who may raise it afterwards?

**Q9. When memory is short.** Today an ordinary pool that cannot grow
halts the machine. With admission, what happens under pressure: refuse new
spawns, fail the actor that asked (S1), ask a service to shed, or reclaim?
Who decides which actor goes first?

**Q10. What stays mechanism, and what does it cost?** The plan keeps
reserve, commit and rollback in C and moves the decision to an FP-RISC
admission actor. A spawn would then be a message round trip (the log
showed one costs about 1-2 us). Is that acceptable for every spawn, or only
for `spawnHeap` and processes, with plain `spawn` checking a C counter the
admission actor sets?

**Q11. Bootstrap.** Which spawns never wait on the admission actor: actor
0, the memory actor, the admission actor itself, the log actor, the
interrupt router, the network and storage owners started before apps? Is
there a control reserve they draw from, separately counted, so they cannot
be starved by apps -- and so the admission actor's own failure cannot stop
the machine from logging it?

**Q12. Sol.** Should Sol's `spawnHeap` enforce its grant, or say plainly
that it does not?

## What to decide first

1. The killed-blocked-actor leak (fix; no decision needed).
2. S1 and Q1 together: which resource failures end only the actor that
   asked. Everything else builds on it.
3. S2/S3: what a death carries and who is told -- the supervisor's input.
4. Q3/Q4: where budgets come from and who may change them -- the admission
   actor's input.
5. Then S4-S6 (restart policy) and Q2/Q6 (what a grant covers), which can
   follow one service and one budget at a time.

## Fixed: a killed blocked actor is reaped (2026-10-05)

`a_kill` now changes the state with a compare-and-swap and, when the actor
was BLOCKED, hands it to its owner hart (`ship`), as a wake does. Only the
owner hart dequeues it, so it has switched out before `deq` or the backlog
scan reaps it; `reap` already had the branch for "a killed parked actor"
that nothing ever reached. Killing an actor that has already ended is now a
no-op (its watchers were woken when it ended).

Measured with `tests/base/killblocked.fpr` (free buddy memory before and
after 1,500 kills of actors blocked in `receive`): about 100 MB lost before,
under 4 MiB after on one hart. On four harts about 9 MB, settling rather
than growing -- 7,500 further kills cost about 16 MB more in falling steps,
where the old code would have lost about 530 MB -- which is per-hart caches
and the cross-hart channel-block epoch filling, not a leak.

A consequence worth knowing: a killed blocked actor's cleanup hook
(`fpr_actor_cleanup_set`) now RUNS. Before, it never did, for exactly the
actors QOS kills on purpose -- the Files owner's Qlog child, a cancelled
block I/O worker, a losing network candidate.

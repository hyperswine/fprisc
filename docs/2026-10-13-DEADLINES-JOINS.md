# Live-service deadlines and owned task joins

Date: 2026-10-13. Base/ExtBase implementation, with QOS Native process and
physical Pi 4 validation recorded in the sibling QOS document.

## Contracts

`receiveFromNow me sender` selectively returns `Ok message`, `Err "empty"`,
or `Err "dead actor"` (since 2026-10-15 `Err "dead actor: <why>"` when the
sender failed or was killed, built on the caller; the bare text for a
return is static). Empty Results are static. It preserves unrelated
messages and per-sender FIFO, including the shared overflow ring. A queued
reply is drained before the sender's death is reported. Successful receives
have the same keep/drop and automatic-turn rules as `receiveFromRes`.
The primitive is also available in Sol.

`std/actor.callWithin ms` and `callSureWithin ms` share an absolute monotonic
microsecond deadline across admission and response. `callUntil` and
`callSureUntil` take that absolute deadline directly. Stale correlation IDs
are discarded without renewing the budget. Durations below zero or too large
for the clock addition are refused; zero expires before admission.

- Checked sends preserve immediate `mailbox full`/`dead actor` refusals.
- Retrying admission ends with `deadline exceeded before admission`.
- An admitted request without a timely answer ends with
  `deadline exceeded (outcome unknown)`. Timeout never automatically replays
  or cancels the service's operation.
- Late correlated replies cannot satisfy a later call on the same service.

Legacy replies contain no correlation ID. `session owner` provides a reusable
return address and `sessionCallUntil` supplies it to a request constructor.
A failed session sends its final Result and retires; the owner waits for that
final Result/death and kills the session at normal shutdown. Late bare replies
then target a dead inbox. `sendAwaitUntil` is the lower-level form, only safe
when its receiver retires after a timeout. Do not retry a raw legacy wait on
that same return address.

MVU owns one reusable session and one render worker per run, with no helper
identity per frame/request. Existing runners select a five-second budget;
`runResultWithin`, `runLiveResultWithin`, `runWithResultWithin` and
`runWatchedWithin` allow a millisecond budget. Dimensions get one budget;
all input polls and subscribed ports in a collection share another; each
render worker callback/backend round trip shares one. Failure stops owned
helpers and returns a Result. Watched runs also stop their watcher and port.
External service actors remain caller-owned.

`std/task.map`/`mapBounded` own a collector inbox and every worker handle.
The collector polls only its workers, detects a worker that ends without
replying, cancels remaining workers, and retires its inbox. It preserves input
order, refills whichever slot completes, and respects the concurrency limit
(zero unlimited; negatives refused). `mapWithin`/`mapBoundedWithin` bound the
whole batch, including queued inputs. Owner death also cancels its workers.
The caller's unrelated messages remain queued. Prelude `par2` checks admission
and watches its specific worker, producing a named error on worker death.

## Runtime repairs required by these paths

A timeout campaign exposed dead actor reclamation under the scheduler's
backlog lock. Cleanup can wake the memory actor on that same hart and re-enter
admission, deadlocking the lock. Selection now unlinks the actor, unlocks,
reclaims, and restarts its scan. A teardown claim prevents competing reapers
from reclaiming the same migrated sleeper; running actors are deferred.
A deterministic C regression asserts that cleanup may re-enter admission.

Concurrent string replies also exposed a per-hart formatting-buffer race:
allocating the result string can park its actor while another actor overwrites
the buffer. `str` snapshots the bytes on the actor's stack before allocation.

Loaded process scratch loops previously used a disabled local allocator.
Scratch arena/loop/loopWith execution now routes through the memory plane,
keeping scope cleanup, transfer slabs, ARC locking and recyclers together.
Actor-plane ABI and memory-plane ABI are both **2**; native ABI remains **6**.
Native process archives and their plane must be rebuilt together. Legacy plane
ABI 1 archives are rejected before placement.

## Verification and boundaries

`tests/check_deadlines.py` runs selective/FIFO/overflow, queued-before-death,
static empty polls, admission deadlines, stale streams, late correlated/bare
replies, live MVU service/worker stalls, watched cleanup and healthy subsequent
runs on one/four harts. It also checks task worker fail-stop, sibling and owner
cancellation, total batch deadlines, concurrency, ordering, unrelated mail,
failed-join retention after warm-up, and named `par2` failure. Sol exercises
selective empty/live-timeout/dead results. `tests/check_actor_reap.py` forces
cleanup to re-enter admission. The watched-timeout campaign also passes sixty
consecutive four-hart host runs after reproducing the former hang.

These are cooperative deadlines, subject to scheduling and allocator progress;
they do not preempt arbitrary synchronous update/reload callbacks, blocking
foreign code or memory admission. Cancellation marks workers dead but does not
prove that external I/O or side effects have stopped. Base panics still halt
the program; fallible jobs should return Results. Permanent actor identities,
plain-spawn allocation failure, admission/restart policy and universal deadlines
for other service APIs remain separate boundaries. Failed runs/batches consume
identities, so finite retention checks do not prove an infinite restart soak.

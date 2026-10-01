# Actor result loss during channel claim

The rare `receiveRes` hang reported on macOS arm64 with ten harts has a
concrete message-loss interleaving in `runtime/actors.c:chan_for`. It does not
require the base-profile inliner or a broken block/wake fence.

## The interleaving

1. Senders A and B both observe a dedicated channel with `sender == 0` and
   remember it as their free candidate.
2. A resets the counters, wins the sender CAS, queues its Result, publishes
   `rt = 1`, calls `wake`, and can finish.
3. B resumes with its stale candidate. Before attempting its CAS, it writes
   `rh = rt = 0`. Its CAS then loses to A and it retries elsewhere.
4. A's successfully queued Result is now outside `[rh, rt)`. The receiver can
   consume every other result and then block forever; the missing worker is
   already dead. `sendSure` correctly reported successful queueing at step 2.

This explains how a receiver can be BLOCKED waiting for a Result with all its
workers DEAD: a successful send was erased after publication, rather than its
wake being lost. The reported executions themselves were not captured here;
this interleaving was reproduced deterministically against the original code.

## Repair

Channel counters and mailbox policy are initialized by `chan_init` and the
spawn/boot setup before the actor is published. Claimants now only CAS the
sender key; they never write counters or policy before owning a channel.
Reclaimed dead-and-drained slots retain their monotonic head and tail,
including across wraparound. Reclamation reads the consumer's head with
acquire, matching `take_at`'s release. Mailbox scans use acquire loads for
sender publication, instead of mixing ordinary reads with the sender CAS.

The existing seq_cst publish/fence/wake and block/fence/recheck pairing is
retained. A sender-key change cannot hide a nonempty channel: reclamation
requires a dead sender and a drained ring. `take_at` shifts only the occupied
head side; growth takes the same lock as that shift, and old ring storage is
retained. The shared overflow ring is already bound and does not execute the
unbound-counter reset. `receiveFromRes` watchers only add wakes and never
alter channel counters; `receiveRes` does not register those watchers.

The detector and donation queues are unchanged. A delayed shipped wake makes
the actor READY; it does not itself explain the reported BLOCKED result waiter
with every task worker DEAD. This repair is not a general proof against false
deadlock detection under arbitrary host suspension.

## Regression and validation

`tests/check_actor_claim.py` compiles the actual runtime source in a small C
harness, inserting a scheduling hook into a temporary test copy only. It pauses
the losing claimant after selecting a candidate, runs the winner through claim
and Result publication, then resumes the loser. The original runtime fails
`ch_count == 1`; the repaired runtime preserves the Result and passes `p_res`
and `take_at`. The same test covers dead/drained reuse at `UINT32_MAX`,
refusal to reclaim a dead sender's nonempty channel, and middle removal with
unrelated events and sender tags in both dedicated and shared rings across
counter wraparound.

`tests/base/taskstress.fpr` is the reported SHA workload: eight workers over
forty rounds, checking each parallel digest list against the serial list.
`tests/check_base.py` runs it with and without the inliner, on one and four
harts, then twelve processes per setting with ten harts, six concurrent.
`FPR_ACTOR_STRESS_RUNS=120 python3 tests/check_base.py` increases this to
120 processes per setting (240 loaded runs, 76,800 worker results), with
300-second per-process timeouts. Exit status and exact output are checked.

On macOS arm64, `make fpr`, the deterministic harness, the complete base suite
with `FPR_ACTOR_STRESS_RUNS=120`, and the complete standard-library suite passed.
All 240 ten-hart loaded stress executions produced `shastress: 40`, with no
nonzero exits or timeouts. The existing receiveFromRes regression also passed
3,000 reply/death pairs each on one, four and eight harts. This is hosted arm64
validation; other architectures were not executed for this change.

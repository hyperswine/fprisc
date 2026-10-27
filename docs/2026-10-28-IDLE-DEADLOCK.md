# An idle posix program is declared deadlocked (open)

**Status: open.** The memory-actor hypothesis is ruled out (second catch,
2026-10-27); the evidence now points to another thread touching hart 0's
sleeper bookkeeping. Reproduced with a 20-line program, so the bug
is in the runtime, not in any application. Found through qrepo's server
(`qr serve`) on the Mac mini, which has hit it 14 times since 2026-10-04.

## Symptom

A posix program built with `--harts 2` that waits in `std/tcp`'s `accept` (no
connections arriving) panics after hours of idling:

    [ERR] actors: deadlock -- every hart idle, someone blocked, nothing moving
    *** FPRISC PANIC [actor 900]: actors: deadlock -- every hart idle, someone blocked, nothing moving ***

The detector is right that the program can no longer make progress: the main
actor is blocked and nothing will ever wake it. The bug is how it got there.

Idle time before the panic, from qrepo's server (which now records its last
step before a stop): 12.5 h, 57 h and 12.5 h in the last three. It happens
only while idle in `accept`; no request was in progress in any recorded case.
The mini never sleeps (`pmset` sleep 0) and its power log shows nothing at
those times, so system sleep and wake are not the trigger.

## Every dump looks the same

From qrepo's release build (fprisc 493f234), 2026-10-26 21:27Z:

    dl: actor 1 hart 0 pinned BLOCKED waits any holds 0 parent 0
       trace: 4.0 5.0 7.0 10.0
    dl: actor 0 hart 0 pinned BLOCKED waits any holds 0 parent 0
       trace: 5.0 7.0 12.0 10.0 1.0 4.0 5.0 7.0 12.0 10.0 1.0 4.0 5.0 7.0 12.0 10.0
    dl: hart 0 idle current 0 phase 3 turns-in-quiet-window 13 in-wfi-for-ms 154
    dl: hart 1 idle current 0 phase 4 turns-in-quiet-window 13 in-wfi-for-ms 110

The same two actors, states and traces appear in all 14 dumps, across the
2026-10-04 build and the 493f234 build. Trace codes are the `TR(a, code)`
sites in runtime/actors.c (`code.hart`):

- 1 `wake` won the BLOCKED -> READY CAS (16 would be a lost CAS)
- 4 admitted to the backlog, 5 selected from it, 7 popped from the run queue
- 10 parked in `block_unless`, 12 resumed after parking

- **Actor 0 (main)** loops `5 7 12 10 1 4`: run, park, woken, admitted. That
  is the `Sys.sleepUs` backoff in `Tcp.accept` (100 us doubling to 4 ms), with
  each wake coming from `slp_drain`. Its last entry is `10`: parked, and
  never woken again. No `1` or `16` follows, so **no wake was even
  attempted**.
- **Actor 1** has four transitions in its whole life: admitted, run, parked
  once at startup. It is almost certainly the memory actor (`mem_act`, the
  first spawn after boot, pinned to hart 0). It is reached only when
  `buddy_alloc_try` finds `buddy_lock` held, which is why it never runs in an
  idle program.

## The one diagnostic catch

Dump-only extra lines (`deadlock_dump_sleepers`, below) caught it once, on
2026-10-23 at 09:23Z, in the minimal reproducer after 8.7 h:

    dlx: now 5005797482880 g_sleepers 0 g_blocked 2 g_irq_waiting 0 g_activity 5713170
    dlx: actor 1 slp_on 0 slp_hart 0 wake_at-now -5005797482880 waits_sleep 2 running 0 in_bl 0 in_rq 0
    dlx: actor 0 slp_on 0 slp_hart 0 wake_at-now -20199210 waits_sleep 2 running 0 in_bl 0 in_rq 0
    dlx: hart 0 sleepers:
    dlx: hart 1 sleepers:
    dl: actor 0 hart 0 pinned BLOCKED waits any ...   (as above)

(`waits_sleep 2` meant "wait_kind is 1 and p_sleep is already true". For actor
1 that only reflects `wake_at` = 0, since it never slept.)

What it shows:

- No actor is on any sleeper list, and `g_sleepers` is 0, so the detector's
  `slp == 0` test is truthful.
- Actor 0's `wake_at` passed 2.02 s before the dump. That is the detector's
  window (`DETECT_WINDOW`, 2 s, plus samples). So **its last sleep ended
  normally**, and it was unlinked properly. The block that never ends came
  after that sleep, in some other wait with `wait_kind` 1.
- Both actors are off every queue (`in_bl 0`, `in_rq 0`, `running 0`).

In an idle `accept` loop the only `wait_kind`-1 waits actor 0 can enter are
`p_sleep` (runtime/actors.c, `a_sleep_us`) and `p_mem` (`fpr_mem_take`, when
the buddy lock is busy). `p_any`, a plain receive, is not on this path.

## The second diagnostic catch (2026-10-27 18:37Z): not memory

The dump-only build (no ACB fields, nothing on a hot path) caught it in the
reproducer `idle10`, about 3 h into its run (16 copies):

    dlx: now 8794386623190 g_sleepers 0 g_blocked 2 g_irq_waiting 0 g_activity 5676766
    dlx: mem reqs 0 waits 0 inline 1 direct 13 frees 0 denied 0
    dlx: actor 1 (memory actor) slp_on 0 slp_hart 0 wake_at-now -8794386623190 sleep_due 1 mem_reply 0 wait_arg 0 running 0 in_bl 0 in_rq 0
    dlx: actor 0 slp_on 0 slp_hart 0 wake_at-now -20272050 sleep_due 1 mem_reply 0 wait_arg 0 running 0 in_bl 0 in_rq 0
    dlx: hart 0 sleepers:
    dlx: hart 1 sleepers:
    (dl: lines identical to every other dump)

- Actor 1 **is** the memory actor, and it has never been sent a request
  (`fpr_mem_reqs` 0). Actor 0 is not waiting on memory (`mem_reply` 0).
  **Hypothesis 1 below is ruled out.**
- Actor 0's last sleep was due 2.03 s before the dump (the detector's
  window), `p_sleep` is true now, and it is on no sleeper list. Its last
  transitions are `12 10`: resumed, then parked, with no wake (`1`) or failed
  wake (`16`) after the park.
- Off this code path the only `wait_kind`-1 wait left is `p_sleep`. So actor
  0 is **parked in a sleep after leaving the sleeper list**, with its
  deadline already passed and nothing left to wake it.

On one thread that cannot happen: `a_sleep_us` links before it parks,
`block_unless` re-checks `p_sleep` after setting BLOCKED, and only hart 0's
loop drains hart 0's list. So **something touches hart 0's sleeper list, or
actor 0's `slp_on`/`var`, from another thread.** One way: a thread acting as
hart 0 that is not (`fpr_hart()` is the x28 register; compare
docs on the x28 migration bug). It drains hart 0's list while actor 0, on
the real hart 0 thread, sits between its link and its park, or the reverse.
`TR` is a plain `tr[tr_i++ % 16]` from whichever thread runs it, so the same
race can overwrite the one trace entry (`16` or `1`) that would have shown
it.

Next experiment: record in each hart struct the pthread that runs it, and
check `pthread_self()` against it in `slp_drain`, in the link in
`a_sleep_us`, and in `wake`'s ship. One compare each, a panic naming both
threads on a mismatch. If the hypothesis is right, the next catch names the
culprit instead of a deadlock.

## Hypotheses (before the second catch)

1. **A memory request whose wake is lost.** Actor 0 allocates, finds
   `buddy_lock` held, posts to the memory actor (`mem_post`: `ring_push`, a
   seq_cst fence, `wake(mem_act)`) and parks on `p_mem`. That fits "rare"
   (it needs the lock held at that instant) and "after hours" (it needs an
   allocation that misses the pool). It does not fit actor 1's trace: a
   successful `wake(mem_act)` records `1` and a failed CAS records `16`, and
   neither is there. Unless the request never reached `wake`, or actor 1 is
   not the memory actor. Who would hold `buddy_lock` in an idle program is
   also unexplained, since hart 1 has no actors.
2. **A sleep entered without being linked.** If the parked wait is `p_sleep`
   with `slp_on` 0 and `wake_at` in the past, `block_unless` should have
   seen `p_sleep` true and returned, so this needs a path where the
   predicate is checked against a different `wake_at` than the one that is
   stored. None has been found.

Code reading has ruled out:
- the actor running on the other hart while hart 0 drains its sleeper list
  (actor 0 is pinned, and `steal_from` skips pinned actors)
- a missed sleep wake (`block_unless` re-checks the time-based `p_sleep`
  after setting BLOCKED, so a late wake corrects itself)
- packed fields in the ACB that two threads could clobber (all word-sized or
  atomic 32-bit)
- `Os.run` and `flock` (they block the hart thread, which then is not idle)
- `IO.ready`/`Os.accept`/`Os.ready` (non-blocking `poll`/`accept`)
- the detector itself (identical in the 2026-10-04 and 493f234 builds)

## The instrumentation changes the outcome

- Dump-only lines: 1 catch in about 140 process-hours (16 processes).
- Adding fields to `acb_t` (predicate pointer, link/unlink counters,
  `hal_mtime` stamps in `slp_drain` and the self-unlink): **0 catches in
  about 1,300 process-hours**, while the uninstrumented production server hit
  it twice in the same days.

So the bug is sensitive to ACB layout or to timing in the sleep path. That
points to a race with a narrow window, not to a logic error on a common path.

## Reproducing

`idle.fpr` (built `fpr build idle.fpr --system=posix --harts 2 -o idle`):

    Program = use "std/program".
    Tcp = use "std/tcp".
    S = use "std/string".

    main = case Program.args Unit of
        [port] -> (case S.toInt port of
            Ok p -> (case Tcp.listen "127.0.0.1" p of
                Ok l -> _ = Sys.stderr "idle on {port}\n"; waitLoop l
              | Err why -> Program.fail 1 why)
          | Err _ -> Program.fail 2 "port")
      | _ -> Program.fail 2 "usage: idle PORT".

    waitLoop : unsafe Tcp.Listener -> Unit .
    waitLoop l = case Tcp.accept l of
        Ok _ -> waitLoop l
      | Err why -> Program.fail 1 why.

Run many copies at once and wait. On the mini, `~/dlhunt/hunt.sh` runs 12 of
these plus 4 `qr serve` instances on loopback ports, restarting each that
dies, with timestamped logs in `~/dlhunt/logs` and deaths in
`~/dlhunt/deaths.log` (stop: `pkill -f hunt.sh; pkill -x idle; pkill -f
qr-diag`). The 2026-10-23 catch is in `~/dlhunt/caught/`. Since 2026-10-27
the hunt runs a dump-only build (a clone of 493f234 in qrepo's
`deps/fprisc-diag`, git-ignored). It adds `deadlock_dump_sleepers` to
`deadlock_dump`: the sleeper and memory counters, and per actor `slp_on`,
`wake_at`, `p_sleep`, `mem_reply`, `wait_arg`, and which actor is `mem_act`.
That would settle hypothesis 1: `mem_reply` == `MEM_PENDING` on actor 0.

A machine that sleeps and wakes in between is not needed, and a single
process takes days; 14 copies reach it in hours.

## Next steps

1. Catch it with the dump-only build and read `mem_reply` / `fpr_mem_reqs`.
2. If it is `p_mem`: trace `mem_post` -> `wake(mem_act)` against the memory
   actor's `mem_next` park (`block_unless(a, p_any, 0)` after scanning
   `ch[]`). Check that a channel created by `chan_for(mem_act, key, 1)` for a
   first-ever requester is visible to a `p_any` scan already parked on the
   old channel set, and that `ring_push` publishes before the scan's fence.
3. If it is `p_sleep`: find the path that parks with the predicate already
   true.
4. Add the reproducer to the host suites as a soak check once the fix is
   known (long-running, so not in the default suite).

## Mitigation in qrepo

Since 2026-10-28 qrepo's server waits for connections the way `std/tcp`'s
`serveOn` does, with `Poller.awaitResult` on the listener and then a
non-waiting `Os.accept`, keeping its one-request-at-a-time loop. Idle, its
main actor is parked in its mailbox while `os_watch.c`'s thread waits in
poll(2), so it makes no sleeps and no allocations and is off the path above.
Measured on this Mac over 30 s idle: 0.36 s of CPU for the sleep-polling
server, 0.09 s for the poller one (what remains is the detector's own 30 ms
timer); a request after an idle spell is answered in about 10 ms. The runtime
bug is unchanged, and the reproducer above still exercises it. Any program
idling in `Tcp.accept` (or in `ST.readWithin`, `Sys.sleepUs` loops) is still
exposed.

# A full drop-park list freed a message slab twice (27 November 2026)

Kind: bug record. Branch `fix/drop-park-double-free`. Found while investigating the QOS GUI shell
freezing in Files, on the Pi 4B and on the desktop (qos
`docs/2026-11-27-PI-GUISHELL-SDK-0.6.1-INSTALL.md`, "Files freeze and app reset").

## Symptom

- **On the Pi:** the GUI froze with SSH still responsive. Three QOS harts stayed runnable at full
  CPU, with no I/O, no panic and no kernel fault.
- **On the desktop:** the same shell binary (identical `app.qa` SHA-256) also crashed sometimes,
  with `SIGSEGV addr=0x1` inside the buddy allocator.

Both came from corrupted buddy free lists. A free list with a cycle makes the next scan in
`buddy_free_locked` loop forever under `buddy_lock`, and every other hart then spins on that lock.
A block that sits on a free list twice is handed out twice, and the stray header word then breaks
a later allocation.

## Cause

When an actor drops the last promoted root that points into an ownerless message slab, the
runtime keeps the slab until the actor's next receive (its borrow window): `fpr_drop_park` takes a
hold and records the slab in the actor's 16-entry drop-park list. When the list was full, the old
code released the oldest entry first:

```c
fpr_slab_unhold(slots[oldest], 1);   /* the oldest entry's hold goes */
slots[oldest] = sl;
...
sl->holds++;                         /* then this drop's hold is taken */
```

The oldest entry can be the slab being parked. If that entry was its only hold, and this drop
took its last escaped root to 0, the unhold released the slab to buddy. The code then parked the
freed slab and took a hold on it. The drain at the next receive or `Sys.poolReset` released it
again.

The shell hits this when one message slab holds many roots that are dropped in one turn. Draining
the MVU message port, which is how a Files listing reaches the shell, fills the list with the same
slab. `Sys.poolReset` (`fpr_rx_release_outer`) then drops every received root at once.

**Fix:** take this drop's hold before giving up the oldest entry. When the oldest entry is this
slab, the count then stays above zero and nothing is released.

## How it was found

The freeze could not be reproduced by hand. A random-key soak of the shell (keys fed through an
`FPR_EVDEV` FIFO), run under `lldb` with an instrumented copy of SDK 0.6.1's runtime, caught it
within one four-minute run. The instrumentation:

- buddy traps on a free of a block already on a free list, records every block's last freer, and
  checks a "free" bit per block across the hart caches;
- every slab hold, unhold, escape, park, release and allocation is logged with its call chain and
  the current actor.

The first catches pointed at region code (`region_close` freeing a spare slab that a receive had
already freed). That was a downstream symptom: a slab freed twice by this bug gets reused as a
region's state slab, and the stale park entry later releases it under the region. The free-bit
check, which also sees frees that go to a hart cache, caught the first double free in the act.
Both frees were inside one `Sys.poolReset`: the full-list unhold in `fpr_drop_park`, then the
drain.

## Checks

- Same detectors, same random seeds, against the shell built with SDK 0.6.1:

  | Runtime | Result |
  |---|---|
  | unfixed | double free caught (seeds 20, 21, 22) |
  | this fix only | no fault over seeds 20 to 25 (15 minutes) |

- An earlier hold change for region spare slabs was also tried. It made no difference once this
  fix was in, so it is not part of the change.
- Sol check suite (CI-style): 38 run, none unexpected. Compiler unit tests pass. `tests/actors.fpr` and `tests/base/autodrop2.fpr` pass. (`tests/autodrop.fpr` and `tests/base/inboxownership.fpr` need link-time probes and fail to build under a plain `fpr run`, before and after this change.)

## Not done

- **No automated regression test.** The trigger is a precise order of receives and drops (one slab
  parked oldest with a single hold, fifteen others, then its last root dropped). That needs an
  actor-level harness the base tests do not have wired to a runner.
- **QOS still carries the bug.** The fix reaches QOS when its fprisc pin moves, the Portable SDK is
  rebuilt, and the Pi is redeployed.
- **Separate, also found:** opening the Editor from the desktop shell built with SDK 0.6.1 panics
  the whole shell (`Int: expected Int or BigInt`, right after `creating /home/.editor/session`).
  Not investigated here.

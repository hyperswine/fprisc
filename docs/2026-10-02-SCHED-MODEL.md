# The scheduler model: what is bounded, in what units, under what assumptions

Date: 2026-10-02. Kind: living register. `runtime/actors.c` and
`runtime/fpr.h` cite this page as `docs/SCHED-MODEL.md` since the two-tier
scheduler was written; the page did not exist until today. Applies to
revision `daf0281` and later; later changes are dated below.

## The structures

Per hart (`fpr_hart_t`, fpr.h): a FIFO run queue of at most `RQ_CAP = 4`
actors, a ready backlog list, a sleeper list, and an LCG. Only the owning
hart touches its queues.

Global: the admission counter `g_adm` and the cross-hart wake rings
`xr[src][dst]` (64 entries each, single producer, single consumer, lock
free). Until later on 2026-10-02 there was also a donation ring
`steal_ring[64]` under `steal_lock`; see "The decision on stealing".

## The policy

An actor made ready lands in its hart's backlog stamped with `g_adm`.
When the run queue is empty the hart refills it, admitting up to `RQ_CAP`
actors, one pass over the backlog per admission:

- Aged tier: any backlog actor that has waited more than `g_tau`
  (`FPR_TAU = 64`) admissions, or carries `prio`, is a candidate; the
  oldest stamp wins. Deterministic.
- Default tier: otherwise one actor is picked by weighted reservoir
  sampling over `acb->weight` with the hart's LCG. Randomness decides who
  runs among the un-aged only.

An idle hart steals: it walks the other harts' backlogs in turn, its
neighbour first, and takes the oldest unpinned ready actor of the first
that has one (`steal_from`), under that hart's own backlog lock. A hart
whose backlog exceeds `DONATE_HI = 4` rings an idle hart's doorbell so a
sleeper comes to look. Pinned actors, the victim's running actor, and
anything not `READY` never move.

Preemption is cooperative at compiler-inserted fuel safepoints on every
FP-RISC function entry, `FUEL_QUANTUM = 2000` entries per slice. A parked
receive or sleep leaves the hart at once.

## The bound, stated honestly

In admissions: an actor ready on hart h waits at most

    tau + (number of actors on h stamped earlier)

admissions on h before it is admitted. This is what the code enforces
(`select_backlog`, aged tier first) and what `FPR_TAU` means.

In time, the same bound reads

    tau * T_adm + (earlier-stamped actors) * T_slot

and holds only under assumptions the runtime does not enforce:

1. `T_slot`, the longest time one admitted actor holds the hart, is
   bounded. A slice is `FUEL_QUANTUM` function entries, each of bounded IR
   length (`Codegen.wcetAnnotate`), plus any C entry the slice makes. C
   entries never preempt: a deep message copy, a device wait that spins,
   a graphics present under vsync or a host system call extend `T_slot`
   by their own duration. The bound is conditional on every such call
   being bounded.
2. `T_adm`, the time between admissions on a hart, is the slot time plus
   one backlog scan, which is linear in that hart's backlog length. The
   bound is therefore not constant in the number of ready actors.
3. A backlog's lock is taken by its owner for every change and scan and
   by a thief for a take; a scan under it is linear in the backlog.
   `xpush` spins when a wake ring is full, bounded only by the peer
   draining it.
4. Interrupt and timer work on the IRQ hart, the hart-0 deadlock detector
   (`DETECT_TICKS`) and the memory actor's `prio` admissions are charged
   to the hart they run on and are not in the formula.

No measurement in this repository establishes a numeric `T_slot` for any
target. `docs/2026-10-01-RUNTIME-COSTS.json` records per-operation costs
on one host, which is the start of such a manifest, not a bound.

## The decision on stealing (2026-10-02, later)

The donation ring was global scheduling state: one lock every busy hart
took to publish and every idle hart took to pop, and a FIFO that decided
which hart got which actor. The ideal this runtime serves is per-hart
schedulers with work stealing and no global scheduler. The ring is
replaced by stealing proper: the backlog stays its owner's list, now under
the owner's lock (`fpr_hart_t.bl_lock`), and an idle hart takes from a
victim's backlog itself. What remains global is the admission clock, an
atomic counter, which the aging stamps need to be comparable after a
migration; and the wake rings, which are per pair of harts. The cost
moved: an uncontended lock per backlog change and per selection scan,
instead of a lock per donation; the benefit is that no hart's decision
goes through a shared queue, and a busy hart is never delayed by the
ring being full.

## What this page does not claim

Not worst-case execution time for a program, not fairness between
processes beyond the aging rule, not a bound on cross-hart message
latency (see `2026-10-01-XHART.md` for measurements), and not that the
admission clock could be made per hart. A change to any constant above, or
to the tiers, is recorded here with its date.

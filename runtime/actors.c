/* actors.c — actor runtime v3: MULTI-HART, ALL-SPSC.
 *
 * v2 gave every actor per-sender SPSC channels precisely so that going
 * multi-hart would be a FENCE INSERTION, not a redesign.  This is that
 * insertion, plus the scheduler restructure it forces:
 *
 *   TOPOLOGY.  Every ring in the system still has exactly one writer
 *   and one reader:
 *     - message channels: writer = the sender ACTOR (an actor runs on
 *       exactly one hart at a time and never migrates), reader = the
 *       owning actor.  The v2 storage is unchanged; head/tail crossings
 *       now carry acquire/release.
 *     - wake/spawn shipping: a FPR_NHARTS x FPR_NHARTS matrix of SPSC
 *       rings of acb pointers; writer = source hart, reader = owner
 *       hart.  No shared run queue, no CAS loop on a list, ever.
 *   The only non-ring shared-mutable state is the actor STATUS word
 *   (a 3-state CAS: the wake protocol needs consensus on who enqueues)
 *   and the ARC table (spin-locked in runtime.c).
 *
 *   SCHEDULER.  Each hart runs a hart loop on its boot stack: drain
 *   inbound wake rings into the local FIFO run queue, run one actor to
 *   its next safepoint (block / yield / fuel exhaustion / death), and
 *   loop.  Actors are PINNED to the hart that spawnOn named (plain
 *   spawn = current hart); `main` itself is actor 0 on hart 0, spawned
 *   like everyone else so the boot stack can become the hart loop.
 *
 *   FUEL is per-hart now: generated code decrements 0(tp) -- see the
 *   fpr_hart_t essay in fpr.h.  The quantum refill sites are unchanged.
 *
 *   THE BLOCK/WAKE PROTOCOL (the one lost-wakeup trap in this design):
 *     sender:   publish message (release rt)
 *               fence seq_cst
 *               if CAS(status, BLOCKED -> READY) succeeds: ship(acb)
 *     receiver: scan channels; if satisfied, take it
 *               CAS(status, READY -> BLOCKED); fence seq_cst
 *               RE-SCAN; if now satisfied: CAS back to READY, continue
 *               else switch to the hart loop
 *     Both sides put a seq_cst fence between "my write" and "their
 *     flag", the Dekker pattern; whoever loses the race still sees the
 *     other's write, so a message published while blocking is either
 *     re-scanned by the receiver or CAS-woken by the sender.  Spurious
 *     wakes and duplicate run-queue entries are possible and HARMLESS:
 *     all entries for an actor land on its one owner hart, so execution
 *     is always sequential; a stale entry for a BLOCKED actor is
 *     skipped by deq (each real wake re-ships).
 *
 *   DEADLOCK detection had to become global: an empty local queue just
 *   means the work is elsewhere.  Hart 0's loop declares deadlock only
 *   when (all harts idle) && (someone is blocked) && (the global
 *   activity counter has not moved) held stable across a long window --
 *   any in-flight send keeps its hart non-idle, so a stable window is a
 *   real deadlock, not a race.
 *
 * Lifetime semantics from v2 kept: body-return = death, send-to-dead =
 * silent no-op, stacks leak on death, selective receive by sender /
 * by Result type over the same rings.  kill of a RUNNING actor on
 * another hart is advisory: it lands at that actor's next safepoint.
 */
#include "fpr.h"

/* An actor's FIRST stack: exactly one 128 KiB buddy block.  It was 256 KiB,
 * which the buddy rounded (with its header) to a 512 KiB block -- reasonable
 * when a stack was all an actor would ever have, and half a megabyte of every
 * session of a live server now that stacks GROW (fpr_stack_grow): an actor that
 * needs depth gets it, in doubling segments, and one that does not never pays. */
#ifndef FPR_STACK_SZ
#define FPR_STACK_SZ (128 * 1024 - 2 * sizeof(uw))
#endif
#define STACK_SZ FPR_STACK_SZ
#define MAXSND 8    /* channel slots per actor: MAXSND-1 dedicated (one
                     * sender each, SPSC) + ONE SHARED overflow ring for
                     * every further sender (MPSC under a lock, entries
                     * tagged with the sender so selective receive still
                     * works).  A hub -- a register with a thousand
                     * sessions, a service with a thousand clients -- is
                     * bounded by memory, not by this constant. */
#define SHIDX (MAXSND - 1) /* the shared ring's slot */
#define SHARED_KEY ((uw)1) /* its sender key: never an acb address */
#define RING_CAP 64  /* the DEFAULT ring: messages per channel, power of
                      * two, inline in the channel block.  spawnCap sets
                      * another: Static n never grows (a WCET bound),
                      * Dynamic n doubles from the buddy when full. */
#define RING_MAX (1u << 20)
#define XCAP 64     /* acb pointers per cross-hart wake ring */

#define FUEL_QUANTUM 2000 /* FPRISC function entries per scheduling slice */

enum { ST_READY, ST_BLOCKED, ST_DEAD };

/* the ring IN FORCE for a channel: capacity, slots and (the shared ring
 * only) the per-entry sender tags, one block -- so a reader that loads
 * `rv` once sees a consistent (cap, slots) pair.  Growth allocates a
 * new block, copies [rh, rt) by logical index and swaps the pointer;
 * the old block stays on the `old` chain until the channel block is
 * reused (a reader may still hold it), which the epoch limbo already
 * guarantees is quiescent.  The default lives inline (rv0/slots0). */
typedef struct ringv {
  uint32_t cap, pad;
  V *slots;
  uw *from;           /* sender tags, the shared ring only; else 0 */
  struct ringv *old;  /* the ring this one replaced (freed at reuse) */
} ringv_t;
#define SLOT(rv, k) ((rv)->slots[(k) & ((rv)->cap - 1)])
#define TAGAT(rv, k) ((rv)->from[(k) & ((rv)->cap - 1)])

/* one SPSC channel: bound to a single sender for the actor's lifetime.
 *
 * Cache lines (2026-10-01, docs/2026-10-01-XHART.md): the producer's fields
 * (rt, rv, its cached view of rh) share one line, the consumer's head rh
 * has its own, and the producer re-reads rh only when its cached view says
 * the ring is full.  With both on one line, a producer and a consumer
 * running at the same time on two harts moved that line between the cores
 * on EVERY message: cross-hart streaming ran at 11.5M messages/s against
 * 20M once the receiver stopped sleeping between batches. */
#ifndef FPR_CACHELINE
#if defined(__APPLE__) && defined(__aarch64__)
#define FPR_CACHELINE 128
#else
#define FPR_CACHELINE 64
#endif
#endif
typedef struct {
  uw sender;       /* sender id + 1; 0 = unbound (claimed by CAS) */
  uint32_t rt;     /* free-running tail: producer-owned; count = rt - rh */
  uint32_t rh_seen; /* the producer's last view of rh (never ahead of it) */
  uint32_t dyn;    /* 1 = the ring doubles when full (Dynamic n) */
  uint32_t pad;
  ringv_t *rv;     /* the ring in force (producer swaps it; readers
                    * load it AFTER rt: the producer publishes rv
                    * before rt, so a seen rt is covered by the rv) */
  uint32_t rh __attribute__((aligned(FPR_CACHELINE))); /* free-running head: consumer-owned */
  uint32_t rt_seen; /* the consumer's last view of rt (never ahead of it) */
  ringv_t rv0 __attribute__((aligned(FPR_CACHELINE))); /* the inline default */
  V slots0[RING_CAP];
} chan_t;
uw fpr_ring_grows, fpr_send_full; /* growths; sends refused for a full ring */

typedef struct fpr_acb {
  uint32_t tid, var; /* var = status word (atomic; doubles as header) */
  uw ctx[FPR_CTX_WORDS]; /* ra sp gp tp s0..s11, then fs0..fs11 where the machine saves them */
  chan_t *ch;        /* MAXSND channels, OUT-OF-LINE (see chblk below):
                      * the acb stays permanent (send-to-dead reads
                      * var), but its 8 KiB of rings is reclaimed at
                      * reap -- the permanent residue per dead actor is
                      * now ~sizeof(acb_t) ~= 250 B, which is what the
                      * "stated ceiling" always meant to say */
  uint32_t scan; /* round-robin cursor for fair receive (owner-only) */
  uint32_t mbdyn;  /* mailbox policy: 1 = rings grow (Dynamic n) */
  uint32_t mbcap;  /* initial ring capacity per channel (spawnCap) */
  fpr_slab_t *entry_hold; /* admitted entry copy: separate from the local heap */
  V entry;       /* PAP to run: body = entry(self); 0 for main */
  struct fpr_acb *next; /* run-queue link (owner hart only) */
  struct fpr_acb *bl_next; /* backlog link (owner hart only) */
  uw ready_at; /* g_adm stamp when it entered a backlog (aging tier) */
  uw weight;   /* selection weight for the randomized default tier (>=1) */
  char *stack;
  uw id;
  uw hart;         /* owner hart (donation can move it unless pin) */
  uw pin;          /* 1 = never donated: actor 0, and spawnOn-placed
                    * actors -- explicit placement is an affinity
                    * contract (a graphics actor's EGL context is bound
                    * to its hart's thread on hosted targets) */
  uw parent;              /* spawner's actor id (0 = the boot actor) */
  uw pid;                 /* owning process: 0 = the boot image
                           * (System.qa / the hosted app); a loaded
                           * process's actors carry its pid -- the ONLY
                           * kernel/process distinction that remains */
  struct fpr_acb *all_nx; /* the all-actors ledger (monitor's walk) */
  /* the borrow window (fpr_drop_park): a message slab whose root this
   * actor dropped stays HELD until its next receive -- the compiler's
   * autodrop drops right after the destructure while the arm still
   * reads the children.  Slabs are shared by many messages now (send
   * packs), so a dropper records a hold per slab instead of chaining
   * the slab itself; DP_N outstanding is plenty (one window holds the
   * messages of one activation), and an overflow retires the oldest. */
#define DP_N 16
  fpr_slab_t *dp[DP_N];
  uw dp_n;
  fpr_slab_t *msg_slab; /* the slab this actor's sends pack into (runtime.c) */
  fpr_pool_t pool; /* this actor's slabs + recycle buckets (slab refactor) */
  struct fpr_pool *pool_override; /* Sys.arena / Sys.loopWith: the arena this ACTOR is
                                   * inside, or 0.  It was a hart field until 2026-10-02:
                                   * an actor parked inside its arena (a call's wait) let
                                   * every other actor the hart ran allocate into that arena,
                                   * torn down at the step's end under them. */
  fpr_lock_t shlock; /* producers' lock on the shared ring */
  uw wait_kind, wait_arg; /* while BLOCKED: 1 any, 2 from(arg = sender acb), 3 res */
  uint8_t tr[16]; uw tr_i; /* scheduler transition trace (site codes; the deadlock dump reads it) */
  uint32_t running; /* 0, or 1 + the hart whose loop has switched into this context and not yet back */
  uint32_t irq_target; /* bound to an interrupt source: the world outside can wake it */
  struct fpr_acb *slp_next; /* the hart's sleeper list (Sys.sleepUs) */
  uint64_t wake_at;         /* its deadline, mtime ticks */
  uw prio; /* 1: admitted ahead of the backlog (the memory actor: every
            * other actor's allocation waits on it, so it never queues
            * behind them -- backlog_add / select_backlog) */
  volatile uw mem_reply; /* the memory actor's answer to this actor's
                          * pending request (fpr_mem_take): MEM_PENDING
                          * while it waits, then the block (0 = denied) */
  uw in_rq; /* owner-only: admitted to the run queue, not yet popped.  A
             * STALE SHIP -- a waker flipped us READY, we noticed and
             * ran on, then parked again and were re-woken and admitted
             * before the first waker's push landed -- must not add us
             * to the backlog a second time: the next admission would
             * queue us twice and the run queue would loop on itself
             * (found with the memory actor, woken thousands of times
             * a second and admitted ahead of everyone). */
  uw in_bl; /* owner-only: on this hart's backlog list right now.  A second
             * enqueue of a listed actor -- a waker's ship racing the
             * receiver's own early un-block, then a yield -- used to
             * re-link it: bl_next zeroed mid-list (entries after it
             * lost) or the tail pointed at itself (a cycle the selector
             * walked forever, the hart "idle" with work in its rings). */
  uw stack_sz; /* the stack's real size, read BEFORE its guard went up (the
                * block header that says so lies inside the guard). */
  /* growable stacks: the segments linked in after `stack` (newest first), one
   * kept warm, and the check values of the segment last known to hold sp */
  struct stkseg *segs, *spare;
  uw stk_lo, stk_span, stk_total;
  /* Sys.sleepUs: linked on hart `slp_hart`'s sleeper list right now (see a_sleep_us) */
  uw slp_on, slp_hart;
  /* receiveFromRes: the sender this actor is parked on (0 when not), and
   * how many actors are parked on THIS one -- a dying actor walks the
   * ledger to wake its watchers only when the count says there are any */
  void (*external_cleanup)(void *);
  void *external_arg;
  struct fpr_acb *watch;
  uw watchers;
#ifdef FPR_COST_PROBE
  uint64_t probe_shipped, probe_drained; /* cross-hart latency stamps (XHART.md) */
#endif
} acb_t;
#define TR(a, code) do { (a)->tr[(a)->tr_i++ % 16] = (uint8_t)((code) * 8 + (fpr_hart() ? fpr_hart()->id : 7)); } while (0)

fpr_plane_actors_t *fpr_plane_actors = 0; /* see fpr.h: NULL = this image is the plane */
fpr_plane_memory_t *fpr_plane_memory = 0; /* NULL = this image owns its heap */
static void dl_put(char **p, const char *e, const char *str);
static void dl_num(char **p, const char *e, uw u);
static void dl_out(const char *b, uw n);
static int p_from(acb_t *a, uw sid);      /* fwd: the deadlock dump and block_unless name them */
static int p_res(acb_t *a, uw unused);
static uint32_t ch_count(chan_t *c);

/* ---- deferred message-slab release (see fpr.h) ----------------------
 * Called under arc_lock when the last promoted root in an ownerless
 * slab is dropped: the dropper takes a HOLD on the slab until its next
 * receive (its borrow window); a context with no actor has no window,
 * and the slab goes home now unless someone else holds it. */
void fpr_drop_park(fpr_slab_t *sl) {
  fpr_hart_t *h = fpr_hart();
  acb_t *a = h ? h->current : 0;
  if (!a) { /* hart-loop context: no borrower; home if nothing keeps it */
    if (sl->holds == 0 && sl->escaped == 0) fpr_slab_release(sl);
    return;
  }
  if (a->dp_n == DP_N) { /* overflow: the oldest window is retired now */
    fpr_slab_unhold(a->dp[0], 1);
    for (uw i = 1; i < DP_N; i++) a->dp[i - 1] = a->dp[i];
    a->dp_n--;
  }
  a->dp[a->dp_n++] = sl;
  sl->holds++;
}
static void drop_drain(acb_t *a) {
  if (!a->dp_n) return;
  uw n = a->dp_n;
  a->dp_n = 0;
  fpr_slabs_unhold(a->dp, n);
}
fpr_slab_t **fpr_acb_msg_slot(struct fpr_acb *a) { return &a->msg_slab; }
void fpr_drop_drain_current(void) {
  acb_t *a = fpr_hart()->current;
  if (a) drop_drain(a);
}

fpr_pool_t *fpr_acb_pool(struct fpr_acb *a) { return &a->pool; }
struct fpr_pool **fpr_acb_override_slot(struct fpr_acb *a) { return &a->pool_override; }

/* big raw blocks (stacks, acbs, rings): the memory actor's buddy on an
 * image that owns one (fpr_mem_own -- a machine boot, the qosp app);
 * inside a loaded process without a buddy, a grant from the loader.
 * `direct` asks for the never-waiting path (a spinlock is held). */
static void *big_block_d(uw n, int direct) {
  if (fpr_mem_own) return direct ? fpr_mem_take_direct(n) : fpr_mem_take(n);
  fpr_grant_t g = fpr_grow_counted(n, 4); /* big-block: stacks/acbs */
  return (g.ptr && g.size >= n) ? g.ptr : 0;
}
static void *big_block(uw n) { return big_block_d(n, 0); }
/* the usable size of a block big_block handed out */
static uw big_block_size(void *p, uw want) {
  return fpr_mem_own ? buddy_block_usable_size(p) : want;
}

/* ---- spawn-side blocks ---------------------------------------------
 * With a memory actor, a dead actor's stack simply goes home (a one-
 * way free from the reaper) and the next spawn asks for a fresh one;
 * the recycling that process mode needed -- grants are never returned
 * to a loader, so without it every spawn leaked a stack grant and a
 * mostly-empty acb grant (pshell burned an arena in seconds) -- stays
 * only for that legacy mode (fpr_mem_own == 0):
 *
 *   stacks: all STACK_SZ, so dead stacks go on a free list and the
 *           next spawn pops one;
 *   acbs:   PERMANENT by contract (the acb IS the actor value that
 *           send-to-dead reads), so they cannot be recycled -- but a
 *           bump arena carves many acbs from one block instead of
 *           wasting a 64 KiB minimum block on each 250 B acb.  That
 *           carve stays in both modes. */
static fpr_freelist_t stack_fl; /* the one freelist discipline (fpr.h) */
static fpr_lock_t acb_lock;     /* the acb bump arena below */
static char *acb_hp, *acb_end;
static fpr_freelist_t acb_unpublished;

/* pool telemetry, always on, PULL-based (Sys.memStats reads them):
 * a print at an allocation site is a syscall inside the allocator */
uw fpr_stk_pushes, fpr_stk_misses, fpr_spawns, fpr_chb_carves;
static void stack_recycle(void *p, uw size);
static V spawn_on_pid(uw hart, V f, uw pin, uw pid);

/* ---- the stack guard ---------------------------------------------------
 * A stack is a fixed STACK_SZ, and running off its low end used to be
 * silent: SIGBUS with no word said on a hosted system, whatever lay below
 * overwritten on bare metal (docs/2026-09-19-BOUNDS.md: building a 20,000-element
 * list by plain recursion).  The core cannot fix that -- a guard is a fact
 * about the MACHINE (an inaccessible page, a PMP region) -- so it asks the
 * HAL at the two places a stack changes hands.  The defaults do nothing.
 * The buddy header and the recycler's list node both live at a stack's
 * low end, inside the guard, so it comes off before a stack goes home. */
__attribute__((weak)) void hal_stack_guard(void *lo, uw size) { (void)lo; (void)size; }
__attribute__((weak)) void hal_stack_unguard(void *lo, uw size) { (void)lo; (void)size; }
/* The RUNNING actor's current stack segment starts at `lo` (0: no actor runs
 * on this hart now).  For a machine without guard pages whose CPU has a
 * watchpoint (machine/esp-idf: no MMU), so a write into the segment's bottom
 * -- C code past the headroom -- is a named fault, not a quiet write into
 * the neighbouring heap block.  Told at switch-in, whenever the segment
 * changes, and on the way back to the hart loop. */
__attribute__((weak)) void hal_actor_stack(void *lo) { (void)lo; }

/* A stack is as big as the block it was GIVEN.  STACK_SZ is what is asked
 * for; the buddy rounds (size + its header) up to a power of two, so a
 * 256 KiB request is a 512 KiB block -- and the top half used to sit
 * unused while the stack overflowed out of the bottom.  (tests/dtree.fpr
 * needs ~400 KiB: it ran past a 256 KiB stack on every run, into the
 * previous block's unused half, and passed by that accident until the
 * guard said so.)  Same memory, the whole block, the guard at its true
 * low end.  A process's grant is only known to be what was wanted. */
static void *stack_guarded(void *p, uw *size) {
  if (!p) return 0;
  *size = big_block_size(p, STACK_SZ); /* reads the header the guard is about to cover */
  hal_stack_guard(p, *size);
  return p;
}
static void *stack_block(uw *size) {
  if (fpr_mem_own) return stack_guarded(fpr_mem_take(STACK_SZ), size);
  void *p = fpr_fl_take(&stack_fl, STACK_SZ);
  if (p) return stack_guarded(p, size);
  __atomic_add_fetch(&fpr_stk_misses, 1, __ATOMIC_RELAXED);
  /* SELF-TOPPING on a miss: take two, keep one warm.  A miss means
   * live+in-flight actors exceeded pool depth, so depth converges to
   * the real concurrency and each level is paid for at most once --
   * without this the boot immortals consume any fixed pre-warm and
   * the spawn-vs-death-epilogue race keeps finding an empty pool
   * (measured: 13 misses/8k spawns, ~12KB/s of permanent stacks). */
  void *spare = big_block(STACK_SZ);
  if (spare) stack_recycle(spare, 0); /* never guarded */
  return stack_guarded(big_block(STACK_SZ), size);
}

/* a dead actor's stack: home to the memory actor, or the recycler */
static void stack_recycle(void *p, uw size) {
  if (size) hal_stack_unguard(p, size);
  if (fpr_mem_own) { fpr_mem_give(p); return; }
  fpr_fl_put(&stack_fl, p, STACK_SZ);
  __atomic_add_fetch(&fpr_stk_pushes, 1, __ATOMIC_RELAXED);
}

/* ---- growable stacks ----------------------------------------------------
 * An actor's stack is not a size.  Every function entry the compiler cannot
 * prove shallow checks that sp still has FPR_STACK_HEADROOM below it in the
 * segment it is in (two loads, a subtract, a branch: Codegen.hs stackCheck);
 * when it has not, fpr_stack_grow links in a NEW segment twice the size of
 * the last -- the mailbox ring's `Dynamic n` doubling -- and the function
 * continues with sp there.  Nothing moves: a frame is addressed through its
 * frame pointer and the epilogue restores sp FROM the frame pointer, so the
 * function that grew returns into the old segment by itself, with no
 * trampoline and no per-architecture assembly.  (Moving a live stack is not
 * possible here: C frames and saved frame pointers hold addresses into it.)
 *
 * Release is lazy.  Once sp has returned to an older segment the newer ones
 * are dead, but nothing runs at that moment; the next failed check notices
 * sp is not in the newest segment, pops the dead ones (keeping one warm, so a
 * call that straddles a boundary in a loop never allocates twice) and
 * re-answers.  reap() frees the rest.
 *
 * The headroom is what C gets: the runtime's own calls run on the actor's
 * stack and are not checked.  The guard page stays below every segment as
 * the backstop for them, and for a single frame larger than the headroom.
 * fpr_stack_max is policy, not capacity: the ceiling on one actor's stack,
 * so that run-away recursion is a named panic instead of the machine's
 * memory.  Bare metal has no guard page, and needs none for FP-RISC frames
 * any more: the check is the guard. */
/* The headroom comes out of the first segment, so it must be smaller than
 * it: half of it, up to 64 KiB (unix: 64 KiB less 8 bytes of a 128 KiB first
 * segment, as before; the ESP32-P4's 64 KiB segment: 32 KiB).  It was a flat 64 KiB,
 * and on the board's 64 KiB segment `size - FPR_STACK_HEADROOM` wrapped to
 * a huge span: the check always passed, stacks never grew, and deep
 * recursion wrote past the segment until the board reset
 * (docs/2026-10-03-ESP-LIMITS.md item 1).  Grown segments are at least twice
 * the first, so the first is the one this must fit. */
#ifndef FPR_STACK_HEADROOM
#define FPR_STACK_HEADROOM ((uw)STACK_SZ / 2 < (uw)64 * 1024 ? (uw)STACK_SZ / 2 : (uw)64 * 1024)
#endif
_Static_assert(FPR_STACK_HEADROOM < STACK_SZ,
               "FPR_STACK_HEADROOM must leave the first stack segment room to run: "
               "the stack check subtracts it from the segment size");
uw fpr_stack_max = (uw)1 << 30;

static void fpr_panic_stack(const char *what, uw kib) __attribute__((noreturn));
static void fpr_panic_stack(const char *what, uw kib) { /* "<what><kib> KiB" */
  static char msg[128];
  char *p = msg;
  for (; *what && p < msg + 96; what++) *p++ = *what;
  char d[24];
  int n = 0;
  do { d[n++] = (char)('0' + kib % 10); kib /= 10; } while (kib);
  while (n) *p++ = d[--n];
  for (const char *t = " KiB"; *t; t++) *p++ = *t;
  *p = 0;
  fpr_cpanic(msg);
}

typedef struct stkseg { struct stkseg *prev; char *lo; uw size; } stkseg_t; /* at the segment's TOP */

static void stk_window(acb_t *a, fpr_hart_t *h, char *lo, uw size) {
  /* a segment no larger than the headroom would wrap the span below, and
   * the check would never fire: refuse it by name, never run on it */
  if (size <= FPR_STACK_HEADROOM) {
    if (h) { h->stk_lo = 0; h->stk_span = ~(uw)0; }
    fpr_panic_stack("stack: a segment no larger than the headroom cannot be checked: ", size >> 10);
  }
  a->stk_lo = (uw)lo + FPR_STACK_HEADROOM;
  a->stk_span = size - FPR_STACK_HEADROOM;
  if (h) { h->stk_lo = a->stk_lo; h->stk_span = a->stk_span; hal_actor_stack(lo); }
}
static void stkseg_free(stkseg_t *g) {
  char *lo = g->lo;
  uw size = g->size;
  hal_stack_unguard(lo, size);
  if (fpr_mem_own) fpr_mem_give(lo);
  else fpr_fl_put(&stack_fl, lo, size); /* a loader's grant is never returned */
}
static void stk_release_all(acb_t *a) {
  while (a->segs) { stkseg_t *g = a->segs; a->segs = g->prev; stkseg_free(g); }
  if (a->spare) { stkseg_free(a->spare); a->spare = 0; }
  a->stk_total = 0;
}

static uw stack_grow_at(uw sp);
uw fpr_stack_grow(void) {
  uw sp = (uw)__builtin_frame_address(0);
  /* a loaded process's actors are the PLANE's: its scheduler grows them */
  if (fpr_plane_memory) return fpr_plane_memory->stack_grow(sp);
  return stack_grow_at(sp);
}
static uw stack_grow_at(uw sp) {
  fpr_hart_t *h = fpr_hart();
  acb_t *a = h ? h->current : 0;
  if (!a || !a->stack) { /* the hart loop, a boot stack: not ours to grow */
    if (h) { h->stk_lo = 0; h->stk_span = ~(uw)0; }
    return 0;
  }
  /* segments sp has left are dead: pop them, the largest stays warm.  The
   * watched segment is the one being popped, and freeing writes its bottom
   * (the allocator's header): unwatch first; stk_window below re-arms. */
  if (a->segs && !(sp >= (uw)a->segs->lo && sp < (uw)a->segs->lo + a->segs->size)) hal_actor_stack(0);
  while (a->segs && !(sp >= (uw)a->segs->lo && sp < (uw)a->segs->lo + a->segs->size)) {
    stkseg_t *g = a->segs;
    a->segs = g->prev;
    a->stk_total -= g->size;
    if (!a->spare) a->spare = g;
    else if (g->size > a->spare->size) { stkseg_free(a->spare); a->spare = g; }
    else stkseg_free(g);
  }
  char *lo = a->segs ? a->segs->lo : (char *)a->stack;
  uw size = a->segs ? a->segs->size : a->stack_sz;
  if (sp < (uw)lo || sp >= (uw)lo + size) { /* a stack we do not know (a foreign caller's) */
    h->stk_lo = 0; h->stk_span = ~(uw)0;
    return 0;
  }
  stk_window(a, h, lo, size);
  if (sp - a->stk_lo < a->stk_span) return 0; /* room after all */
  /* a new segment, double the last */
  uw want = 2 * size - sizeof(uw); /* the buddy adds its header back: exactly the next order */
  if (a->stack_sz + a->stk_total + 2 * size > fpr_stack_max) {
    h->stk_lo = 0; h->stk_span = ~(uw)0; /* the panic path runs on what is left */
    fpr_panic_stack("stack overflow -- the actor's stack reached its ceiling, fpr_stack_max, at ", (a->stack_sz + a->stk_total) >> 10);
  }
  stkseg_t *g = 0;
  char *nlo;
  uw nsz;
  if (a->spare && a->spare->size >= 2 * size) {
    nlo = a->spare->lo; nsz = a->spare->size; a->spare = 0;
  } else {
    nlo = (char *)big_block_d(want, 1);
    if (!nlo) {
      h->stk_lo = 0; h->stk_span = ~(uw)0;
      fpr_panic_stack("stack overflow -- no memory to grow the actor's stack by ", want >> 10);
    }
    nsz = big_block_size(nlo, want);
    hal_stack_guard(nlo, nsz);
  }
  g = (stkseg_t *)((uw)(nlo + nsz - sizeof(stkseg_t)) & ~(uw)15);
  g->prev = a->segs; g->lo = nlo; g->size = nsz;
  a->segs = g;
  a->stk_total += nsz;
  stk_window(a, h, nlo, nsz);
  return (uw)g & ~(uw)15;
}

/* for a HAL's fault handler: the stack of the actor running on THIS hart
 * (NULL between actors), its size and the actor's id.  Reads only. */
void *fpr_current_stack(uw *id, uw *size) {
  fpr_hart_t *h = fpr_hart();
  acb_t *a = h ? h->current : 0;
  if (!a || !a->stack) return 0;
  if (id) *id = a->id;
  if (a->segs) { /* the newest segment: where a C frame would run off */
    if (size) *size = a->segs->size;
    return a->segs->lo;
  }
  if (size) *size = a->stack_sz;
  return a->stack;
}

static acb_t *acb_block(void) {
  acb_t *reserved = (acb_t *)fpr_fl_take(&acb_unpublished, sizeof(acb_t));
  if (reserved) return reserved;
  uw sz = (sizeof(acb_t) + 15) & ~(uw)15;
  for (;;) {
    fpr_lock(&acb_lock);
    if (acb_hp + sz <= acb_end) {
      acb_t *a = (acb_t *)acb_hp;
      acb_hp += sz;
      fpr_unlock(&acb_lock);
      return a;
    }
    fpr_unlock(&acb_lock);
    /* refill OUTSIDE the lock: the block may come from the memory
     * actor (a wait), and no spinlock is ever held across a wait.
     * No growlog here either: the trace print is a uart SYSCALL under
     * qosp, and printing inside an allocator stalls the world. */
    uw want = 16 * sz;
    char *p = (char *)big_block(want);
    if (!p) return 0;
    uw got = big_block_size(p, want);
    if (got < sz) return 0;
    fpr_lock(&acb_lock);
    if (acb_hp + sz > acb_end) { /* still empty: install ours */
      acb_hp = p;
      acb_end = p + got;
      fpr_unlock(&acb_lock);
    } else { /* a racer refilled first: give ours back, carve from theirs */
      fpr_unlock(&acb_lock);
      if (fpr_mem_own) fpr_mem_give(p);
    }
  }
}

/* ---- out-of-line channel blocks: type-stable, epoch-deferred --------
 * The acb permanence contract exists so a stale handle's send is a
 * harmless read of var==ST_DEAD.  But send CHECKS var and then TOUCHES
 * the channels -- so channel memory cannot be handed to anything else
 * while such a send may be in flight.  Two properties make reuse
 * sound:
 *
 *   TYPE-STABLE: a channel block is only ever reused as a channel
 *   block, so a racing access reads well-formed channel memory;
 *
 *   EPOCH-DEFERRED: every hart bumps h->epoch once per hart-loop
 *   iteration, and a send runs INSIDE one scheduler segment on its
 *   hart -- its hart's epoch cannot advance past it.  A reaped block
 *   parks on a limbo list stamped with every live hart's epoch and is
 *   reused only after each has advanced by 2: any send that loaded a
 *   stale var==READY has long since completed.
 *
 * Without this, frame-per-actor designs retire 8 KiB of dead rings
 * per frame forever (pshell exhausted a Pi 4's arena in minutes). */
typedef struct chblk {
  chan_t ch[MAXSND];
  uw shfrom[RING_CAP]; /* the shared ring's per-entry sender tags (its inline ring) */
  struct chblk *nx;
  uw stamp[FPR_NHARTS];
} chblk_t;
static fpr_freelist_t chb_fl; /* never-referenced carve extras ONLY --
                               * reaped blocks go to limbo and are
                               * reused from there, so the flnode
                               * overlay can't race a stale send */
static chblk_t *chb_limbo;
static fpr_lock_t chb_lock; /* the limbo list + its epoch stamps */

static void chb_drain(chan_t *ch); /* below reap: releases what a dead actor's rings still hold */
static int chb_matured(chblk_t *b) {
  for (uw i = 0; i < fpr_live_harts; i++)
    if (fpr_harts[i].epoch < b->stamp[i] + 2) return 0;
  return 1;
}

/* a channel's rings to their inline default: grown blocks (the `old`
 * chain above the inline one) go back to the buddy -- inside a process
 * they are grants, kept until exit like every other grant */
static void chan_init(chan_t *c, uw *shfrom, int fresh) {
  /* a reused block (limbo) carries a sane rv chain: free what grew.
   * A fresh carve or free-list block carries nothing readable. */
  ringv_t *rv = fresh ? 0 : c->rv;
  while (rv && rv != &c->rv0) {
    ringv_t *o = rv->old;
    if (fpr_mem_own) fpr_mem_give(rv); /* a loader grant is kept until exit */
    rv = o;
  }
  c->sender = 0;
  c->rh = c->rt = 0;
  c->rh_seen = c->rt_seen = 0; /* the cached views go with the counters: a
                                * reused block's stale rt_seen claimed
                                * messages that were never sent */
  c->dyn = 0;
  c->rv0.cap = RING_CAP;
  c->rv0.slots = c->slots0;
  c->rv0.from = shfrom;
  c->rv0.old = 0;
  c->rv = &c->rv0;
}
/* a ring of cap slots (plus tags when the channel is the shared one),
 * in one block; 0 when there is no memory */
static ringv_t *ring_block_d(uint32_t cap, int tagged, ringv_t *old, int direct) {
  uw bytes = sizeof(ringv_t) + (uw)cap * sizeof(V) + (tagged ? (uw)cap * sizeof(uw) : 0);
  ringv_t *nv = (ringv_t *)big_block_d(bytes, direct);
  if (!nv) return 0;
  nv->cap = cap;
  nv->pad = 0;
  nv->slots = (V *)(nv + 1);
  nv->from = tagged ? (uw *)(nv->slots + cap) : 0;
  nv->old = old;
  return nv;
}
static ringv_t *ring_block(uint32_t cap, int tagged, ringv_t *old) {
  return ring_block_d(cap, tagged, old, 0);
}
static chan_t *chb_take(void) {
  chblk_t *b = 0;
  int fresh = 0;
  fpr_lock(&chb_lock);
  /* matured limbo first, then the free list */
  chblk_t **pp = &chb_limbo;
  while (*pp) {
    if (chb_matured(*pp)) {
      b = *pp;
      *pp = b->nx;
      break;
    }
    pp = &(*pp)->nx;
  }
  fpr_unlock(&chb_lock);
  if (b) chb_drain(b->ch); /* a send that raced the kill landed here: release it */
  if (!b) { b = (chblk_t *)fpr_fl_take(&chb_fl, sizeof(chblk_t)); fresh = 1; }
  if (!b) {
    fresh = 1;
    /* fresh backing: the floor-sized block carves several channel
     * blocks; the extras seed the free list (type-stable forever) */
    uw sz = (sizeof(chblk_t) + 15) & ~(uw)15;
    uw want = sz * 4;
    fpr_chb_carves++;
    char *p = (char *)big_block(want);
    if (!p) return 0;
    uw got = big_block_size(p, want);
    if (got < sz) got = sz;
    b = (chblk_t *)p;
    for (char *q = p + sz; q + sz <= p + got; q += sz)
      fpr_fl_put(&chb_fl, q, sz);
  }
  for (int i = 0; i < MAXSND; i++) chan_init(&b->ch[i], i == SHIDX ? b->shfrom : 0, fresh);
  b->ch[SHIDX].sender = SHARED_KEY; /* the overflow ring is always bound */
  return b->ch;
}
static chan_t *sh_chan(acb_t *a) { return &a->ch[SHIDX]; }

static void chb_limbo_put(chan_t *ch) {
  chblk_t *b = (chblk_t *)ch; /* ch is the block's first member */
  fpr_lock(&chb_lock);
  for (uw i = 0; i < FPR_NHARTS; i++)
    b->stamp[i] = (i < fpr_live_harts) ? fpr_harts[i].epoch : 0;
  b->nx = chb_limbo;
  chb_limbo = b;
  fpr_unlock(&chb_lock);
}

/* release what is still queued on a channel: each slot's root is dropped
 * exactly as the receiver's own drop would have (a send's copy or an ARC
 * share goes back, a transferred root is released), and the head catches
 * up with the tail.  Called by reap on the owner hart, and again when a
 * matured limbo block is taken: a sender that read var != DEAD before the
 * kill may push after reap drained -- its message waits in limbo (the
 * block is type-stable and epoch-deferred, so the slot is well-formed)
 * and is released here, two epochs later, before the block is reused.
 * Before this, 300 deaths with 50 one-KiB messages unread lost 16.5 MB
 * per round (docs/2026-10-07-STATES.md 1.5). */
static void chan_drain(chan_t *c) {
  uint32_t rt = __atomic_load_n(&c->rt, __ATOMIC_ACQUIRE);
  ringv_t *rv = __atomic_load_n(&c->rv, __ATOMIC_ACQUIRE); /* after rt: covers every slot below it */
  for (uint32_t k = c->rh; k != rt; k++) fpr_arc_decref(SLOT(rv, k));
  __atomic_store_n(&c->rh, rt, __ATOMIC_RELEASE);
}
static void chb_drain(chan_t *ch) {
  for (int i = 0; i < MAXSND; i++)
    if (__atomic_load_n(&ch[i].sender, __ATOMIC_ACQUIRE)) chan_drain(&ch[i]);
}

/* death reclamation (called from the hart loop, NEVER on the dying
 * actor's own stack): slabs via the ARC-locked teardown, stack -- which
 * cannot escape -- straight back to buddy.  Idempotent via stack=0. */
static void mem_cancel(acb_t *a);
static volatile uw g_blocked;      /* actors currently parked */
static volatile uw g_sleepers;     /* of which: parked with a deadline */
static volatile uw g_irq_waiting;  /* of which: an interrupt's actor, waiting for it */
static void reap(acb_t *a) {
  if (!a->stack) return;
  mem_cancel(a);
  if (a->wait_kind) { /* a killed parked actor never returns through block_unless */
    __atomic_fetch_sub(&g_blocked, 1, __ATOMIC_RELAXED);
    if (a->irq_target) __atomic_fetch_sub(&g_irq_waiting, 1, __ATOMIC_RELAXED);
    a->wait_kind = 0;
  }
  if (a->external_cleanup) {
    void (*fn)(void *) = a->external_cleanup;
    void *arg = a->external_arg;
    a->external_cleanup = 0; a->external_arg = 0;
    fn(arg);
  }
  if (a->ch) chb_drain(a->ch); /* mail it never read: released, not stranded (holds park below) */
  drop_drain(a); /* the holds of windows the dead actor never closed */
  if (a->msg_slab) { fpr_slab_unhold(a->msg_slab, 0); a->msg_slab = 0; } /* its packing slab */
  fpr_pool_reclaim(a);
  stk_release_all(a);
  stack_recycle(a->stack, a->stack_sz); /* home to the memory actor (or the recycler) */
  a->stack = 0;
  if (a->ch) {
    chb_limbo_put(a->ch); /* deferred: see the epoch essay above */
    a->ch = 0;
  }
  if (a->entry_hold) { fpr_slab_unhold(a->entry_hold, 0); a->entry_hold = 0; a->entry = 0; }
  else if (a->entry) { fpr_arc_decref(a->entry); a->entry = 0; } /* unpin the closure */
  /* a process's actor reclaimed: its loader may end the image once none
   * is left (fpr_pid_live is 0 only when no hart runs that code) */
  if (a->pid && fpr_pid_quiet) fpr_pid_quiet(a->pid);
  /* the acb itself stays: it IS the actor value other actors hold
   * (send-to-dead reads a->var).  ~sizeof(acb_t) per actor, stated. */
}

extern void fpr_ctx_switch(uw *save, uw *load);
extern V fpr_fn_main(void);
extern void fpr_exit(V result);
extern void fpr_set_tp(fpr_hart_t *h);
extern volatile uint32_t fpr_shutdown;
extern void fpr_rvv_enable(void); /* mstatus.VS is per-hart; weak default defined in runtime.c */

/* hal.c: CLINT-based sleep/wake (see the wfi essay there) */
void hal_ipi_send(uw hart);
void hal_ipi_clear(uw hart);
void hal_timer_park(uw hart);
void hal_timer_arm(uw hart, uint64_t delta);
void hal_wfi_enable(void);
void hal_wfi(void);

/* ---- shared counters (the deadlock detector's whole world) ----------- */
static uw next_id;                 /* atomic fetch_add */
/* every acb ever, newest first (acbs are immortal, so the walk is
 * always safe; readers tolerate concurrent pushes -- push is a single
 * release store of the head) */
static acb_t *g_all;
static void wake_watchers(acb_t *s); /* receiveFromRes: a dying actor wakes its watchers */
static int p_from_dead(acb_t *a, uw sid);
static void ledger_push(acb_t *a) {
  acb_t *h;
  do {
    h = __atomic_load_n(&g_all, __ATOMIC_ACQUIRE);
    a->all_nx = h;
  } while (!__atomic_compare_exchange_n(&g_all, &h, a, 0, __ATOMIC_RELEASE,
                                        __ATOMIC_ACQUIRE));
}
static volatile uw g_activity;     /* bumped on every ship/spawn */

/* ---- cross-hart wake rings: xr[src][dst], strictly SPSC -------------- */
typedef struct {
  uint32_t rh, rt;
  acb_t *ring[XCAP];
} xring_t;
static xring_t xr[FPR_NHARTS][FPR_NHARTS];
/* where each hart's loop is (1 drained, 2 entering steal, 3 past steal,
 * 4 entering wfi, 5 back from wfi) and how many turns it has taken --
 * the deadlock dump's answer to "is hart N looping or stuck?" */
static volatile uw hart_phase[FPR_NHARTS], hart_loops[FPR_NHARTS], hart_loops_at_quiet[FPR_NHARTS];
static volatile uint64_t hart_wfi_at[FPR_NHARTS]; /* mtime when the hart last entered wfi */

static void xpush(uw src, uw dst, acb_t *a) {
  xring_t *x = &xr[src][dst];
  TR(a, 2);
  /* single producer: only OUR rt moves; spin if the consumer lags */
  while (x->rt - __atomic_load_n(&x->rh, __ATOMIC_ACQUIRE) == XCAP)
    __asm__ volatile("nop");
  x->ring[x->rt % XCAP] = a;
  __atomic_store_n(&x->rt, x->rt + 1, __ATOMIC_RELEASE);
}

/* ---- the two-tier bounded-latency scheduler (docs/2026-10-02-SCHED-MODEL.md) -----
 *
 * READY actors land in the per-hart BACKLOG (owner-only list) stamped
 * with the machine-wide admission counter g_adm. Admission into the
 * (bounded, FIFO) run queue picks per slot:
 *
 *   AGED TIER (deterministic): if any backlog actor has waited more
 *   than FPR_TAU admissions, the OLDEST such actor is admitted — no
 *   randomness, oldest-first. This tier alone carries the WCET bound:
 *   Wait(a) <= tau + (#earlier-stamped actors) * T_slot.
 *
 *   DEFAULT TIER (weighted random): otherwise a weighted reservoir
 *   pick over acb->weight, driven by a per-hart deterministic LCG.
 *   Randomness here decides only WHO runs among the un-aged — it
 *   shapes expected fairness and touches no worst case.
 *
 * Work stealing is per-hart and the THIEF's act (2026-10-02; it was a
 * global donation ring under one lock): an idle hart walks the other
 * harts' backlogs in turn, from its neighbour on, and takes the oldest
 * unpinned READY entry it finds (stamp preserved: the admission clock is
 * machine-wide).  A backlog is its owner's list, under the owner's own
 * lock, which the thief takes for the take; a backlog past DONATE_HI
 * rings an idle hart's doorbell so a sleeper comes to look.  No global
 * scheduling state remains but the admission clock. */

#ifndef FPR_TAU
#define FPR_TAU 64 /* aging threshold, in machine-wide admissions */
#endif
#ifndef RQ_CAP
#define RQ_CAP 4 /* run-queue admissions per refill batch */
#endif
#define DONATE_HI 4 /* backlog length past which an idle hart is rung */

static uw g_tau = FPR_TAU;
static volatile uw g_adm;      /* machine-wide admission counter (the clock) */
static volatile uw g_max_wait; /* max observed backlog wait, in admissions */
static volatile uw g_steals;

static void backlog_add(fpr_hart_t *h, acb_t *a);

/* a backlog past DONATE_HI: ring one idle hart so it comes to steal.
 * The publish-then-check order (the entry is on the list under the lock
 * before the idle flags are read) pairs with the thief's idle-then-scan
 * order in hart_loop (Dekker): either the thief's scan sees the entry,
 * or we see its idle flag and raise msip. */
static void offer(fpr_hart_t *h) {
  for (uw i = 0; i < fpr_live_harts; i++)
    if (i != h->id && fpr_harts[i].idle) { hal_ipi_send(i); break; }
}

/* take the oldest unpinned READY entry of another hart's backlog.  Only
 * ST_READY entries may cross: a BLOCKED actor left in the backlog is ALSO
 * the target of its waker's re-ship (wake CAS -> xr) -- taking it puts the
 * same acb in two harts' backlogs, and two harts then resume the same
 * context.  And never the victim's current: fuel preemption (and yield)
 * enqueue the RUNNING actor before to_sched() saves its context, so until
 * the victim's loop regains control that entry points at an unsaved
 * context.  Every other READY entry is quiescent and stable: it isn't
 * running, and wake only fires on BLOCKED actors.  The victim's lock
 * covers the walk and the unlink; the thief holds no lock of its own. */
static acb_t *steal_from(fpr_hart_t *v) {
  fpr_lock(&v->bl_lock);
  acb_t *prev = 0, *a = v->bl_head;
  while (a && (a->pin || a == v->current ||
               __atomic_load_n(&a->var, __ATOMIC_ACQUIRE) != ST_READY)) {
    prev = a;
    a = a->bl_next;
  }
  if (a) {
    if (prev) prev->bl_next = a->bl_next;
    else v->bl_head = a->bl_next;
    if (v->bl_tail == a) v->bl_tail = prev;
    v->bl_len--;
    a->in_bl = 0;
  }
  fpr_unlock(&v->bl_lock);
  return a;
}
/* an idle hart's round: the other harts in turn, the neighbour first */
static acb_t *steal(fpr_hart_t *h) {
  for (uw i = 1; i < fpr_live_harts; i++) {
    fpr_hart_t *v = &fpr_harts[(h->id + i) % fpr_live_harts];
    if (!__atomic_load_n(&v->bl_len, __ATOMIC_RELAXED)) continue;
    acb_t *a = steal_from(v);
    if (a) {
      a->hart = h->id; /* migrates; stamp is preserved (global clock) */
      g_steals++;
      return a;
    }
  }
  return 0;
}

static void backlog_add(fpr_hart_t *h, acb_t *a) {
  if (a->in_bl || a->in_rq) { TR(a, 13); return; } /* already listed: one entry is the invariant */
  a->in_bl = 1;
  TR(a, 4);
  a->ready_at = a->prio ? 0 : g_adm; /* stamped in admission time; a
                                      * priority actor is the oldest by
                                      * construction, so aging picks it */
  fpr_lock(&h->bl_lock);
  a->bl_next = 0;
  if (!a->weight) a->weight = 1;
  if (h->bl_tail) h->bl_tail->bl_next = a;
  else h->bl_head = a;
  h->bl_tail = a;
  uw len = ++h->bl_len;
  fpr_unlock(&h->bl_lock);
  if (len > DONATE_HI) offer(h);
}

/* one O(backlog) scan: unlink DEAD/BLOCKED, find the oldest aged actor,
 * and run the weighted reservoir over the rest in the same pass */
static void backlog_cycle(fpr_hart_t *h) {
  /* the list walked longer than any list can be: name the ring */
  char buf[96], *p = buf, *e = buf + sizeof buf - 1;
  dl_put(&p, e, "backlog cycle on hart "); dl_num(&p, e, h->id);
  dl_put(&p, e, " len "); dl_num(&p, e, h->bl_len); dl_put(&p, e, ":");
  acb_t *a = h->bl_head;
  for (int i = 0; a && i < 12; i++, a = a->bl_next) { dl_put(&p, e, " "); dl_num(&p, e, a->id); }
  *p = 0;
  dl_out(buf, (uw)(p - buf));
  fpr_cpanic("actors: backlog list is cyclic");
}
static acb_t *select_backlog(fpr_hart_t *h) {
  fpr_lock(&h->bl_lock); /* a thief may be walking this list */
  acb_t *prev = 0, *a = h->bl_head;
  acb_t *aged = 0, *aged_prev = 0;
  acb_t *pick = 0, *pick_prev = 0;
  uw total = 0, walked = 0;
  while (a) {
    if (++walked > 1000000) backlog_cycle(h);
    acb_t *nx = a->bl_next;
    uint32_t st = __atomic_load_n(&a->var, __ATOMIC_ACQUIRE);
    if (st != ST_READY) {
      /* unlink; DEAD reaps, BLOCKED re-ships on its real wake */
      TR(a, 6);
      if (prev) prev->bl_next = nx; else h->bl_head = nx;
      if (h->bl_tail == a) h->bl_tail = prev;
      h->bl_len--;
      a->in_bl = 0;
      if (st == ST_DEAD) reap(a);
      a = nx;
      continue;
    }
    if (a->prio || g_adm - a->ready_at > g_tau) {
      if (!aged || a->ready_at < aged->ready_at) { aged = a; aged_prev = prev; }
    }
    total += a->weight;
    h->lcg = h->lcg * 1103515245u + 12345u;
    if ((h->lcg >> 16) % total < a->weight) { pick = a; pick_prev = prev; }
    prev = a;
    a = nx;
  }
  acb_t *sel = aged ? aged : pick;
  acb_t *sp = aged ? aged_prev : pick_prev;
  if (sel) {
    TR(sel, 5);
    if (sp) sp->bl_next = sel->bl_next; else h->bl_head = sel->bl_next;
    if (h->bl_tail == sel) h->bl_tail = sp;
    h->bl_len--;
    sel->in_bl = 0;
  }
  fpr_unlock(&h->bl_lock);
  return sel;
}

/* admit up to RQ_CAP backlog actors into the FIFO run queue */
static void refill(fpr_hart_t *h) {
  while (h->rq_len < RQ_CAP) {
    acb_t *a = select_backlog(h);
    if (!a) return;
    uw adm = __atomic_add_fetch(&g_adm, 1, __ATOMIC_RELAXED);
    uw wait = adm - a->ready_at;
    if (wait > g_max_wait) g_max_wait = wait;
    /* the run queue holds an actor once: a second entry is a self-loop
     * that spins the hart forever -- name it instead */
    for (acb_t *q = h->rq_head; q; q = q->next)
      if (q == a) {
        char buf[128], *bp = buf, *e = buf + sizeof buf - 1;
        dl_put(&bp, e, "run queue holds actor "); dl_num(&bp, e, a->id);
        dl_put(&bp, e, " twice (var "); dl_num(&bp, e, a->var);
        dl_put(&bp, e, " in_bl "); dl_num(&bp, e, a->in_bl);
        dl_put(&bp, e, " prio "); dl_num(&bp, e, a->prio);
        dl_put(&bp, e, " hart "); dl_num(&bp, e, a->hart);
        dl_put(&bp, e, " on "); dl_num(&bp, e, h->id);
        dl_put(&bp, e, " current "); dl_num(&bp, e, h->current ? h->current->id : 0);
        dl_put(&bp, e, ")");
        *bp = 0;
        dl_out(buf, (uw)(bp - buf));
        fpr_cpanic("actors: run queue double entry");
      }
    a->next = 0;
    a->in_rq = 1;
    if (h->rq_tail) h->rq_tail->next = a;
    else h->rq_head = a;
    h->rq_tail = a;
    h->rq_len++;
  }
}

static void enq(fpr_hart_t *h, acb_t *a) { backlog_add(h, a); }

static acb_t *deq(fpr_hart_t *h) {
  refill(h);
  while (h->rq_head) {
    acb_t *a = h->rq_head;
    h->rq_head = a->next;
    if (!h->rq_head) h->rq_tail = 0;
    h->rq_len--;
    a->in_rq = 0;
    uint32_t st = __atomic_load_n(&a->var, __ATOMIC_ACQUIRE);
    /* skip stale entries: DEAD forever; BLOCKED re-ships on real wake */
    if (st == ST_DEAD) reap(a); /* slab refactor: reclaim off its stack */
    if (st == ST_READY) { TR(a, 7); return a; }
    TR(a, 8);
  }
  return 0;
}

/* ---- device interrupts -> actor messages ----------------------------
 * The no-trap model's last mile: a device source bound with
 * Sys.irqBind is claimed-and-masked by the IRQ HART's loop
 * (hal_irq_claim, plic.c on virt; weak no-ops on hosts, where
 * "interrupts" are the host tier's poll loops) and delivered to its
 * actor as a PLAIN INT message -- copy-free, allocation-free, safe
 * from scheduler context.  The actor services the device and re-arms
 * with Sys.irqAck.  Only the BOUND actor is interrupted; everything
 * downstream of it sees ordinary messages it chooses to send.
 *
 * ALL interrupts land on an AUXILIARY hart: fpr_irq_hart is the last
 * live hart (0 only when the machine has one), so MEIP/MTIP servicing
 * never preempts the prime hart's latency-sensitive work -- the bound
 * actor still runs wherever the scheduler puts it (deliveries are
 * ordinary cross-hart sends). */
uw fpr_irq_hart; /* set in fpr_actors_init, after fpr_live_harts is final */

__attribute__((weak)) void hal_irq_open(uw src) { (void)src; }
__attribute__((weak)) sw hal_irq_claim(void) { return 0; }
__attribute__((weak)) void hal_irq_ack(uw src) { (void)src; }

/* Which actor a source belongs to is FP-RISC: the router in
 * core/prelude.fpr keeps the table (any number of sources, no capacity
 * here) and implements Sys.irqBind / Sys.irqUnbind.  C keeps the
 * mechanism: claim on the irq hart, post the source to the ONE installed
 * router, and the primitives the router and binders need.  A delivery
 * still reaches the bound actor on irq_src_key's channel, so a binder
 * waiting for the router's reply never takes an interrupt for it. */
static acb_t *irq_router;      /* installed once (Sys.irqInstall); never replaced */
static volatile int irq_bound; /* gate: keep the hot loop MMIO-free until a router exists */
static uw irq_src_key;         /* the deliveries' stable channel key */

static acb_t *want_actor(V av, const char *who) {
  if (ISINT(av) || TID(av) != T_ACTOR) fpr_cpanic(who);
  return (acb_t *)av;
}
/* Sys.irqInstall a -> Bool: make a THE router; False if one already is */
static V a_irq_install(V av) {
  acb_t *a = want_actor(av, "Sys.irqInstall: not an actor");
  acb_t *none = 0;
  if (!__atomic_compare_exchange_n(&irq_router, &none, a, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST))
    return (V)&fpr_false;
  __atomic_store_n(&irq_bound, 1, __ATOMIC_RELEASE);
  return (V)&fpr_true;
}
/* Sys.irqRouter () -> the router, or 0 before one is installed */
static V a_irq_router(V u) {
  (void)u;
  acb_t *r = __atomic_load_n(&irq_router, __ATOMIC_ACQUIRE);
  return r ? (V)r : TAG(0);
}
/* Sys.irqOpen src: let the device raise it (the router, at bind) */
static V a_irq_open(V srcv) {
  if (!ISINT(srcv) || UNTAG(srcv) < 1) fpr_cpanic("Sys.irqOpen: a source is an Int >= 1");
  hal_irq_open((uw)UNTAG(srcv));
  return (V)&fpr_unit;
}
/* Sys.irqDeliver a src -> Result Unit String: the router hands a claimed
 * source to its actor on the deliveries' channel; a full mailbox refuses
 * (the router retries), a dead actor is "dead actor", as `send` says */
static V a_irq_deliver(V av, V srcv) {
  want_actor(av, "Sys.irqDeliver: not an actor");
  return fpr_send_as((uw)&irq_src_key, av, srcv);
}
/* Sys.irqTarget n: mark (n != 0) or unmark the CALLER as waiting on a
 * device, which the deadlock detector counts as a way to be woken.  Only
 * the running actor changes its own flag: the blocking path counts it
 * around a block. */
static V a_irq_target(V n) {
  if (!ISINT(n)) fpr_cpanic("Sys.irqTarget: not an Int");
  fpr_hart()->current->irq_target = UNTAG(n) != 0;
  return (V)&fpr_unit;
}
static V a_irq_ack(V irqv) {
  if (!ISINT(irqv)) fpr_cpanic("Sys.irqAck: irq must be an Int");
  hal_irq_ack((uw)UNTAG(irqv));
  return (V)&fpr_unit;
}
FPR_FN(fpr_g_Sys_x2eirqInstall, a_irq_install, 1);
FPR_FN(fpr_g_Sys_x2eirqRouter, a_irq_router, 1);
FPR_FN(fpr_g_Sys_x2eirqOpen, a_irq_open, 1);
FPR_FN(fpr_g_Sys_x2eirqDeliver, a_irq_deliver, 2);
FPR_FN(fpr_g_Sys_x2eirqTarget, a_irq_target, 1);
FPR_FN(fpr_g_Sys_x2eirqAck, a_irq_ack, 1);

static void irq_drain(fpr_hart_t *h) {
  if (h->id != fpr_irq_hart || !__atomic_load_n(&irq_bound, __ATOMIC_ACQUIRE)) return;
  acb_t *r = __atomic_load_n(&irq_router, __ATOMIC_ACQUIRE);
  for (;;) {
    sw s = hal_irq_claim(); /* claims AND masks: no same-source spin */
    if (!s) return;
    /* a plain Int: copy-free and allocation-free from scheduler context.
     * A source nobody bound is dropped by the router and stays masked. */
    fpr_send_as((uw)&irq_src_key, (V)r, TAG(s));
  }
}

/* ---- the CLINT timer -> actor messages ------------------------------
 * The same bridge for TIME: Timer.qa binds itself (Sys.timerBind, which
 * answers whether the machine HAS a hardware timer -- 0 on hosts, whose
 * Timer.qa falls back to sleeper children) and arms ONE deadline at a
 * time (Sys.timerArm, a DELTA in CLINT ticks; the service serializes
 * its pending set and always arms the nearest).  The irq hart's loop
 * compares mtime against the armed deadline and, once due, delivers a
 * bare Int message -- the actor pops everything due, notifies the
 * waiters' mailboxes (backlog -> ready under the scheduler's admission
 * bounds), and re-arms.  mtimecmp is per-hart, so the detector's
 * DETECT_TICKS pacing on hart 0 never collides with this unless the
 * machine is single-hart -- there tmr_wfi_arm just refuses to arm
 * LATER than the detector's next sample, and the due check runs every
 * loop pass either way. */
__attribute__((weak)) uint64_t hal_mtime(void) { return 0; }
__attribute__((weak)) int hal_timer_native(void) { return 0; }

static acb_t *tmr_act;
static volatile uint64_t tmr_deadline; /* absolute mtime; 0 = unarmed */
/* A 64-bit deadline on a 32-bit machine: rv32 has no 64-bit atomics (a load
 * or store is two words, and a reader could see half of each).  A lock there;
 * the plain atomic where the word is 64 bits. */
#if UINTPTR_MAX > 0xffffffffu
static uint64_t tmr_dl_get(void) { return __atomic_load_n(&tmr_deadline, __ATOMIC_ACQUIRE); }
static void tmr_dl_set(uint64_t v) { __atomic_store_n(&tmr_deadline, v, __ATOMIC_RELEASE); }
#else
static fpr_lock_t tmr_dl_lock;
static uint64_t tmr_dl_get(void) { fpr_lock(&tmr_dl_lock); uint64_t v = tmr_deadline; fpr_unlock(&tmr_dl_lock); return v; }
static void tmr_dl_set(uint64_t v) { fpr_lock(&tmr_dl_lock); tmr_deadline = v; fpr_unlock(&tmr_dl_lock); }
#endif
static volatile int tmr_bound;
static uw tmr_src_key;

static V a_timer_bind(V av) {
  if (ISINT(av) || TID(av) != T_ACTOR) fpr_cpanic("Sys.timerBind: target is not an actor");
  tmr_act = (acb_t *)av;
  __atomic_store_n(&tmr_bound, 1, __ATOMIC_RELEASE);
  return TAG((sw)hal_timer_native());
}
static V a_timer_arm(V dv) {
  if (!ISINT(dv)) fpr_cpanic("Sys.timerArm: delta must be an Int (CLINT ticks)");
  sw d = UNTAG(dv);
  if (d < 1) d = 1; /* already due: fire on the next drain pass */
  tmr_dl_set(hal_mtime() + (uint64_t)d);
  if (fpr_hart()->id != fpr_irq_hart)
    hal_ipi_send(fpr_irq_hart); /* wake it to re-arm its mtimecmp */
  return (V)&fpr_unit;
}
FPR_FN(fpr_g_Sys_x2etimerBind, a_timer_bind, 1);
FPR_FN(fpr_g_Sys_x2etimerArm, a_timer_arm, 1);

static void tmr_drain(fpr_hart_t *h) {
  if (h->id != fpr_irq_hart || !__atomic_load_n(&tmr_bound, __ATOMIC_ACQUIRE)) return;
  uint64_t dl = tmr_dl_get();
  if (!dl || hal_mtime() < dl) return;
  tmr_dl_set(0);
  if (h->id != 0) hal_timer_park(h->id); /* else MTIP pends forever (hart
                                          * 0's detector re-arms its own) */
  fpr_send_as((uw)&tmr_src_key, (V)tmr_act, TAG((sw)(dl & 0x3FFFFFFFFFFFFFFFull)));
}

static void slp_drain(fpr_hart_t *h);   /* the parked sleep, below block_unless */
static void slp_wfi_arm(fpr_hart_t *h);

static void drain(fpr_hart_t *h) {
  for (uw s = 0; s < FPR_NHARTS; s++) {
    xring_t *x = &xr[s][h->id];
    uint32_t rt = __atomic_load_n(&x->rt, __ATOMIC_ACQUIRE);
    while (x->rh != rt) {
      acb_t *a = x->ring[x->rh % XCAP];
      __atomic_store_n(&x->rh, x->rh + 1, __ATOMIC_RELEASE);
      TR(a, 3);
#ifdef FPR_COST_PROBE
      if (a->probe_shipped) {
        uint64_t now = FPR_PROBE_NOW();
        FPR_COST_ADD(h, xl_drain_n, 1);
        FPR_COST_ADD(h, xl_drain_ns, now - a->probe_shipped);
        a->probe_shipped = 0;
        a->probe_drained = now;
      }
#endif
      enq(h, a);
    }
  }
}

/* ship a runnable actor to its owner hart's queue */
static void ship(acb_t *a) {
  fpr_hart_t *h = fpr_hart();
  __atomic_fetch_add(&g_activity, 1, __ATOMIC_RELAXED);
  if (a->hart == h->id) {
    FPR_COST_ADD(h, xs_lship_n, 1);
    enq(h, a);
  } else {
#ifdef FPR_COST_PROBE
    uint64_t s0 = FPR_PROBE_NOW();
    a->probe_shipped = s0;
#endif
    xpush(h->id, a->hart, a); /* publish the work... */
#ifdef FPR_COST_PROBE
    uint64_t s1 = FPR_PROBE_NOW();
#endif
    hal_ipi_send(a->hart);    /* ...THEN raise msip (Dekker with the sleeper) */
#ifdef FPR_COST_PROBE
    uint64_t s2 = FPR_PROBE_NOW();
    FPR_COST_ADD(h, xs_xship_n, 1);
    FPR_COST_ADD(h, xs_xpush_ns, s1 - s0);
    FPR_COST_ADD(h, xs_ipi_ns, s2 - s1);
#endif
  }
}

/* ---- the hart loop ----------------------------------------------------
 * Runs on the boot stack.  Every actor's block/yield/death switches back
 * here; picking the next actor switches out.  Hart 0 moonlights as the
 * deadlock detector. */
#define DETECT_TICKS 300000 /* 30 ms of CLINT time between detector samples */
#ifndef DETECT_QUIET
#define DETECT_QUIET 8      /* consecutive silent samples before declaring */
#endif
#ifndef DETECT_WINDOW
#define DETECT_WINDOW 20000000ull /* AND at least this much CLINT time quiet
                                   * (2 s at 10 MHz): on hosts the sample
                                   * pacing timer is a no-op and the idle
                                   * pass is a 200 us poll, so a count of
                                   * passes alone declared a deadlock after
                                   * ~1.6 ms of lull -- with a cross-hart
                                   * wake still in flight */
#endif

/* going to sleep on the irq hart: make mtimecmp pop the wfi AT the
 * armed timer deadline.  When the irq hart is also hart 0 (single-hart
 * machine) the detector just armed DETECT_TICKS ahead -- only arm over
 * it for a SOONER deadline, so detector pacing is never stretched. */
static void tmr_wfi_arm(fpr_hart_t *h) {
  if (h->id != fpr_irq_hart || !__atomic_load_n(&tmr_bound, __ATOMIC_ACQUIRE)) return;
  uint64_t dl = tmr_dl_get();
  if (!dl) return;
  uint64_t now = hal_mtime();
  uint64_t delta = dl > now ? dl - now : 1;
  if (h->id == 0 && delta > DETECT_TICKS) return;
  hal_timer_arm(h->id, delta);
}

/* process-loading (docs/PROCESS-LOADING.md): a dynamically loaded app
 * runs its OWN instance of this whole file (a separate compiled image,
 * fpr_process_entry.c calls fpr_hart_main directly instead of crt0
 * doing the machine-wide boot dance). Its actor-0 completion needs to
 * RETURN to the C caller (the loader) instead of halting the machine
 * -- fpr_exit does the latter, unconditionally, which would be wrong
 * here. fpr_is_process / fpr_process_done / fpr_process_result reuse
 * the EXISTING to_sched()/ctx_switch machinery (already exercised by
 * every block/yield/fuel-exhaustion path) rather than inventing a
 * second control-transfer mechanism: setting fpr_process_done just
 * makes hart_loop's normal loop condition fail, so it returns like any
 * other C function -- no extra ctx_switch, no unwinding trick needed.
 * Both flags are 0 forever for a normal machine boot: zero behavior
 * change there. */
volatile int fpr_is_process = 0;
volatile int fpr_process_done = 0;
static V fpr_process_result;

/* the deadlock's last words: every parked actor, what it waits for, and
 * what it already holds -- the runtime names the cycle instead of the
 * program guessing at it */
extern void hal_putc(char c); /* the raw console: the log ring's echo is rate-limited */
static void dl_out(const char *b, uw n) { for (uw i = 0; i < n; i++) hal_putc(b[i]); hal_putc('\n'); }
static void dl_put(char **p, const char *e, const char *str) { while (*str && *p < e) *(*p)++ = *str++; }
static void dl_num(char **p, const char *e, uw u) {
  char d[24]; int i = 23; d[i] = 0;
  if (!u) d[--i] = '0';
  while (u) { d[--i] = '0' + (u % 10); u /= 10; }
  dl_put(p, e, d + i);
}
static void deadlock_dump(void) {
  for (acb_t *a = g_all; a; a = a->all_nx) {
    uint32_t st = __atomic_load_n(&a->var, __ATOMIC_ACQUIRE);
    char buf[96], *p = buf, *e = buf + sizeof buf - 1;
    dl_put(&p, e, "dl: actor "); dl_num(&p, e, a->id);
    dl_put(&p, e, " hart "); dl_num(&p, e, a->hart);
    dl_put(&p, e, a->pin ? " pinned" : " free");
    dl_put(&p, e, st == ST_DEAD ? " DEAD" : (st == ST_READY ? " READY" : " BLOCKED"));
    if (st == ST_BLOCKED) {
      dl_put(&p, e, a->wait_kind == 2 ? " waits from " : (a->wait_kind == 3 ? " waits res" : " waits any"));
      if (a->wait_kind == 2) dl_num(&p, e, ((acb_t *)a->wait_arg)->id);
    }
    uw held = 0;
    if (a->ch) for (int i = 0; i < MAXSND; i++) if (a->ch[i].sender) held += ch_count(&a->ch[i]);
    dl_put(&p, e, " holds "); dl_num(&p, e, held);
    dl_put(&p, e, " parent "); dl_num(&p, e, a->parent);
    *p = 0;
    dl_out(buf, (uw)(p - buf));
    { /* the last 16 transitions, oldest first: site.hart */
      char tb[128], *q = tb, *te = tb + sizeof tb - 1;
      dl_put(&q, te, "   trace:");
      uw n = a->tr_i < 16 ? a->tr_i : 16;
      for (uw i = 0; i < n; i++) {
        uint8_t c = a->tr[(a->tr_i - n + i) % 16];
        dl_put(&q, te, " "); dl_num(&q, te, c / 8); dl_put(&q, te, "."); dl_num(&q, te, c % 8);
      }
      *q = 0;
      dl_out(tb, (uw)(q - tb));
    }
  }
  for (uw sx = 0; sx < fpr_live_harts; sx++)
    for (uw dx = 0; dx < fpr_live_harts; dx++) {
      xring_t *x = &xr[sx][dx];
      if (x->rt == x->rh) continue;
      char buf[64], *p = buf, *e = buf + sizeof buf - 1;
      dl_put(&p, e, "dl: xring "); dl_num(&p, e, sx); dl_put(&p, e, "->"); dl_num(&p, e, dx);
      dl_put(&p, e, " rt "); dl_num(&p, e, x->rt); dl_put(&p, e, " rh "); dl_num(&p, e, x->rh);
      dl_put(&p, e, " head actor "); dl_num(&p, e, x->ring[x->rh % XCAP]->id);
      *p = 0;
      dl_out(buf, (uw)(p - buf));
    }
  for (uw i = 0; i < fpr_live_harts; i++) {
    char buf[160], *p = buf, *e = buf + sizeof buf - 1;
    dl_put(&p, e, "dl: hart "); dl_num(&p, e, i);
    dl_put(&p, e, fpr_harts[i].idle ? " idle" : " busy");
    dl_put(&p, e, " current "); dl_num(&p, e, fpr_harts[i].current ? fpr_harts[i].current->id : 0);
    dl_put(&p, e, " phase "); dl_num(&p, e, hart_phase[i]);
    dl_put(&p, e, " turns-in-quiet-window "); dl_num(&p, e, hart_loops[i] - hart_loops_at_quiet[i]);
    dl_put(&p, e, " in-wfi-for-ms "); dl_num(&p, e, (uw)((hal_mtime() - hart_wfi_at[i]) / 10000));
    *p = 0;
    dl_out(buf, (uw)(p - buf));
  }
}
/* An actor's context may be live on ONE hart.  Two harts resuming the same
 * context corrupt its stack, and the symptom used to be a segfault or a
 * "not the current actor's handle" panic far from the cause.  The hart loop
 * claims the context before switching in and releases it after switching
 * back, when the context is saved; a second claimant stops HERE, naming both
 * harts and the actor's last scheduler transitions. */
static void double_run(acb_t *a, fpr_hart_t *h, uint32_t owner) {
  char buf[512], *p = buf, *e = buf + sizeof buf - 1;
  dl_put(&p, e, "actor "); dl_num(&p, e, a->id);
  dl_put(&p, e, " resumed on hart "); dl_num(&p, e, h->id);
  dl_put(&p, e, " while live on hart "); dl_num(&p, e, owner - 1);
  dl_put(&p, e, " (var "); dl_num(&p, e, a->var);
  dl_put(&p, e, " home "); dl_num(&p, e, a->hart);
  dl_put(&p, e, " in_bl "); dl_num(&p, e, a->in_bl);
  dl_put(&p, e, " in_rq "); dl_num(&p, e, a->in_rq);
  dl_put(&p, e, ") trace oldest-first site@hart:");
  for (uw k = 0; k < 16; k++) {
    uint8_t t = a->tr[(a->tr_i + k) % 16];
    if (!t) continue;
    dl_put(&p, e, " "); dl_num(&p, e, t / 8); dl_put(&p, e, "@"); dl_num(&p, e, t % 8);
  }
  *p = 0;
  dl_out(buf, (uw)(p - buf));
  fpr_cpanic("actors: one context resumed on two harts");
}

/* the hart register must name the hart whose loop this is; if an actor
 * that ran here left it pointing anywhere else, stop and say who */
static void hart_reg_lost(fpr_hart_t *h, acb_t *last) {
  char buf[256], *p = buf, *e = buf + sizeof buf - 1;
  fpr_hart_t *seen = fpr_hart();
  dl_put(&p, e, "hart "); dl_num(&p, e, h->id);
  dl_put(&p, e, ": its hart register now holds ");
  dl_num(&p, e, (uw)seen);
  dl_put(&p, e, " (hart ");
  uw which = (uw)-1;
  for (uw i = 0; i < FPR_NHARTS; i++) if (seen == &fpr_harts[i]) which = i;
  if (which == (uw)-1) dl_put(&p, e, "none"); else dl_num(&p, e, which);
  dl_put(&p, e, ") after actor ");
  dl_num(&p, e, last ? last->id : 0);
  dl_put(&p, e, " ran");
  *p = 0;
  dl_out(buf, (uw)(p - buf));
  fpr_cpanic("actors: the hart register was overwritten");
}

/* A loader publishes code before publishing an actor that can execute it.
 * Each hart acquires that generation and synchronizes its own instruction
 * stream before dispatch. No acknowledgement wait: a busy hart cannot run
 * the new image until it returns through this dispatch boundary. */
static uw code_generation;
__attribute__((weak)) void fpr_instruction_fence(void) {
#if defined(__riscv)
  __asm__ volatile(".option push\n.option arch, +zifencei\nfence.i\n.option pop" ::: "memory");
#endif
}
void fpr_code_publish(void) {
  fpr_instruction_fence(); /* the loader may call the image entry directly */
  __atomic_add_fetch(&code_generation, 1, __ATOMIC_RELEASE);
}
static void hart_loop(fpr_hart_t *h) {
  uw code_seen = 0;
  uw last_act = 0, stable = 0;
  uint64_t quiet_since = 0; /* CLINT time the current lull began (detector) */
  h->lcg = h->id * 2654435761u + 12345u; /* decorrelated, deterministic */
  hal_wfi_enable(); /* mie on, mstatus.MIE off: wfi wakes, never traps */
  for (;;) {
    h->epoch++; /* the quiescence clock (see chblk above) */
    if (fpr_process_done) return; /* process mode: clean C return to the loader */
    if (__atomic_load_n(&fpr_shutdown, __ATOMIC_ACQUIRE))
      for (;;) hal_wfi();
    /* hot path first, NO MMIO: fuel preempts and local yields bounce
     * through here thousands of times a second (irq_drain/tmr_drain
     * are gated on their bound flags AND on being the irq hart, so
     * other harts pay one comparison and machines with no bound
     * sources one flag read) */
    hart_loops[h->id]++;
    irq_drain(h);
    tmr_drain(h);
    slp_drain(h);
    drain(h);
    hart_phase[h->id] = 1;
    acb_t *n = deq(h);
    if (!n) {
      /* nothing visible: arm the sleep protocol.  Clear our doorbell,
       * fence, and look AGAIN -- anything shipped after the clear
       * re-raises msip and the wfi below falls straight through. */
      hal_ipi_clear(h->id);
      __atomic_thread_fence(__ATOMIC_SEQ_CST);
      irq_drain(h); /* MEIP/MTIP wakes ride the same doorbell protocol */
      tmr_drain(h);
      slp_drain(h);
      drain(h);
      n = deq(h);
    }
    if (n) {
      h->idle = 0;
      stable = 0;
      h->current = n;
      h->stk_lo = n->stk_lo; /* the entry check reads the RUNNING actor's segment */
      h->stk_span = n->stk_span;
      {
        uint32_t free_ = 0;
        if (!__atomic_compare_exchange_n(&n->running, &free_, (uint32_t)h->id + 1, 0,
                                         __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
          double_run(n, h, free_);
      }
      if (n->stack && n->stk_span != ~(uw)0) hal_actor_stack((void *)(n->stk_lo - FPR_STACK_HEADROOM));
#ifdef FPR_COST_PROBE
      if (n->probe_drained) {
        FPR_COST_ADD(h, xl_run_n, 1);
        FPR_COST_ADD(h, xl_run_ns, FPR_PROBE_NOW() - n->probe_drained);
        n->probe_drained = 0;
      }
#endif
      uw code_now = __atomic_load_n(&code_generation, __ATOMIC_ACQUIRE);
      if (code_now != code_seen) {
        fpr_instruction_fence();
        code_seen = code_now;
      }
      fpr_ctx_switch(h->sched_ctx, n->ctx);
      hal_actor_stack(0); /* the hart loop may free that stack (reap): nothing watched here */
      __atomic_store_n(&n->running, 0, __ATOMIC_RELEASE); /* saved: it may run elsewhere now */
      if (fpr_hart() != h) hart_reg_lost(h, n);
      h->current = 0;
      /* body-return / kill marked it DEAD before switching back; we are
       * on the hart-loop stack now, so ITS stack is safe to reclaim */
      if (__atomic_load_n(&n->var, __ATOMIC_ACQUIRE) == ST_DEAD) reap(n);
      continue;
    }
    /* nothing local: steal -- the other harts' backlogs in turn, the
     * oldest ready entry of the first that has one.  idle is raised
     * BEFORE the scan (fenced), pairing with offer()'s publish-before-
     * idle-check: whichever side loses the race still observes the
     * other's write, so work past DONATE_HI is never left under a
     * sleeping hart. */
    h->idle = 1;
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    {
      hart_phase[h->id] = 2;
      acb_t *s = steal(h);
      hart_phase[h->id] = 3;
      if (s) { h->idle = 0; backlog_add(h, s); continue; }
    }
    if (h->id == 0) {
      /* deadlock detector, timer-paced: hart 0 wakes every DETECT_TICKS
       * even with no doorbell, samples the world, sleeps again.  A real
       * deadlock is (everyone idle) && (someone parked) && (the global
       * activity counter frozen) across DETECT_QUIET samples; any send
       * in flight keeps its hart non-idle or bumps the counter. */
      uw act = __atomic_load_n(&g_activity, __ATOMIC_RELAXED);
      uw blk = __atomic_load_n(&g_blocked, __ATOMIC_RELAXED);
      int all_idle = 1;
      for (uw i = 0; i < fpr_live_harts; i++)
        if (!fpr_harts[i].idle) all_idle = 0;
      uw slp = __atomic_load_n(&g_sleepers, __ATOMIC_RELAXED);
      /* a world with a sleeper is not a deadlock: its deadline will wake it, and
       * whoever waits on it may be waiting for what it sends then (the rule was
       * blk > slp, which called a waiter on a sleeping actor a deadlock after
       * DETECT_WINDOW).  Nor is a world with an interrupt's actor waiting: a
       * device -- or on a host, a thread blocked in the kernel on a socket
       * (os.c's watcher) -- will wake it.  A server idle between requests used
       * to look "moving" only because its poller ticked. */
      uw irqw = __atomic_load_n(&g_irq_waiting, __ATOMIC_RELAXED);
      if (all_idle && blk > 0 && slp == 0 && irqw == 0 && act == last_act) {
        uint64_t now = hal_mtime();
        if (stable == 0) {
          quiet_since = now;
          for (uw i = 0; i < fpr_live_harts; i++) hart_loops_at_quiet[i] = hart_loops[i];
        }
        if (++stable > DETECT_QUIET && now - quiet_since > DETECT_WINDOW) {
          deadlock_dump();
          fpr_cpanic("actors: deadlock -- every hart idle, someone blocked, nothing moving");
        }
      } else {
        stable = 0;
        last_act = act;
      }
      hal_timer_arm(0, DETECT_TICKS); /* re-arm clears MTIP until then */
    }
    tmr_wfi_arm(h); /* a sooner timer deadline overrides on the irq hart */
    slp_wfi_arm(h); /* the nearest sleeper, sooner still */
    hart_phase[h->id] = 4;
    hart_wfi_at[h->id] = hal_mtime();
    hal_wfi(); /* sleeps unless msip/mtip is already pending again */
    hart_phase[h->id] = 5;
  }
}

/* switch from the current actor back to this hart's loop */
static void to_sched(void) {
  fpr_hart_t *h = fpr_hart();
  acb_t *p = h->current;
  fpr_ctx_switch(p->ctx, h->sched_ctx); /* returns when re-scheduled */
  fpr_hart()->fuel = FUEL_QUANTUM;      /* fresh slice on resume */
}

/* the compiler-inserted fuel check (0(tp) hit zero) lands here */
void fpr_fuel_exhausted(void) {
  if (fpr_plane_actors) { fpr_plane_actors->fuel(); return; }
  fpr_hart_t *h = fpr_hart();
  h->fuel_preempts++;
  h->fuel = FUEL_QUANTUM;
  TR(h->current, 14);
  enq(h, h->current); /* still runnable: back of our own queue */
  to_sched();
}

/* first activation of a spawned actor lands here (fabricated ra) */
static void trampoline(void) {
  fpr_hart_t *h = fpr_hart();
  acb_t *a = h->current;
  h->fuel = FUEL_QUANTUM;
  if (a->entry == 0) {          /* actor 0: main itself */
    V r = fpr_fn_main();
    if (fpr_is_process) {       /* return to the loader, don't halt the machine */
      fpr_process_result = r;
      fpr_process_done = 1;
      to_sched();
      fpr_cpanic("actors: process resumed after its own exit");
    }
    fpr_exit(r);                /* normal boot: halts the machine */
  }
  V r = fpr_apply(a->entry, (V)a);
  /* the body's result has no reader: release it.  A received message root
   * returned as the result (`fn self -> receive self`) kept its whole
   * message slab alive -- the slab goes home only when every root in it
   * is dropped, so one undropped root pinned 49 drained neighbours
   * (tests/base/deadmail.fpr).  A pool-local or by-value result is a no-op. */
  fpr_arc_decref(r);
  __atomic_store_n(&a->var, ST_DEAD, __ATOMIC_SEQ_CST);
  wake_watchers(a);
  to_sched();
  fpr_cpanic("actors: dead actor resumed");
}

/* ---- channels --------------------------------------------------------- */

/* the target's channel for messages FROM a given sender; a free slot is
 * claimed by CAS on the sender field -- two first-time senders on
 * different harts race politely for slots.
 *
 * SLOT RECLAMATION (the slab-refactor companion fix): the key is the
 * sender's acb POINTER (acbs are immortal, so its status word is
 * always readable).  A slot whose sender is DEAD with a drained ring
 * (rh == rt) is claimable by CAS from the dead key -- without this,
 * every short-lived sender permanently consumed one of the receiver's
 * MAXSND slots, and a spawn/reply/die loop exhausted them at 8. */
static chan_t *chan_for(acb_t *a, uw skey, int create) {
  uw key = skey;
  for (;;) {
    chan_t *free_slot = 0;
    uw free_expect = 0;
    for (int i = 0; i < SHIDX; i++) {
      uw s = __atomic_load_n(&a->ch[i].sender, __ATOMIC_ACQUIRE);
      if (s == key) return &a->ch[i];
      if (!free_slot) {
        if (s == 0) { free_slot = &a->ch[i]; free_expect = 0; }
        else if (__atomic_load_n(&((acb_t *)s)->var, __ATOMIC_ACQUIRE) == ST_DEAD) {
          chan_t *c = &a->ch[i];
          uint32_t rt = __atomic_load_n(&c->rt, __ATOMIC_ACQUIRE);
          if (__atomic_load_n(&c->rh, __ATOMIC_ACQUIRE) == rt) { free_slot = c; free_expect = s; } /* dead + drained */
        }
      }
    }
    if (!create) return 0;
    if (!free_slot) return sh_chan(a); /* the dedicated slots are taken: share */
    /* chan_init / spawn initialize counters and policy BEFORE publishing
     * the actor. Never write them while merely holding a candidate: another
     * sender can win the CAS and publish a message before our CAS fails.
     * Resetting rt here erased that message, stranding receiveRes forever.
     * Reclaimed slots likewise keep their monotonic counters where they stand;
     * the acquire of rh above observes the consumer's release of the last slot. */
    uw expect = free_expect;
    if (__atomic_compare_exchange_n(&free_slot->sender, &expect, key, 0,
                                    __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
      return free_slot;
    /* lost the race: rescan (our key may now exist, or steal elsewhere) */
  }
}

/* CAS BLOCKED -> READY; the winner ships the actor to its owner hart */
static void wake(acb_t *a) {
  uint32_t exp = ST_BLOCKED;
  if (__atomic_compare_exchange_n(&a->var, &exp, ST_READY, 0,
                                  __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {
    TR(a, 1);
    ship(a);
  } else TR(a, 16);
}

/* park the current actor unless `pred(a, arg)` already holds.  The
 * seq_cst fence between the status store and the re-scan is the other
 * half of the Dekker pairing with a_send. */
typedef int (*pred_t)(acb_t *, uw);

/* SPIN BEFORE BLOCKING (2026-10-01, docs/2026-10-01-XHART.md): an actor
 * about to block, on a hart with nothing else to run, re-checks what it is
 * waiting for for up to hal_block_spin_ns() first.  A reply or the next
 * streamed message usually lands inside that window, and then there is no
 * block, no wake, no ship to the hart and no two context switches.  Only
 * when the hart is otherwise idle -- its run queue, backlog and incoming
 * ships empty -- so no other actor waits behind the spin.  0 = block at
 * once: bare metal (wfi and an IPI are cheap on real harts); the posix
 * machine sets it ($FPR_BLOCK_SPIN_NS). */
__attribute__((weak)) uw hal_block_spin_ns(void) { return 0; }
/* the longest gap between two looks (spin_until's backoff doubles up to it) */
#ifndef FPR_SPIN_GAP
#define FPR_SPIN_GAP 64
#endif
static int hart_quiet(fpr_hart_t *h) {
  if (h->rq_head || h->bl_head) return 0;
  for (uw s = 0; s < fpr_live_harts; s++) {
    xring_t *x = &xr[s][h->id];
    if (__atomic_load_n(&x->rt, __ATOMIC_ACQUIRE) != x->rh) return 0;
  }
  return 1;
}
static int spin_until(acb_t *a, pred_t pred, uw arg) {
  static uw spin_ns = (uw)-1;
  if (spin_ns == (uw)-1) spin_ns = hal_block_spin_ns();
  if (!spin_ns) return 0;
  fpr_hart_t *h = fpr_hart();
  if (!hart_quiet(h)) return 0;
  uint64_t end = hal_mtime() + spin_ns / 100 + 1; /* 100 ns ticks */
  /* exponential backoff between looks: an imminent reply is seen almost at
   * once, and a waiter that is only keeping pace with its producer stops
   * re-reading the producer's line (each look at an empty channel reads
   * rt) -- that contention halved cross-hart streaming at a fixed gap */
  int gap = 1;
  do {
    for (int i = 0; i < gap; i++) {
#if defined(__aarch64__)
      __asm__ volatile("isb");
#elif defined(__x86_64__)
      __asm__ volatile("pause");
#endif
    }
    if (pred(a, arg)) return 1;
    if (gap < FPR_SPIN_GAP) gap <<= 1;
  } while (hal_mtime() < end && hart_quiet(h));
  return 0;
}

static void block_unless(acb_t *a, pred_t pred, uw arg) {
  if (spin_until(a, pred, arg)) return; /* it arrived while we looked */
  uint32_t exp = ST_READY;
  if (!__atomic_compare_exchange_n(&a->var, &exp, ST_BLOCKED, 0,
                                   __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {
    to_sched(); /* killed under our feet: park forever (deq skips DEAD) */
    fpr_cpanic("actors: dead actor resumed");
  }
  __atomic_thread_fence(__ATOMIC_SEQ_CST);
  if (pred(a, arg)) { /* a message slid in while we were deciding */
    TR(a, 11);
    exp = ST_BLOCKED;
    __atomic_compare_exchange_n(&a->var, &exp, ST_READY, 0,
                                __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    return; /* whether we or a waker flipped it, we are READY */
  }
  a->wait_kind = (pred == p_from || pred == p_from_dead) ? 2 : (pred == p_res ? 3 : 1);
  a->wait_arg = arg;
  TR(a, 10);
  __atomic_fetch_add(&g_blocked, 1, __ATOMIC_RELAXED);
  if (a->irq_target) __atomic_fetch_add(&g_irq_waiting, 1, __ATOMIC_RELAXED);
  to_sched();
  TR(a, 12);
  if (a->irq_target) __atomic_fetch_sub(&g_irq_waiting, 1, __ATOMIC_RELAXED);
  __atomic_fetch_sub(&g_blocked, 1, __ATOMIC_RELAXED);
  a->wait_kind = 0;
}

/* Shared monotonic clock in the scheduler's 10 MHz units. */
static V a_mtime(V ignored) { (void)ignored; return TAG((sw)hal_mtime()); }
FPR_FN(fpr_g_Sys_x2emtime, a_mtime, 1);

/* ---- Sys.sleepUs: a PARKED sleep ------------------------------------
 * The sleeper leaves its hart: parked with a deadline on the hart's
 * own list (only this hart touches it), woken by the hart loop once
 * mtime passes -- qosp's wfi polls every 200 us, bare metal arms the
 * CLINT timer for the nearest deadline (slp_wfi_arm).  It used to
 * nanosleep the HART THREAD on qosp, so every actor sharing that hart
 * -- the memory actor included, and with it every allocation in the
 * system -- waited out the sleep.  A message wakes a sleeper early
 * like any parked actor; it re-parks until its deadline. */
static int p_sleep(acb_t *a, uw unused) {
  (void)unused;
  return hal_mtime() >= a->wake_at;
}
static V a_sleep_us(V usv) {
  if (!ISINT(usv)) fpr_cpanic("Sys.sleepUs: microseconds must be an Int");
  sw us = UNTAG(usv);
  if (us <= 0) return (V)&fpr_unit;
  fpr_hart_t *h = fpr_hart();
  acb_t *a = h ? h->current : 0;
  uint64_t now = hal_mtime();
#ifndef FPR_PARKED_SLEEP
#define FPR_PARKED_SLEEP 1 /* 0: the hart-blocking host sleep (the bisecting switch) */
#endif
  if (!a || fpr_plane_actors || !now || !FPR_PARKED_SLEEP) { /* no actor to park, or no clock: the host sleep */
    fpr_hal_sleep_us((uw)us);
    return (V)&fpr_unit;
  }
  /* A sleeper woken EARLY by a message returned still linked on the list, and
   * its next sleep linked it a second time: when it was the head it then pointed
   * at itself, and the hart walked that one-node cycle forever, running nothing
   * (an actor that sleeps while messages keep arriving -- std/poller -- did it
   * within a few hundred connections).  So: never link twice.  An actor still on
   * a list another hart owns (it migrated mid-sleep) may not touch that list, and
   * takes the host sleep this once; that hart unlinks it when it comes due. */
  if (__atomic_load_n(&a->slp_on, __ATOMIC_ACQUIRE)) {
    fpr_hal_sleep_us((uw)us);
    return (V)&fpr_unit;
  }
  a->wake_at = now + (uint64_t)us * 10; /* mtime runs at 10 MHz everywhere we run */
  a->slp_hart = h->id;
  __atomic_store_n(&a->slp_on, 1, __ATOMIC_RELEASE);
  a->slp_next = h->slp_head;
  h->slp_head = a;
  __atomic_fetch_add(&g_sleepers, 1, __ATOMIC_RELAXED);
  while (!p_sleep(a, 0)) block_unless(a, p_sleep, 0);
  /* woken by the deadline: slp_drain already unlinked us.  Woken early and now
   * past it: still linked.  Unlink here when the list is THIS hart's to touch. */
  if (__atomic_load_n(&a->slp_on, __ATOMIC_ACQUIRE)) {
    fpr_hart_t *hn = fpr_hart();
    if (hn && hn->id == a->slp_hart) {
      for (acb_t **pp = &hn->slp_head; *pp; pp = &(*pp)->slp_next)
        if (*pp == a) {
          *pp = a->slp_next;
          __atomic_fetch_sub(&g_sleepers, 1, __ATOMIC_RELAXED);
          __atomic_store_n(&a->slp_on, 0, __ATOMIC_RELEASE);
          break;
        }
    }
  }
  return (V)&fpr_unit;
}
void fpr_actor_sleep_us(uw us) {
  if (fpr_plane_actors) { fpr_plane_actors->sleep_us(us); return; }
  (void)a_sleep_us(TAG((sw)us));
}
int fpr_actor_cleanup_set(void (*fn)(void *), void *arg) {
  if (fpr_plane_actors) return fpr_plane_actors->cleanup_set(fn, arg);
  fpr_hart_t *h = fpr_hart();
  acb_t *a = h ? h->current : 0;
  if (!a) return 0;
  if (a->external_cleanup) fpr_cpanic("actors: nested external request");
  a->external_arg = arg; a->external_cleanup = fn;
  return 1;
}
void fpr_actor_cleanup_clear(void *arg) {
  if (fpr_plane_actors) { fpr_plane_actors->cleanup_clear(arg); return; }
  fpr_hart_t *h = fpr_hart();
  acb_t *a = h ? h->current : 0;
  if (a && a->external_arg == arg) { a->external_cleanup = 0; a->external_arg = 0; }
}

/* FAIL-STOP: end the CURRENT actor with a named reason instead of halting the
 * machine.  For a device primitive whose request cannot be completed (a
 * deadline passed, the device stalled or refused, an I/O error) the honest
 * outcome belongs to the caller, not to every actor on the system: the
 * reason goes to the error ring, the actor dies (its watchers wake, so an
 * RPC caller hears Err "dead actor"; the reaper runs a pending cleanup
 * hook), and the machine keeps running.  A routed process image fails
 * through the plane's own copy (fpr_plane_actors->fail), so a device failure in
 * a loaded process ends that actor, not the machine.  The boot actor has
 * no one to fail to: it panics with the same reason. */
static V a_kill(V av);
void fpr_actor_fail(const char *why) {
  if (fpr_plane_actors) { fpr_plane_actors->fail(why); for (;;) FPR_PARK(); }
  fpr_hart_t *h = fpr_hart();
  acb_t *a = h ? h->current : 0;
  if (!a || a->id == 0) fpr_cpanic(why);
  char msg[200];
  uw n = 0;
  const char *pre = "actor failed: ";
  for (const char *c = pre; *c && n < sizeof msg - 1; c++) msg[n++] = *c;
  for (const char *c = why; *c && n < sizeof msg - 1; c++) msg[n++] = *c;
  fpr_logput(2, msg, n);
  (void)a_kill((V)a);
  fpr_cpanic("actors: a failed actor resumed");
  for (;;) FPR_PARK();
}

FPR_FN(fpr_g_Sys_x2esleepUs, a_sleep_us, 1);
/* wake the sleepers whose time has come (hart loop, every pass) */
static void slp_drain(fpr_hart_t *h) {
  if (!h->slp_head) return;
  uint64_t now = hal_mtime();
  acb_t **pp = &h->slp_head;
  int fired = 0;
  while (*pp) {
    acb_t *a = *pp;
    uint32_t st = __atomic_load_n(&a->var, __ATOMIC_ACQUIRE);
    if (now >= a->wake_at || st == ST_DEAD) {
      *pp = a->slp_next;
      __atomic_store_n(&a->slp_on, 0, __ATOMIC_RELEASE); /* after the unlink: a_sleep_us reads it */
      __atomic_fetch_sub(&g_sleepers, 1, __ATOMIC_RELAXED);
      if (st != ST_DEAD) wake(a);
      else if (!__atomic_load_n(&a->running, __ATOMIC_ACQUIRE)) reap(a);
      fired = 1;
    } else
      pp = &a->slp_next;
  }
  if (fired && h->id != 0) hal_timer_park(h->id); /* MTIP would pend forever (see tmr_drain) */
}
/* before wfi: the nearest sleeper deadline arms the hart's timer (bare
 * metal; a no-op on qosp, whose wfi is a 200 us poll) */
static void slp_wfi_arm(fpr_hart_t *h) {
  if (!h->slp_head) return;
  uint64_t now = hal_mtime(), best = 0;
  for (acb_t *a = h->slp_head; a; a = a->slp_next)
    if (!best || a->wake_at < best) best = a->wake_at;
  uint64_t delta = best > now ? best - now : 1;
  if (h->id == 0 && delta > DETECT_TICKS) return; /* the detector's own arm is sooner */
  hal_timer_arm(h->id, delta);
}

/* channel emptiness/content tests (consumer side: acquire on rt) */
static uint32_t ch_count(chan_t *c) {
  return __atomic_load_n(&c->rt, __ATOMIC_ACQUIRE) - c->rh;
}
/* the same, for the CONSUMER only: rt is the producer's line, re-read only
 * when the cached view says the channel is empty -- which is exactly when
 * a wait has to see a newly published message, so blocking stays sound */
static uint32_t ch_avail(chan_t *c) {
  /* signed: receiveRes can take past the cached view (it scans to the
   * real rt), and a reclaimed channel keeps an old view -- either way the
   * cache is behind rh, and that means re-read, never "4 billion queued" */
  int32_t n = (int32_t)(c->rt_seen - c->rh);
  if (n > 0) return (uint32_t)n;
  c->rt_seen = __atomic_load_n(&c->rt, __ATOMIC_ACQUIRE);
  return c->rt_seen - c->rh;
}

static int p_any(acb_t *a, uw unused) {
  (void)unused;
  for (int i = 0; i < MAXSND; i++)
    if (__atomic_load_n(&a->ch[i].sender, __ATOMIC_ACQUIRE) && ch_avail(&a->ch[i])) return 1;
  return 0;
}

/* the shared ring holds a message from sid?  (tags were written before
 * rt was released, so an acquire on rt makes them visible) */
static int sh_has_from(acb_t *a, uw sid, uint32_t *at) {
  chan_t *c = sh_chan(a);
  uint32_t rt = __atomic_load_n(&c->rt, __ATOMIC_ACQUIRE);
  ringv_t *rv = __atomic_load_n(&c->rv, __ATOMIC_ACQUIRE); /* after rt */
  for (uint32_t k = c->rh; k != rt; k++)
    if (TAGAT(rv, k) == sid) { if (at) *at = k; return 1; }
  return 0;
}
static int p_from(acb_t *a, uw sid) {
  chan_t *c = chan_for(a, sid, 0);
  return (c && ch_avail(c)) || sh_has_from(a, sid, 0);
}

/* receiveFromRes waits for a message from sid OR for sid's death */
static int p_from_dead(acb_t *a, uw sid) {
  return p_from(a, sid) || __atomic_load_n(&((acb_t *)sid)->var, __ATOMIC_SEQ_CST) == ST_DEAD;
}

static int p_res(acb_t *a, uw unused) {
  (void)unused;
  for (int i = 0; i < MAXSND; i++) {
    chan_t *c = &a->ch[i];
    if (!__atomic_load_n(&c->sender, __ATOMIC_ACQUIRE)) continue;
    uint32_t rt = __atomic_load_n(&c->rt, __ATOMIC_ACQUIRE);
    ringv_t *rv = __atomic_load_n(&c->rv, __ATOMIC_ACQUIRE);
    for (uint32_t k = c->rh; k != rt; k++) {
      V m = SLOT(rv, k);
      if (!ISINT(m) && TID(m) == T_RESULT) return 1;
    }
  }
  return 0;
}

/* remove the message at logical position k (rh <= k < rt), shifting the
 * head side down one -- all touched slots are consumer-owned (< rt). */
static V take_at(acb_t *a, chan_t *c, uint32_t k) {
  uint32_t rh = c->rh;
  if (k == rh) { /* the head: no shifting, no lock (the caller loaded rt first) */
    ringv_t *rv = __atomic_load_n(&c->rv, __ATOMIC_ACQUIRE);
    V m = SLOT(rv, k);
    __atomic_store_n(&c->rh, rh + 1, __ATOMIC_RELEASE); /* frees a slot */
    return m;
  }
  /* shifting rewrites consumer-owned slots; a producer growing the
   * ring copies those same slots, so the two exclude each other */
  fpr_lock(&a->shlock);
  ringv_t *rv = c->rv;
  V m = SLOT(rv, k);
  for (uint32_t j = k; j > rh; j--) {
    SLOT(rv, j) = SLOT(rv, j - 1);
    if (rv->from) TAGAT(rv, j) = TAGAT(rv, j - 1);
  }
  __atomic_store_n(&c->rh, rh + 1, __ATOMIC_RELEASE);
  fpr_unlock(&a->shlock);
  return m;
}

/* ---- boot: hart entry points (called from crt0) ----------------------- */

static acb_t main_acb; /* actor 0 */

void fpr_actors_init(void) { /* hart 0, before fpr_smp_go */
  fpr_irq_hart = fpr_live_harts - 1; /* interrupts belong to the last hart */
  for (uw i = 0; i < fpr_live_harts; i++) hal_timer_park(i);
  main_acb.tid = T_ACTOR;
  main_acb.var = ST_READY;
  main_acb.ch = chb_take();
  if (!main_acb.ch) fpr_cpanic("boot: no memory for actor 0's channels");
  main_acb.scan = 0;
  __builtin_memset(&main_acb.shlock, 0, sizeof main_acb.shlock);
  main_acb.prio = 0;
  main_acb.in_rq = 0;
  main_acb.mbdyn = 1; /* actor 0 hosts services: its rings grow */
  main_acb.mbcap = RING_CAP;
  for (int i = 0; i < MAXSND; i++) main_acb.ch[i].dyn = 1; /* the shared
                                 * ring too: chan_for only stamps the
                                 * dedicated slots, and a fan-in of
                                 * more than 7 senders lands there */
  main_acb.mem_reply = 0;
  main_acb.entry_hold = 0;
  main_acb.entry = 0; /* trampoline runs fpr_fn_main + fpr_exit */
  main_acb.id = 0;
  main_acb.hart = 0;
  main_acb.pin = 1; /* the result carrier never migrates */
  main_acb.parent = 0;
  main_acb.pid = 0;
  main_acb.external_cleanup = 0; main_acb.external_arg = 0;
  ledger_push(&main_acb);
  uw stk_sz = 0;
  char *stk = (char *)stack_block(&stk_sz);
  if (!stk) fpr_cpanic("boot: no block for actor 0's stack");
  static void *main_bkts[FPR_NBUCKETS]; /* actor 0 lives forever */
  fpr_pool_init(&main_acb.pool, main_bkts);
  main_acb.dp_n = 0;
  main_acb.msg_slab = 0;
  main_acb.stack = stk;
  main_acb.stack_sz = stk_sz;
  main_acb.slp_on = 0;
  main_acb.segs = main_acb.spare = 0;
  main_acb.stk_total = 0;
  stk_window(&main_acb, 0, stk, stk_sz);
  for (int i = 0; i < 16; i++) main_acb.ctx[i] = 0;
  fpr_ctx_fabricate(main_acb.ctx, (void (*)(void))trampoline,
                    ((uw)stk + stk_sz) & ~(uw)15, &fpr_harts[0]);
  enq(&fpr_harts[0], &main_acb);
  fpr_mem_spawn(); /* the memory actor, second in hart 0's queue */
}

void fpr_hart_main(int id) { /* boot stack becomes the hart loop */
  hart_loop(&fpr_harts[id]);
}

void fpr_hart_secondary(int id) {
  fpr_set_tp(&fpr_harts[id]);
  fpr_rvv_enable(); /* mstatus.VS is per-hart */
  hart_loop(&fpr_harts[id]);
}

/* ---- FPRISC-facing API ------------------------------------------------ */

static V spawn_on(uw hart, V f, uw pin) {
  return spawn_on_pid(hart, f, pin, (uw)-1);
}
/* pid (uw)-1 = inherit from the spawner (the transparent default);
 * the loader passes a fresh pid for a process's root actor */
static V spawn_on_pid_cap(uw hart, V f, uw pin, uw pid, uint32_t cap, uint32_t dyn);
static V spawn_on_pid(uw hart, V f, uw pin, uw pid) {
  return spawn_on_pid_cap(hart, f, pin, pid, RING_CAP, 0);
}
typedef struct {
  acb_t *acb;
  char *stack;
  uw stack_size;
  void **buckets;
  chan_t *channels;
  fpr_slab_t *entry_hold;
  fpr_slab_t *grant;
} admission_t;
static V spawn_on_pid_cap_heap(uw hart, V f, uw pin, uw pid, uint32_t cap, uint32_t dyn,
                              fpr_slab_t *grant, uw heap_bytes, admission_t *admitted);
static V spawn_on_pid_cap(uw hart, V f, uw pin, uw pid, uint32_t cap, uint32_t dyn) {
  return spawn_on_pid_cap_heap(hart, f, pin, pid, cap, dyn, 0, 0, 0);
}
static V spawn_on_pid_cap_heap(uw hart, V f, uw pin, uw pid, uint32_t cap, uint32_t dyn,
                              fpr_slab_t *grant, uw heap_bytes, admission_t *admitted) {
  fpr_spawns++;
  if (hart >= fpr_live_harts) fpr_cpanic("spawnOn: no such hart (Sys.harts is the live count)");
  if (ISINT(f) || TID(f) != T_PAP) fpr_cpanic("spawn: argument must be a function");
  acb_t *a = admitted ? admitted->acb : (acb_t *)acb_block();
  uw stk_sz = admitted ? admitted->stack_size : 0;
  char *stk = admitted ? admitted->stack : (char *)stack_block(&stk_sz);
  if (!a || !stk) fpr_cpanic("spawn: buddy has no free block");
  fpr_pool_init(&a->pool, admitted ? admitted->buckets : fpr_bkt_take()); /* zeroed; teardown returns it */
  if (grant) {
    grant->next = 0; grant->owner = &a->pool;
    grant->escaped = grant->holds = 0;
    grant->hp = (char *)(grant + 1);
    grant->end = grant->hp + heap_bytes;
    a->pool.cur = grant;
    a->pool.fixed_heap = heap_bytes;
  }
  a->mem_reply = 0;
  a->pool_override = 0;
  a->dp_n = 0;
  a->msg_slab = 0;
  a->running = 0; /* the block may be reused: no hart has this context yet */
  a->irq_target = 0;
  if (!a->pool.buckets) fpr_cpanic("spawn: no memory for a bucket array");
  a->entry_hold = admitted ? admitted->entry_hold : 0;
  if (!admitted) f = fpr_msg_copy_to(f, pid != (uw)-1 ? pid : fpr_current_pid());
                       /* the entry closure crosses like any message:
                        * deep-copied, so captures never dangle into
                        * the spawner's pool */
  if (!admitted) fpr_arc_incref(f); /* admitted copies have their own slab hold */
  a->tid = T_ACTOR;
  a->var = ST_READY;
  a->ch = admitted ? admitted->channels : chb_take(); /* cleared by chb_take */
  if (!a->ch) fpr_cpanic("spawn: no memory for a channel block");
  a->mbdyn = dyn;
  a->mbcap = cap;
  a->prio = 0;
  a->in_rq = 0;
  for (int i = 0; i < MAXSND; i++) {
    a->ch[i].dyn = dyn;
    if (cap > RING_CAP) { /* a bigger first ring than the inline one */
      ringv_t *rv = ring_block(cap, i == SHIDX, a->ch[i].rv);
      if (!rv) fpr_cpanic("spawn: no memory for the mailbox rings (spawnCap)");
      a->ch[i].rv = rv;
    } else
      a->ch[i].rv0.cap = cap; /* a smaller ring in the inline slots (masked) */
  }
  a->scan = 0;
  __builtin_memset(&a->shlock, 0, sizeof a->shlock);
  a->in_bl = 0;
  a->tr_i = 0;
  a->entry = f;
  a->next = 0;
  a->stack = stk;
  a->stack_sz = stk_sz;
  a->external_cleanup = 0; a->external_arg = 0;
  a->wait_kind = a->wait_arg = 0;
  a->slp_on = 0;
  a->segs = a->spare = 0;
  a->stk_total = 0;
  stk_window(a, 0, stk, stk_sz);
  a->id = __atomic_add_fetch(&next_id, 1, __ATOMIC_RELAXED);
  a->hart = hart;
  a->pin = pin;
  {
    acb_t *cur = fpr_hart()->current;
    a->parent = cur ? cur->id : 0;
    a->pid = pid != (uw)-1 ? pid : (cur ? cur->pid : 0);
  }
  ledger_push(a);
  for (int i = 0; i < 16; i++) a->ctx[i] = 0;
  /* first-activation state is machine-specific (x86 needs a stack-
   * alignment bias; rv needs tp) -- the ctx layer owns fabrication */
  fpr_ctx_fabricate(a->ctx, (void (*)(void))trampoline,
                    ((uw)stk + stk_sz) & ~(uw)15, &fpr_harts[hart]);
  /* everything above happens-before the ship (ring release / same-hart
   * program order), so the owner hart sees a fully built acb */
  ship(a);
  return (V)a;
}

static V a_spawn(V f) {
  if (fpr_plane_actors) return fpr_plane_actors->spawn(f);
  return spawn_on(fpr_hart()->id, f, 0);
}
/* spawnCap mode n f / spawnCapOn hart mode n f: the mailbox policy --
 * mode 0 Static n (rings of n, never grow: a WCET bound), 1 Dynamic n
 * (rings start at n and double when full).  n rounds up to a power of
 * two, 8..RING_MAX.  On the shared plane the policy goes through the
 * actors table (spawn_cap), so a process's Static ring refuses and says
 * so exactly as the plane's own would. */
static uint32_t cap_of(V nv) {
  if (!ISINT(nv)) fpr_cpanic("spawnCap: n must be an Int");
  sw n = UNTAG(nv);
  uint32_t c = 8;
  while ((sw)c < n && c < RING_MAX) c <<= 1;
  return c;
}
static V a_spawn_cap(V modev, V nv, V f) {
  if (fpr_plane_actors) return fpr_plane_actors->spawn_cap(TAG(0), 0, modev, nv, f);
  if (!ISINT(modev)) fpr_cpanic("spawnCap: mode must be an Int");
  return spawn_on_pid_cap(fpr_hart()->id, f, 0, (uw)-1, cap_of(nv), UNTAG(modev) != 0);
}
/* First admission slice: one pre-granted local HEAP, not a total actor
 * budget. Infrastructure and messaging retain their existing allocation. */
#define HEAP_ERR(name, text) \
  static const struct { hdr_t h; uw len; char bytes[sizeof(text)]; } name##_s = \
    {{T_STR, 0}, sizeof(text) - 1, text}; \
  static const struct { hdr_t h; V value; } name = {{T_RESULT, 1}, (V)&name##_s}
HEAP_ERR(heap_size, "fixed heap: bytes must be positive");
HEAP_ERR(heap_entry, "fixed heap: entry must be a function");
HEAP_ERR(heap_large, "fixed heap: grant too large");
HEAP_ERR(heap_denied, "fixed heap: admission denied");
#undef HEAP_ERR
/* This record lives on the spawner's stack. A parked spawner may be
 * killed; the reaper runs cleanup before freeing that stack. No reserved
 * child pointer has been published, so its control blocks are reusable. */
static void admission_rollback(void *arg) {
  admission_t *ad = (admission_t *)arg;
  if (ad->acb) fpr_fl_put(&acb_unpublished, ad->acb, sizeof(acb_t));
  if (ad->entry_hold) fpr_slab_unhold(ad->entry_hold, 0);
  if (ad->channels) fpr_fl_put(&chb_fl, ad->channels, sizeof(chblk_t));
  if (ad->buckets) fpr_bkt_put(ad->buckets);
  if (ad->stack) stack_recycle(ad->stack, ad->stack_size);
  if (ad->grant) fpr_slab_release(ad->grant);
  /* response belongs to the spawner's pool: ordinary refusal frees it
   * below; cancellation's pool teardown owns it, never the reaper's pool. */
}
/* Test faults are linked only into explicit admission-test builds.  Each
 * phase is after a reservation, so every partial prefix is exercised. */
#ifdef FPR_ADMISSION_TEST
extern int fpr_admission_test_fail(uw phase);
#define ADMISSION_FAIL(phase) fpr_admission_test_fail(phase)
#else
#define ADMISSION_FAIL(phase) 0
#endif
static V a_spawn_heap(V bytesv, V f) {
  if (fpr_plane_actors) return fpr_plane_actors->spawn_heap(bytesv, f);
  if (!ISINT(bytesv) || UNTAG(bytesv) <= 0) return (V)&heap_size;
  if (ISINT(f) || TID(f) != T_PAP) return (V)&heap_entry;
  uw bytes = (uw)UNTAG(bytesv);
  if (bytes > ((uw)-1 >> 2)) return (V)&heap_large;
  /* Allocating the response belongs to the spawner, before any reservation.
   * It is freed on refusal. No child is registered or scheduled until commit. */
  hdr_t *r = (hdr_t *)fpr_alloc(8 + sizeof(V));
  admission_t ad = {0};
  if (!fpr_actor_cleanup_set(admission_rollback, &ad)) { fpr_free((V)r); return (V)&heap_denied; }
  ad.grant = fpr_slab_new(bytes + sizeof(fpr_slab_t));
  if (!ad.grant || ADMISSION_FAIL(1)) goto denied;
  ad.stack = (char *)stack_block(&ad.stack_size);
  if (!ad.stack || ADMISSION_FAIL(2)) goto denied;
  ad.buckets = fpr_bkt_take();
  if (!ad.buckets || ADMISSION_FAIL(3)) goto denied;
  ad.channels = chb_take();
  if (!ad.channels || ADMISSION_FAIL(4)) goto denied;
  V entry;
  if (!fpr_entry_copy_try(f, fpr_current_pid(), &entry, &ad.entry_hold) || ADMISSION_FAIL(5)) goto denied;
  ad.acb = acb_block();
  if (!ad.acb || ADMISSION_FAIL(6)) goto denied;
  /* From here initialization and shipping do not park or allocate. */
  fpr_actor_cleanup_clear(&ad);
  V actor = spawn_on_pid_cap_heap(fpr_hart()->id, entry, 0, (uw)-1, RING_CAP, 0, ad.grant, bytes, &ad);
  r->tid = T_RESULT; r->var = 0;
  *(V *)((char *)r + 8) = actor;
  return (V)r;
denied:
  fpr_actor_cleanup_clear(&ad);
  admission_rollback(&ad);
  fpr_free((V)r);
  return (V)&heap_denied;
}
#undef ADMISSION_FAIL
static V a_spawn_cap_on(V hv, V modev, V nv, V f) {
  if (fpr_plane_actors) return fpr_plane_actors->spawn_cap(hv, 1, modev, nv, f);
  if (!ISINT(hv) || !ISINT(modev)) fpr_cpanic("spawnCapOn: hart and mode must be Ints");
  return spawn_on_pid_cap((uw)UNTAG(hv), f, 1, (uw)-1, cap_of(nv), UNTAG(modev) != 0);
}
static V a_spawn_at(V hv, V f) {
  if (fpr_plane_actors) return fpr_plane_actors->spawn_at(hv, f);
  if (ISINT(hv) == 0) fpr_cpanic("spawnOn: hart must be an Int");
  return spawn_on((uw)UNTAG(hv), f, 1); /* explicit placement pins */
}

/* Sys.spawnApp f -> actor: run `f me` under a FRESH pid -- the app-
 * image launch (std/loader.fpr `launch`): the shell's actors stay pid
 * 0, the app's root gets the next pid and everything it spawns
 * inherits it, so Sys.actInfo / myPid tell the images apart.  Not
 * routed: an image on the shared plane is itself a process already. */
static uw next_pid; /* 0 = the boot image; apps count up from 1 */
static V a_spawn_app(V f) {
  if (fpr_plane_actors) fpr_cpanic("Sys.spawnApp: only the plane's own image launches apps");
  if (ISINT(f) || TID(f) != T_PAP) fpr_cpanic("Sys.spawnApp: argument must be a function");
  uw pid = __atomic_add_fetch(&next_pid, 1, __ATOMIC_RELAXED);
  /* the image the root's code lives in (an attached, not yet launched
   * image is pid 0) becomes this process's: it is freed with the pid
   * (runtime.c fpr_image_adopt; the loader's fpr_pid_quiet hook) */
  (void)fpr_image_adopt((const void *)((pap0_t *)f)->fn, pid);
  return spawn_on_pid(fpr_hart()->id, f, 0, pid);
}
FPR_FN(fpr_g_Sys_x2espawnApp, a_spawn_app, 1);

/* Sys.pidOf a -> Int: the process an actor belongs to (0 = the boot
 * image).  The namespace (qos mods/ep.fpr) authorizes an open by the
 * CALLER's pid: the grants a process was launched with, looked up by
 * the sender of the request, never by anything the request says. */
static V a_pid_of(V av) {
  if (ISINT(av) || TID(av) != T_ACTOR) fpr_cpanic("Sys.pidOf: argument is not an actor");
  return TAG((sw)((acb_t *)av)->pid);
}
FPR_FN(fpr_g_Sys_x2epidOf, a_pid_of, 1);

/* Sys.alive a -> Bool: has the actor not ended?  A service that holds a
 * client's session (the graphics service's focus) asks before keeping it;
 * a reply's refusal is the other way a dead client is learned of. */
static V a_alive(V av) {
  if (ISINT(av) || TID(av) != T_ACTOR) fpr_cpanic("Sys.alive: argument is not an actor");
  return BOOL(__atomic_load_n(&((acb_t *)av)->var, __ATOMIC_ACQUIRE) != ST_DEAD);
}
FPR_FN(fpr_g_Sys_x2ealive, a_alive, 1);

uw fpr_current_pid(void) {
  fpr_hart_t *h = fpr_hart();
  acb_t *cur = h ? h->current : 0;
  return cur ? cur->pid : 0;
}

/* myPid u -> Int: the ACB's owning process (0 = the boot image) */
static V a_mypid(V u) {
  (void)u;
  acb_t *cur = fpr_hart()->current;
  return TAG((sw)(cur ? cur->pid : 0));
}
FPR_FN(fpr_g_myPid, a_mypid, 1);



/* the send core, sender key EXPLICIT: a_send passes the current acb;
 * the SYSCALL TRAMPOLINE (process.c) passes its dormant reply mailbox
 * so a loaded process -- which lives in its own scheduler world -- can
 * still publish into System.qa's storage actor. */
/* A FULL RING IS AN ANSWER, not a wait: send returns Result Unit
 * String -- Ok when the message is queued, Err "mailbox full" when a
 * Static ring has no room (or a Dynamic one cannot grow), Err "dead
 * actor" for a target that has exited.  Nothing in the runtime ever
 * spins or yields for mailbox space any more (the old backpressure
 * could deadlock two actors waiting on each other's full rings, and
 * hid every burst that outran a consumer).  The sender decides: retry,
 * back off, drop, or die -- std wraps the common policies, and
 * services spawn Dynamic so a burst costs memory, not messages. */
static const struct { hdr_t h; V f; } ok_unit_s = {{T_RESULT, 0}, (V)&fpr_unit};
#define OK_UNIT ((V)&ok_unit_s)
static V send_err(const char *why) { fpr_send_full++; return fpr_mkresult(1, why); }
int fpr_sent(V r) { return !ISINT(r) && TID(r) == T_RESULT && ((hdr_t *)r)->var == 0; }

static acb_t *mem_act; /* the memory actor (below); 0 before it exists */

/* install nv as c's ring, under a->shlock: [rh, rt) copied by logical
 * index, the pointer published (before any rt that lands in it). */
static void ring_install(chan_t *c, ringv_t *nv) {
  ringv_t *ov = c->rv;
  uint32_t rh = __atomic_load_n(&c->rh, __ATOMIC_ACQUIRE), rt = c->rt;
  for (uint32_t k = rh; k != rt; k++) {
    SLOT(nv, k) = SLOT(ov, k);
    if (nv->from) TAGAT(nv, k) = TAGAT(ov, k);
  }
  nv->old = ov;
  __atomic_store_n(&c->rv, nv, __ATOMIC_RELEASE);
  fpr_ring_grows++;
}
/* place m (already copied and pinned) on channel c of a: 1 queued, 0
 * full.  A Dynamic ring that is full doubles -- and the new block is
 * taken OUTSIDE a->shlock (it may come from the memory actor, which is
 * a wait; a spinlock is never held across one), then installed under
 * the lock after a re-check: on the shared ring another producer may
 * have grown it meanwhile, and ours goes back.  The memory actor's own
 * rings grow through the direct path: a request to it cannot be what
 * makes room for that request. */
static int ring_push(acb_t *a, chan_t *c, uw key, V m) {
  int shared = c->sender == SHARED_KEY; /* many producers: the lock orders them */
  for (;;) {
    if (shared) fpr_lock(&a->shlock);
    ringv_t *rv = c->rv; /* dedicated: single producer, private rt */
    uint32_t rt = c->rt;
    /* the cached head first: rh is the consumer's line, read only when
     * the ring looks full (a stale view is never ahead of rh, so the
     * check can only err towards re-reading) */
    if (rt - c->rh_seen >= rv->cap) c->rh_seen = __atomic_load_n(&c->rh, __ATOMIC_ACQUIRE);
    if (rt - c->rh_seen < rv->cap) {
      if (shared) TAGAT(rv, rt) = key;
      SLOT(rv, rt) = m;
      __atomic_store_n(&c->rt, rt + 1, __ATOMIC_RELEASE); /* publish */
      if (shared) fpr_unlock(&a->shlock);
      return 1;
    }
    uint32_t ncap = rv->cap * 2;
    int can = c->dyn && rv->cap < RING_MAX;
    if (shared) fpr_unlock(&a->shlock);
    if (!can) return 0;
    ringv_t *nv = ring_block_d(ncap, shared, 0, a == mem_act);
    if (!nv) return 0;
    fpr_lock(&a->shlock); /* take_at's shifting and the copy exclude each other */
    if (c->rv->cap >= ncap) { /* a racer grew it first */
      fpr_unlock(&a->shlock);
      if (fpr_mem_own) fpr_mem_give(nv);
      continue;
    }
    ring_install(c, nv);
    fpr_unlock(&a->shlock);
  }
}
V fpr_send_as(uw sender_key, V av, V m) {
  if (fpr_plane_actors) return fpr_plane_actors->send_as(sender_key, av, m);
  if (ISINT(av) || TID(av) != T_ACTOR) fpr_cpanic("send: target is not an actor");
  acb_t *a = (acb_t *)av;
  if (__atomic_load_n(&a->var, __ATOMIC_ACQUIRE) == ST_DEAD)
    return send_err("dead actor");
#ifdef FPR_COST_PROBE
  fpr_hart_t *ph = fpr_hart();
  uint64_t q0 = FPR_PROBE_NOW();
#endif
  chan_t *c = chan_for(a, sender_key, 1);
  m = fpr_msg_copy_to(m, a->pid); /* DEEP COPY: the receiver gets a self-contained
                        * slab; nothing the sender does afterward can
                        * touch it, and drop-of-root frees all of it */
#ifdef FPR_COST_PROBE
  uint64_t q1 = FPR_PROBE_NOW();
#endif
  fpr_arc_incref(m); /* promotion: heap values become shared on send */
#ifdef FPR_COST_PROBE
  uint64_t q2 = FPR_PROBE_NOW();
#endif
  if (!ring_push(a, c, sender_key, m)) {
    fpr_arc_decref(m); /* the copy goes back: nobody will receive it */
    return send_err("mailbox full");
  }
#ifdef FPR_COST_PROBE
  uint64_t q3 = FPR_PROBE_NOW();
#endif
  __atomic_thread_fence(__ATOMIC_SEQ_CST); /* Dekker: publish before flag read */
  wake(a);
#ifdef FPR_COST_PROBE
  uint64_t q4 = FPR_PROBE_NOW();
  FPR_COST_ADD(ph, xs_send_n, 1);
  FPR_COST_ADD(ph, xs_send_ns, q4 - q0);
  FPR_COST_ADD(ph, xs_copy_ns, q1 - q0);
  FPR_COST_ADD(ph, xs_arc_ns, q2 - q1);
  FPR_COST_ADD(ph, xs_push_ns, q3 - q2);
  FPR_COST_ADD(ph, xs_wake_ns, q4 - q3);
#endif
  return OK_UNIT;
}

static V a_send(V av, V m) {
  return fpr_send_as((uw)fpr_hart()->current, av, m);
}

/* sendLinear: MOVE the message (docs/2026-08-25-MEMORY.md v2, the send triad).
 * The compiler's linearity checker consumes the payload argument, so
 * the sender's binding is unusable afterward -- send_linear IS the
 * value's release.  Mechanism, two cases:
 *
 *   TRANSFER -- the value is a received message root (ownerless slab,
 *   tracked in the ARC table, fpr_arc_movable_root): enqueue the SAME
 *   pointer.  No copy, no incref -- the one standing count changes
 *   hands, and the receiver's ordinary drop parks the slab exactly as
 *   if it had been sent fresh.  A relay chain (the frames ping-pong)
 *   is zero-copy end to end.
 *
 *   COPY+CONSUME -- anything else (a locally built value, a child of
 *   a still-held message): deep-copy like send, then release what the
 *   sender owned.  A Vector root is freed on the spot (its columns
 *   are the bulk); other locals stay pool-scoped, consumed in the
 *   checker's eyes and reclaimed with the pool as ever.
 *
 * A dead target still consumes: the contract is "this value left me",
 * so it is released exactly as a received-then-dropped message would
 * be, never silently retained. */
static V a_send_linear(V av, V m) {
  if (fpr_plane_actors) return fpr_plane_actors->send_as((uw)fpr_hart()->current, av, m);
  if (ISINT(av) || TID(av) != T_ACTOR) fpr_cpanic("sendLinear: target is not an actor");
  acb_t *a = (acb_t *)av;
  /* a move shares the value's statics too: across processes it copies,
   * so nothing it holds can outlive a process image (runtime.c) */
  int movable = fpr_arc_movable_root(m) && a->pid == fpr_current_pid();
  if (__atomic_load_n(&a->var, __ATOMIC_ACQUIRE) == ST_DEAD) {
    if (movable) fpr_arc_decref(m); /* the drop the receiver would have done */
    else if (!ISINT(m) && fpr_in_heap(m) && TID(m) == T_VEC)
      fpr_vec_release(m);
    return send_err("dead actor");
  }
  chan_t *c = chan_for(a, (uw)fpr_hart()->current, 1);
  if (!movable) {
    V orig = m;
    m = fpr_msg_copy_to(m, a->pid);
    fpr_arc_incref(m);
    if (!ISINT(orig) && fpr_in_heap(orig) && TID(orig) == T_VEC)
      fpr_vec_release(orig); /* the bulk case: consume frees it now */
  }
  if (!ring_push(a, c, (uw)fpr_hart()->current, m)) {
    fpr_arc_decref(m); /* consumed either way: the value left the sender */
    return send_err("mailbox full");
  }
  __atomic_thread_fence(__ATOMIC_SEQ_CST); /* Dekker: publish before flag read */
  wake(a);
  return OK_UNIT;
}

/* ---- the SYSCALL MAILBOX (process.c's trampoline) -------------------
 * A dormant acb that is never scheduled: var is pinned ST_READY so a
 * sender's wake CAS(BLOCKED->READY) always fails -- replies are
 * PUBLISHED but nothing ever ships this acb to a run queue.  The
 * trampoline (not an actor; it runs on the process's stack) spin-scans
 * its channels for the next T_RESULT.  Single caller by construction:
 * one process slot, one synchronous syscall at a time. */
static acb_t syscall_mb;
void *fpr_syscall_mailbox(void) {
  if (syscall_mb.tid != T_ACTOR) {
    syscall_mb.tid = T_ACTOR;
    syscall_mb.var = ST_READY; /* pinned: wake CAS never matches */
    syscall_mb.hart = 0;
    static chblk_t syscall_chb; /* static: the mailbox never dies */
    for (int i = 0; i < MAXSND; i++) chan_init(&syscall_chb.ch[i], i == SHIDX ? syscall_chb.shfrom : 0, 1);
    syscall_chb.ch[SHIDX].sender = SHARED_KEY;
    syscall_mb.ch = syscall_chb.ch;
  }
  return &syscall_mb;
}

V fpr_syscall_wait_result(void) {
  acb_t *a = &syscall_mb;
  for (;;) {
    for (int i = 0; i < MAXSND; i++) {
      chan_t *c = &a->ch[i];
      if (!__atomic_load_n(&c->sender, __ATOMIC_ACQUIRE)) continue;
      uint32_t rt = __atomic_load_n(&c->rt, __ATOMIC_ACQUIRE);
      ringv_t *rv = __atomic_load_n(&c->rv, __ATOMIC_ACQUIRE);
      for (uint32_t k = c->rh; k != rt; k++) {
        V m = SLOT(rv, k);
        if (!ISINT(m) && TID(m) == T_RESULT) return take_at(a, c, k);
      }
    }
    __asm__ volatile("" ::: "memory"); /* spin; hart 1 serves storage */
  }
}

/* fair receive: round-robin over channels, FIFO within a channel */
static V a_receive(V me) {
  if (fpr_plane_actors) return fpr_plane_actors->receive(me);
  fpr_hart_t *h = fpr_hart();
  if (ISINT(me) || (acb_t *)me != h->current)
    fpr_cpanic("receive: not the current actor's handle");
  acb_t *a = h->current;
  drop_drain(a); /* the previous activation's borrows are dead here */
#ifdef FPR_COST_PROBE
  uint64_t r0 = FPR_PROBE_NOW();
#endif
  for (;;) {
    for (int n = 0; n < MAXSND; n++) {
      chan_t *c = &a->ch[(a->scan + n) % MAXSND];
      if (__atomic_load_n(&c->sender, __ATOMIC_ACQUIRE) && ch_avail(c)) {
        a->scan = (a->scan + n + 1) % MAXSND;
        V got = take_at(a, c, c->rh);
#ifdef FPR_COST_PROBE
        FPR_COST_ADD(fpr_hart(), xr_recv_n, 1);
        FPR_COST_ADD(fpr_hart(), xr_scan_ns, FPR_PROBE_NOW() - r0);
#endif
        return got;
      }
    }
#ifdef FPR_COST_PROBE
    FPR_COST_ADD(fpr_hart(), xr_scan_ns, FPR_PROBE_NOW() - r0);
    FPR_COST_ADD(fpr_hart(), xr_block_n, 1);
#endif
    block_unless(a, p_any, 0);
#ifdef FPR_COST_PROBE
    r0 = FPR_PROBE_NOW();
#endif
  }
}

/* receive WITHOUT WAITING: `Ok message` when one is there, and otherwise the
 * one static `Err "empty"` -- asking an empty mailbox allocates nothing, so an
 * actor may ask as often as it likes.  This is what lets ONE actor watch two
 * things: its mailbox and something it has to poll (std/poller.fpr: every
 * socket of a server), and it is the whole of a timed receive
 * (std/actor.fpr receiveWithin). */
static const struct { uint32_t tid, var; uw len; uint8_t bytes[8]; } __attribute__((aligned(8))) recv_empty_s = {T_STR, 0, 5, "empty"};
static const struct { uint32_t tid, var; V f; } __attribute__((aligned(8))) recv_empty = {T_RESULT, 1, (V)&recv_empty_s};
static V a_receive_now(V me) {
  if (fpr_plane_actors) return fpr_plane_actors->receive_now(me);
  fpr_hart_t *h = fpr_hart();
  if (ISINT(me) || (acb_t *)me != h->current)
    fpr_cpanic("receiveNow: not the current actor's handle");
  acb_t *a = h->current;
  drop_drain(a); /* the previous activation's borrows are dead here */
  for (int n = 0; n < MAXSND; n++) {
    chan_t *c = &a->ch[(a->scan + n) % MAXSND];
    if (__atomic_load_n(&c->sender, __ATOMIC_ACQUIRE) && ch_avail(c)) {
      a->scan = (a->scan + n + 1) % MAXSND;
      V m = take_at(a, c, c->rh);
      V *ok = (V *)fpr_alloc(8 + sizeof(uw));
      ((hdr_t *)ok)->tid = T_RESULT;
      ((hdr_t *)ok)->var = 0;
      FPR_FLD(ok, 0) = m;
      return (V)ok;
    }
  }
  return (V)&recv_empty;
}

/* selective receive by SENDER: only that sender's channel, FIFO */
static V a_receive_from(V me, V fromv) {
  if (fpr_plane_actors) return fpr_plane_actors->receive_from(me, fromv);
  fpr_hart_t *h = fpr_hart();
  if (ISINT(me) || (acb_t *)me != h->current)
    fpr_cpanic("receiveFrom: not the current actor's handle");
  if (ISINT(fromv) || TID(fromv) != T_ACTOR)
    fpr_cpanic("receiveFrom: sender is not an actor");
  acb_t *a = h->current;
  drop_drain(a); /* the previous activation's borrows are dead here */
  uw sid = (uw)fromv; /* the key IS the sender's acb */
#ifdef FPR_COST_PROBE
  uint64_t r0 = FPR_PROBE_NOW();
#define RECV_DONE(x) do { V got_ = (x); FPR_COST_ADD(fpr_hart(), xr_recv_n, 1); FPR_COST_ADD(fpr_hart(), xr_scan_ns, FPR_PROBE_NOW() - r0); return got_; } while (0)
#else
#define RECV_DONE(x) return (x)
#endif
  for (;;) {
    chan_t *c = chan_for(a, sid, 0);
    if (c && ch_avail(c)) RECV_DONE(take_at(a, c, c->rh));
    uint32_t k;
    if (sh_has_from(a, sid, &k)) RECV_DONE(take_at(a, sh_chan(a), k));
#ifdef FPR_COST_PROBE
    FPR_COST_ADD(fpr_hart(), xr_scan_ns, FPR_PROBE_NOW() - r0);
    FPR_COST_ADD(fpr_hart(), xr_block_n, 1);
#endif
    block_unless(a, p_from, sid);
#ifdef FPR_COST_PROBE
    r0 = FPR_PROBE_NOW();
#endif
  }
#undef RECV_DONE
}

/* selective receive by sender that ANSWERS: `Ok message`, or the static
 * `Err "dead actor"` once the sender has exited with nothing from it left
 * queued.  A plain receiveFrom on a sender that dies waits forever; this is
 * what a request/reply caller uses so a service that ends (its body
 * returned, or it was killed) is an answer rather than a stranded caller.
 *
 * Wake-up without a lost race: the waiter publishes `watch` and bumps the
 * sender's `watchers` BEFORE block_unless flips it BLOCKED and re-checks
 * p_from_dead; the dying actor stores DEAD (seq_cst) and then reads
 * `watchers`.  Either the waiter's re-check sees DEAD, or the dier sees
 * the count and finds `watch` pointing at it on the ledger walk. */
static const struct { uint32_t tid, var; uw len; uint8_t bytes[16]; } __attribute__((aligned(8))) recv_dead_s = {T_STR, 0, 10, "dead actor"};
static const struct { uint32_t tid, var; V f; } __attribute__((aligned(8))) recv_dead = {T_RESULT, 1, (V)&recv_dead_s};

static void wake_watchers(acb_t *s) {
  if (__atomic_load_n(&s->watchers, __ATOMIC_SEQ_CST) == 0) return;
  for (acb_t *a = __atomic_load_n(&g_all, __ATOMIC_ACQUIRE); a; a = a->all_nx)
    if (__atomic_load_n(&a->watch, __ATOMIC_SEQ_CST) == s) wake(a);
}

static V ok_of(V m) {
  V *ok = (V *)fpr_alloc(8 + sizeof(uw));
  ((hdr_t *)ok)->tid = T_RESULT;
  ((hdr_t *)ok)->var = 0;
  FPR_FLD(ok, 0) = m;
  return (V)ok;
}

static V a_receive_from_res(V me, V fromv) {
  if (fpr_plane_actors) return fpr_plane_actors->receive_from_res(me, fromv);
  fpr_hart_t *h = fpr_hart();
  if (ISINT(me) || (acb_t *)me != h->current)
    fpr_cpanic("receiveFromRes: not the current actor's handle");
  if (ISINT(fromv) || TID(fromv) != T_ACTOR)
    fpr_cpanic("receiveFromRes: sender is not an actor");
  acb_t *a = h->current;
  acb_t *s = (acb_t *)fromv;
  drop_drain(a); /* the previous activation's borrows are dead here */
  uw sid = (uw)fromv;
  for (;;) {
    /* read DEAD first: its seq_cst load orders every send the sender
     * made before dying ahead of the queue check below */
    int dead = __atomic_load_n(&s->var, __ATOMIC_SEQ_CST) == ST_DEAD;
    chan_t *c = chan_for(a, sid, 0);
    if (c && ch_avail(c)) return ok_of(take_at(a, c, c->rh));
    uint32_t k;
    if (sh_has_from(a, sid, &k)) return ok_of(take_at(a, sh_chan(a), k));
    if (dead) return (V)&recv_dead;
    __atomic_store_n(&a->watch, s, __ATOMIC_SEQ_CST);
    __atomic_fetch_add(&s->watchers, 1, __ATOMIC_SEQ_CST);
    block_unless(a, p_from_dead, sid);
    __atomic_fetch_sub(&s->watchers, 1, __ATOMIC_SEQ_CST);
    __atomic_store_n(&a->watch, 0, __ATOMIC_SEQ_CST);
  }
}

/* selective receive by TYPE: next T_RESULT from any channel */
static V a_receive_res(V me) {
  if (fpr_plane_actors) return fpr_plane_actors->receive_res(me);
  fpr_hart_t *h = fpr_hart();
  if (ISINT(me) || (acb_t *)me != h->current)
    fpr_cpanic("receiveRes: not the current actor's handle");
  acb_t *a = h->current;
  drop_drain(a); /* the previous activation's borrows are dead here */
  for (;;) {
    for (int n = 0; n < MAXSND; n++) {
      chan_t *c = &a->ch[(a->scan + n) % MAXSND];
      if (!__atomic_load_n(&c->sender, __ATOMIC_ACQUIRE)) continue;
      uint32_t rt = __atomic_load_n(&c->rt, __ATOMIC_ACQUIRE);
      ringv_t *rv = __atomic_load_n(&c->rv, __ATOMIC_ACQUIRE);
      for (uint32_t k = c->rh; k != rt; k++) {
        V m = SLOT(rv, k);
        if (!ISINT(m) && TID(m) == T_RESULT) return take_at(a, c, k);
      }
    }
    block_unless(a, p_res, 0);
  }
}

static V a_yield(V me) {
  if (fpr_plane_actors) {
    /* routed: requeue-and-reschedule THROUGH THE PLANE.  Running the
     * local enq here would push the acb through this image's private
     * copy of the backlog/donation machinery -- and a donation would
     * strand it in a steal ring no kernel hart ever reads. */
    fpr_hart_t *h = fpr_hart();
    if (ISINT(me) || (acb_t *)me != h->current)
      fpr_cpanic("yield: not the current actor's handle");
    fpr_plane_actors->fuel();
    return (V)&fpr_unit;
  }
  fpr_hart_t *h = fpr_hart();
  if (ISINT(me) || (acb_t *)me != h->current)
    fpr_cpanic("yield: not the current actor's handle");
  TR(h->current, 9);
  enq(h, h->current);
  to_sched();
  return (V)&fpr_unit;
}

static V a_kill(V av) {
  if (ISINT(av) || TID(av) != T_ACTOR) fpr_cpanic("kill: target is not an actor");
  acb_t *a = (acb_t *)av;
  uint32_t st = __atomic_load_n(&a->var, __ATOMIC_ACQUIRE);
  while (st != ST_DEAD &&
         !__atomic_compare_exchange_n(&a->var, &st, ST_DEAD, 0, __ATOMIC_SEQ_CST, __ATOMIC_ACQUIRE)) {}
  if (st == ST_DEAD) return (V)&fpr_unit; /* already ended: its watchers were woken then */
  wake_watchers(a);
  if (a == fpr_hart()->current) {
    to_sched(); /* never resumed: deq skips DEAD */
    fpr_cpanic("actors: dead actor resumed");
  }
  /* A READY actor is on a queue and a RUNNING one returns to its hart loop:
   * both are reaped there.  A BLOCKED one is on no queue, and nothing would
   * ever reap it -- its stack, pool and channel block leaked.  Hand it to
   * its owner hart, as a wake does: only that hart dequeues it, so it has
   * switched out before deq or the backlog scan reaps it (reap is idempotent,
   * and a sleeper's list entry is unlinked by slp_drain). */
  if (st == ST_BLOCKED) ship(a);
  return (V)&fpr_unit;
}

static V a_myself(V dummy) {
  (void)dummy;
  return (V)fpr_hart()->current;
}

static V g_hart_id(V d) { (void)d; return TAG((sw)fpr_hart()->id); }
static V g_harts(V d) { (void)d; return TAG((sw)fpr_live_harts); }

/* scheduler introspection + tuning (docs/2026-10-02-SCHED-MODEL.md) */
static V g_sched_tau(V d) { (void)d; return TAG((sw)g_tau); }
static V g_sched_set_tau(V n) { g_tau = (uw)UNTAG(n); return (V)&fpr_unit; }
static V g_sched_max_wait(V d) { (void)d; return TAG((sw)g_max_wait); }
static V g_sched_steals(V d) { (void)d; return TAG((sw)g_steals); }
static V g_sched_set_weight(V av, V w) {
  ((acb_t *)av)->weight = (uw)UNTAG(w) ? (uw)UNTAG(w) : 1;
  return (V)&fpr_unit;
}

/* fuel introspection, for /proc */
static V g_fuel_quantum(V d) { (void)d; return TAG(FUEL_QUANTUM); }
static V g_fuel_preempts(V d) {
  (void)d;
  uw t = 0;
  for (int i = 0; i < FPR_NHARTS; i++) t += fpr_harts[i].fuel_preempts;
  return TAG((sw)t);
}

/* ---- the discoverable-symbol table ------------------------------------ */
FPR_FN(fpr_g_spawn, a_spawn, 1);
FPR_FN(fpr_g_spawnHeap, a_spawn_heap, 2);
FPR_FN(fpr_g_spawnCap, a_spawn_cap, 3);
FPR_FN(fpr_g_spawnCapOn, a_spawn_cap_on, 4);
FPR_FN(fpr_g_spawnOn, a_spawn_at, 2);
/* sendArc: SHARE by explicit promotion (docs/2026-08-25-MEMORY.md v2) -- the
 * only path by which an object becomes cross-actor shared.  The
 * pointer itself crosses (no copy); the object is FROZEN BY CONTRACT
 * from this send onward (writes after sharing are races the runtime
 * cannot see -- which is why a Vector, linear bulk whose whole point
 * is mutation, is refused: move it or copy it).  Every holder,
 * sender included, releases with `drop`; the last drop reclaims.
 * Deep trees reclaim shallowly at zero (children are pool-scoped) --
 * share flat records/tuples, or accept pool lifetime for the rest. */
static V a_send_arc(V av, V m) {
  if (fpr_plane_actors) return fpr_plane_actors->send_as((uw)fpr_hart()->current, av, m);
  if (ISINT(av) || TID(av) != T_ACTOR) fpr_cpanic("sendArc: target is not an actor");
  if (!ISINT(m) && fpr_in_heap(m) && TID(m) == T_VEC)
    fpr_cpanic("sendArc: a Vector is linear bulk -- sendLinear moves it, send copies it");
  acb_t *a = (acb_t *)av;
  if (__atomic_load_n(&a->var, __ATOMIC_ACQUIRE) == ST_DEAD)
    return send_err("dead actor"); /* no promotion happened; sender keeps sole ownership */
  /* sharing across processes would let the receiver hold the sender's
   * image statics past its end: across processes, a share is a copy */
  if (a->pid != fpr_current_pid()) return fpr_send_as((uw)fpr_hart()->current, av, m);
  chan_t *c = chan_for(a, (uw)fpr_hart()->current, 1);
  fpr_arc_promote_share(m);
  if (!ring_push(a, c, (uw)fpr_hart()->current, m)) {
    fpr_arc_decref(m); /* the receiver's share, returned */
    return send_err("mailbox full");
  }
  __atomic_thread_fence(__ATOMIC_SEQ_CST); /* Dekker: publish before flag read */
  wake(a);
  return OK_UNIT;
}

FPR_FN(fpr_g_send, a_send, 2);
FPR_FN(fpr_g_sendLinear, a_send_linear, 2);
FPR_FN(fpr_g_sendArc, a_send_arc, 2);
FPR_FN(fpr_g_receive, a_receive, 1);
FPR_FN(fpr_g_receiveFrom, a_receive_from, 2);
FPR_FN(fpr_g_receiveRes, a_receive_res, 1);
FPR_FN(fpr_g_receiveNow, a_receive_now, 1);
FPR_FN(fpr_g_receiveFromRes, a_receive_from_res, 2);
FPR_FN(fpr_g_yield, a_yield, 1);
FPR_FN(fpr_g_kill, a_kill, 1);
FPR_FN(fpr_g_myself, a_myself, 1);
FPR_FN(fpr_g_hartId, g_hart_id, 1);
FPR_FN(fpr_g_schedTau, g_sched_tau, 1);
FPR_FN(fpr_g_schedSetTau, g_sched_set_tau, 1);
FPR_FN(fpr_g_schedMaxWait, g_sched_max_wait, 1);
FPR_FN(fpr_g_schedSteals, g_sched_steals, 1);
FPR_FN(fpr_g_schedSetWeight, g_sched_set_weight, 2);
FPR_FN(fpr_g_harts, g_harts, 1);
FPR_FN(fpr_g_fuelQuantum, g_fuel_quantum, 1);
FPR_FN(fpr_g_fuelPreempts, g_fuel_preempts, 1);

/* debug: which actor is panicking (called from fpr_cpanic) */
uw fpr_current_id(void) {
  fpr_hart_t *h = fpr_hart();
  return h && h->current ? h->current->id : 900 + (h ? h->id : 99);
}

V fpr_process_result_get(void) { return fpr_process_result; }


/* ---- introspection: the monitor's window ----------------------------
 * Sys.actLive ()      -> live (non-DEAD) actor count
 * Sys.actInfo i       -> the i-th live actor (ledger order = newest
 *                        first) as [id, status, parent, code]:
 *                        status 0 ready / 1 blocked; parent = the
 *                        spawner's id; code = the entry closure's
 *                        function address, which is ATTRIBUTION: an
 *                        address inside a plugin sub-slot names the
 *                        app that owns the actor.  Out of range -> [].
 * The ledger is append-only over immortal acbs, so walking it is
 * always safe; counts are a snapshot, racing spawns tolerated. */
static V mklist4(uw a, uw b, uw c, uw d) {
  hdr_t *nil = (hdr_t *)fpr_alloc(8);
  nil->tid = T_LIST;
  nil->var = 0;
  V list = (V)nil;
  uw vals[4] = {d, c, b, a};
  for (int i = 0; i < 4; i++) {
    V *cell = (V *)fpr_alloc(24);
    ((hdr_t *)cell)->tid = T_LIST;
    ((hdr_t *)cell)->var = 1;
    FPR_FLD(cell, 0) = TAG((sw)vals[i]);
    FPR_FLD(cell, 1) = list;
    list = (V)cell;
  }
  return list;
}

/* Sys.stkStats () -> [spawns, stackPushes, stackMisses, chbCarves]:
 * the pool ledger, PULL-based -- reading a counter is the only safe
 * telemetry an allocation path gets (see the growlog lesson above) */
static V g_stkStats(V u) {
  (void)u;
  return mklist4(fpr_spawns, fpr_stk_pushes, fpr_stk_misses, fpr_chb_carves);
}
FPR_FN(fpr_g_Sys_x2estkStats, g_stkStats, 1);

static V g_actLive(V u) {
  (void)u;
  uw n = 0;
  for (acb_t *a = __atomic_load_n(&g_all, __ATOMIC_ACQUIRE); a; a = a->all_nx)
    if (__atomic_load_n(&a->var, __ATOMIC_ACQUIRE) != ST_DEAD) n++;
  return TAG((sw)n);
}

static V g_actInfo(V iv) {
  sw want = UNTAG(iv);
  for (acb_t *a = __atomic_load_n(&g_all, __ATOMIC_ACQUIRE); a; a = a->all_nx) {
    uint32_t st = __atomic_load_n(&a->var, __ATOMIC_ACQUIRE);
    if (st == ST_DEAD) continue;
    if (want-- == 0) {
      uw code = 0;
      if (a->entry && !ISINT(a->entry)) code = ((uw *)a->entry)[1];
      return mklist4(a->id, st == ST_BLOCKED ? 1 : 0, a->parent, code);
    }
  }
  hdr_t *nil = (hdr_t *)fpr_alloc(8);
  nil->tid = T_LIST;
  nil->var = 0;
  return (V)nil;
}
FPR_FN(fpr_g_Sys_x2eactLive, g_actLive, 1);

/* the actors of process `pid` that may still run its code: not DEAD, or
 * DEAD but still switched in on a hart (the loader's quiescence rule:
 * a process image's slot is reusable only when this is 0) */
uw fpr_pid_live(uw pid) {
  uw n = 0;
  for (acb_t *a = __atomic_load_n(&g_all, __ATOMIC_ACQUIRE); a; a = a->all_nx) {
    if (a->pid != pid) continue;
    if (__atomic_load_n(&a->var, __ATOMIC_ACQUIRE) != ST_DEAD ||
        __atomic_load_n(&a->running, __ATOMIC_ACQUIRE) != 0)
      n++;
  }
  return n;
}

/* Sys.nextId () -> a fresh Int, never repeated in this image: the
 * correlation id a request/reply caller stamps on a request so a reply
 * can be matched to it (std/actor.fpr call) */
static V g_nextId(V u) {
  (void)u;
  static uw next;
  return TAG((sw)__atomic_add_fetch(&next, 1, __ATOMIC_RELAXED));
}
FPR_FN(fpr_g_Sys_x2enextId, g_nextId, 1);
FPR_FN(fpr_g_Sys_x2eactInfo, g_actInfo, 1);

/* ---- the MEMORY ACTOR (fpr.h; docs/2026-08-25-MEMORY.md) -----------------------
 * One actor owns the buddy.  A request is an Int -- (bytes << 1) | 1
 * to take, ptr >> 1 to give (buddy pointers are 8-aligned, so the
 * low bit distinguishes) -- so the request path allocates nothing.
 * The answer to a take is a plain store into the requester's
 * mem_reply plus a wake: no mailbox on the reply path, so a full
 * mailbox can never lose an answer, and no receive on the requester's
 * side, so the borrows of the message it may be holding stay intact
 * (a_receive's drop_drain would release them).  Frees are one-way.
 *
 * The requester's channel key is its acb; contexts with no actor (the
 * hart loop's reaper, IRQ delivery, boot) free through one pinned key
 * per hart -- a hart loop only ever runs on its own hart, so each key
 * keeps the single-producer discipline of a dedicated channel -- and
 * take directly.  The memory actor itself, and any request that could
 * not be queued, go to the buddy directly as well; those direct calls
 * are the reason buddy_lock still exists. */
#define MEM_PENDING ((uw)-1)
#define MEM_CANCELLED ((uw)-2)
#define MEM_CAP 1024 /* its rings start here and grow (Dynamic) */
int fpr_mem_own;
uw fpr_mem_reqs, fpr_mem_waits, fpr_mem_direct, fpr_mem_frees, fpr_mem_denied, fpr_mem_inline;
static acb_t mem_hart_key[FPR_NHARTS]; /* var pinned READY: never "dead" */

void *fpr_mem_take_direct(uw bytes) {
  __atomic_add_fetch(&fpr_mem_direct, 1, __ATOMIC_RELAXED);
  return buddy_alloc(bytes);
}
/* The reply slot transfers ownership by CAS. A killed waiter leaves a
 * cancellation sentinel: a later grant goes home rather than becoming an
 * orphan. If the reply already arrived, the reaper returns it itself. */
static void mem_cancel(acb_t *a) {
  uw reply = __atomic_exchange_n(&a->mem_reply, MEM_CANCELLED, __ATOMIC_ACQ_REL);
  if (reply && reply != MEM_PENDING && reply != MEM_CANCELLED) buddy_free((void *)reply);
}
static int p_mem(acb_t *a, uw unused) {
  (void)unused;
  return __atomic_load_n(&a->mem_reply, __ATOMIC_ACQUIRE) != MEM_PENDING;
}
/* queue an Int request on the memory actor as `key`: 1 queued */
static int mem_post(uw key, V m) {
  chan_t *c = chan_for(mem_act, key, 1);
  if (!ring_push(mem_act, c, key, m)) return 0;
  __atomic_thread_fence(__ATOMIC_SEQ_CST); /* Dekker: publish before flag read */
  wake(mem_act);
  return 1;
}
void *fpr_mem_take(uw bytes) {
  fpr_hart_t *h = fpr_hart();
  acb_t *a = h ? h->current : 0;
  if (!mem_act || !a || a == mem_act) return fpr_mem_take_direct(bytes);
#ifdef FPR_ADMISSION_TEST
  extern int fpr_admission_test_queue(void);
  if (!fpr_admission_test_queue())
#endif
  { /* uncontended: served on the spot (buddy.c's essay); a miss with
     * the lock free is a real shortage, still queued behind the frees
     * ahead of it in case one of them makes room */
    int busy;
    void *p = buddy_alloc_try(bytes, &busy);
    if (p) { __atomic_add_fetch(&fpr_mem_inline, 1, __ATOMIC_RELAXED); return p; }
  }
  __atomic_store_n(&a->mem_reply, MEM_PENDING, __ATOMIC_RELEASE);
  if (!mem_post((uw)a, TAG((sw)((bytes << 1) | 1)))) {
    __atomic_store_n(&a->mem_reply, 0, __ATOMIC_RELEASE);
    return fpr_mem_take_direct(bytes);
  }
  __atomic_add_fetch(&fpr_mem_reqs, 1, __ATOMIC_RELAXED);
  while (!p_mem(a, 0)) {
    __atomic_add_fetch(&fpr_mem_waits, 1, __ATOMIC_RELAXED);
    block_unless(a, p_mem, 0);
  }
  return (void *)__atomic_exchange_n(&a->mem_reply, 0, __ATOMIC_ACQ_REL);
}
void fpr_mem_give(void *p) {
  if (!p) return;
  __atomic_add_fetch(&fpr_mem_frees, 1, __ATOMIC_RELAXED);
  fpr_hart_t *h = fpr_hart();
  acb_t *a = h ? h->current : 0;
  if (!mem_act || a == mem_act) { buddy_free(p); return; }
  if (buddy_free_try(p)) return; /* uncontended: done on the spot */
  uw key = a ? (uw)a : (uw)&mem_hart_key[h ? h->id : 0];
  if (!mem_post(key, TAG((sw)((uw)p >> 1)))) buddy_free(p); /* could not queue */
}
/* the body: the next request from any channel, with its sender */
static V mem_next(acb_t *a, uw *from) {
  for (;;) {
    for (int n = 0; n < MAXSND; n++) {
      chan_t *c = &a->ch[(a->scan + n) % MAXSND];
      if (__atomic_load_n(&c->sender, __ATOMIC_ACQUIRE) && ch_avail(c)) {
        a->scan = (a->scan + n + 1) % MAXSND;
        if (c->sender == SHARED_KEY) {
          ringv_t *rv = __atomic_load_n(&c->rv, __ATOMIC_ACQUIRE);
          *from = TAGAT(rv, c->rh);
        } else
          *from = c->sender;
        return take_at(a, c, c->rh);
      }
    }
    block_unless(a, p_any, 0);
  }
}
static V mem_body(V me) {
  acb_t *a = (acb_t *)me;
  for (;;) {
    uw from;
    V m = mem_next(a, &from);
    if (ISINT(m) == 0) continue; /* not a request: ignored */
    uw x = (uw)UNTAG(m);
    if (x & 1) {
      void *p = buddy_alloc(x >> 1);
      if (!p) fpr_mem_denied++;
      acb_t *r = (acb_t *)from;
#ifdef FPR_ADMISSION_TEST
      (void)fpr_admission_test_fail(7); /* cancellation after allocation, before reply */
#endif
      uw expected = MEM_PENDING;
      if (__atomic_compare_exchange_n(&r->mem_reply, &expected, (uw)p, 0,
                                      __ATOMIC_RELEASE, __ATOMIC_RELAXED)) {
#ifdef FPR_ADMISSION_TEST
        (void)fpr_admission_test_fail(8); /* reply arrived, waiter not yet woken */
#endif
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
        wake(r);
      } else if (p) buddy_free(p); /* cancelled before the reply */
    } else
      buddy_free((void *)(x << 1));
  }
  return (V)&fpr_unit; /* not reached: the owner never exits */
}
FPR_FN(mem_entry, mem_body, 1);
void fpr_mem_spawn(void) {
  if (!fpr_mem_own || fpr_plane_memory || mem_act) return;
  for (uw i = 0; i < FPR_NHARTS; i++) {
    mem_hart_key[i].tid = T_ACTOR;
    mem_hart_key[i].var = ST_READY;
  }
  /* pinned to hart 0 (the boot hart is always live), pid 0, Dynamic
   * rings: its mailbox is the whole runtime's allocation queue */
  mem_act = (acb_t *)spawn_on_pid_cap(0, (V)&mem_entry, 1, 0, MEM_CAP, 1);
  mem_act->prio = 1; /* ahead of the backlog: nobody's allocation waits
                      * on a reservoir draw (read at selection time; the
                      * spawn above only queued it on this hart) */
}

/* ---- the exported plane (fpr.h: fpr_plane_actors_t, fpr_plane_memory_t) --- */
static V sched_spawn(V f) { return spawn_on(fpr_hart()->id, f, 0); }
static V sched_spawn_at(V hv, V f) {
  if (ISINT(hv) == 0) fpr_cpanic("spawnOn: hart must be an Int");
  return spawn_on((uw)UNTAG(hv), f, 1);
}
/* a process's spawnCap / spawnCapOn: the same rounding and the same pin
 * rule as the plane's own, the pid inherited from the spawner */
static V sched_spawn_cap(V hv, uw pinned, V modev, V nv, V f) {
  if (!ISINT(modev)) fpr_cpanic("spawnCap: mode must be an Int");
  if (pinned && !ISINT(hv)) fpr_cpanic("spawnCapOn: hart must be an Int");
  uw hart = pinned ? (uw)UNTAG(hv) : fpr_hart()->id;
  return spawn_on_pid_cap(hart, f, pinned ? 1 : 0, (uw)-1, cap_of(nv), UNTAG(modev) != 0);
}
static V sched_spawn_pid(V f, uw pid) {
  return spawn_on_pid(fpr_hart()->id, f, 0, pid);
}
static V sched_receive(V me) { return a_receive(me); }
static V sched_receive_from(V me, V from) { return a_receive_from(me, from); }
static V sched_receive_res(V me) { return a_receive_res(me); }
static V sched_receive_now(V me) { return a_receive_now(me); }
static V sched_receive_from_res(V me, V from) { return a_receive_from_res(me, from); }
V fpr_receive_res_c(V me) { return a_receive_res(me); } /* process.c's syscall wait */
V fpr_receive_from_res_c(V me, V from) { return a_receive_from_res(me, from); }
static uw sched_arc_live(void) { return fpr_arc_live_count(); }
void fpr_plane_export(fpr_plane_actors_t *actors, fpr_plane_memory_t *memory) {
  actors->abi = FPR_PLANE_ACTORS_ABI;
  actors->send_as = fpr_send_as;
  actors->receive = sched_receive;
  actors->receive_now = sched_receive_now;
  actors->receive_from = sched_receive_from;
  actors->receive_from_res = sched_receive_from_res;
  actors->receive_res = sched_receive_res;
  actors->spawn = sched_spawn;
  actors->spawn_at = sched_spawn_at;
  actors->spawn_cap = sched_spawn_cap;
  actors->spawn_pid = sched_spawn_pid;
  actors->spawn_heap = a_spawn_heap;
  actors->fuel = fpr_fuel_exhausted;
  actors->sleep_us = fpr_actor_sleep_us;
  actors->cleanup_set = fpr_actor_cleanup_set;
  actors->cleanup_clear = fpr_actor_cleanup_clear;
  actors->fail = fpr_actor_fail;
  memory->abi = FPR_PLANE_MEMORY_ABI;
  memory->arc_incref = fpr_arc_incref;
  memory->arc_decref = fpr_arc_decref;
  memory->arc_live = sched_arc_live;
  memory->slab_new = fpr_slab_new;
  memory->slab_release = fpr_slab_release;
  memory->pool_reset = fpr_pool_reset_c;
  memory->stack_grow = stack_grow_at;
  memory->heap_lo = fpr_heap_lo;
  memory->heap_hi = fpr_heap_hi;
}

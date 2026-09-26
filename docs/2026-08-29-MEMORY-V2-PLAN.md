# MEMORY v2 — the migration plan

docs/2026-08-25-MEMORY.md states the v2 contract; this file maps every [pending]
marker to the mechanisms it replaces, file:line, in landing order.
The rule for the whole plan: each phase DELETES more mechanism than it
adds, and no phase changes what programs mean except where a verb
(`sendLinear`, `sendArc`) makes a cost explicit that was implicit.

Done on this branch — foundations, then phases 1 and 2:
* `buddy_realloc` — buddy.c, proven by qos/tests-host/buddy-check.sh
  (in-place grow via buddy-absorb, in-place shrink, copy fallback,
  coalescing intact after 20k randomized rounds).
* `fpr_pool_init` — fpr.h; all five pool creation sites route through
  it (this is the fix for the Sys.arena uninitialized-bigfree bug).
* Exponential backoff in `fpr_lock` — fpr.h (the transitional form of
  the no-hot-spin rule; deletion per site is phase 5).

## Phase 1 — one freelist discipline **[LANDED]**

Landed as `fpr_freelist_t` / `fpr_fl_take` / `fpr_fl_put` (fpr.h,
runtime.c) — first-fit over capacity-carrying nodes rather than the
planned fixed-size-only helper, because the grant pool's blocks vary
in size and first-fit covers the fixed-size users trivially. Its four
instances: the stack pool, the bucket-array recycler, the chblk carve
extras, and the grant pool. The chblk EPOCH limbo stays as its own
discipline on top (correctness, not recycling); the acb bump arena
got its own lock instead of borrowing the stack pool's. Verified:
the full qosp-reachable golden set byte-identical.

## Phase 2 — contiguous Vec on realloc **[LANDED]**

* runtime/vec.c: `col_t` is {cap, base} — ONE contiguous span, base
  at word offset 1 (the slot the old directory kept blk[0] in, so
  Codegen's colBlk0 pins unchanged). vl_slot/vl_grow/vl_cap/VL_DIR
  and every per-block walk deleted; the SIMD tier (VS_BLOCKS/VS_ZIP,
  blend, burst, gather) runs single spans.
* Growth is `fpr_realloc` (runtime.c): copy-based through the pool
  tiers, the freed predecessor recycling exactly. TWO DEVIATIONS
  from the plan, recorded: (a) columns still allocate through the
  pool, not buddy-direct — one allocation path is simpler, and the
  process tier has no buddy under it anyway; in-place growth arrives
  when bulk storage sits behind Memory.qa. (b) bigfree therefore
  STAYS: it is the pool's exact-fit recycler for ALL big payloads
  (strings included), and it is precisely what makes the realloc
  ladder cheap. Its deletion moves to the Memory.qa phase.
* Codegen.hs: specBlock reads base + done·W and hands the whole
  remainder as one chunk (the loop shape and all five emitters keep
  their structure; the next-block arm is now just the exit recheck);
  the filter write cursor lost its per-block refill; mvmap and the
  SoA fold dual load base-relative cursors. RVV strip-mining now
  runs whole-column. fvec2's asm greps (fadd.d, the VR_FLT guard)
  still hold.
* machine/unix/gfx.c: both mirrors ({cap, base}) and the GPU
  marshalling loops became straight copies; fpr_gpu_vec_axpb now
  takes the raw span. portable-gl builds; the DRM branch
  syntax-checks.
* Sol needed NO change: its vec store is Haskell-side (Val.hs), not
  a reader of this layout.
* Verified: the golden set byte-identical except two footprint
  diagnostics, both explained and accepted — bigfree.fpr's steady
  arena reads 5MB (doubling transiently holds old+new; still flat
  over 40 cycles, the actual invariant) and matvec's negative-control
  heap delta shifted (smaller). dtree stays bit-for-bit; all three
  Sol tiers agree; pathnotes/livereload (plugins, hot-swap, disk)
  green; buddy-check green.

## Phase 3 — the send triad (delete vec CoW) **[LANDED]**

* `send` = deep copy, NO exceptions: the vec CoW rc is deleted and
  fpr_dcopy gained a real T_VEC case — header, col_t's, and column
  spans all land in the message slab (kp_dup mirrors it for `keep`;
  vec_layout.h is the shared contract; boxed columns recurse their
  elements). Both CoW soundness holes ceased to exist, plus a third
  the deletion surfaced: a CoW-shared vector's storage died with the
  SENDER's pool regardless of rc.
* `sendLinear` moves — by a BETTER mechanism than the planned block
  reparenting: since a vector now lives INSIDE its message slab, a
  received root transfers as the same pointer (fpr_arc_movable_root:
  tracked + ownerless slab), no copy, no count change — the standing
  ARC count changes hands. Locals deep-copy and release (a Vector
  root is freed on the spot). The checker consumes the payload via
  an explicit builtinLinShapes override (a polymorphic type would
  derive LU); reuse-after-move is refused by name. Sol runs it as
  send (immutable values: move == send).
* tests/frames.fpr REWRITTEN onto the relay idiom — the old
  ping-pong (retain a vec out of a dropped message) became a
  copy-on-retain violation the moment vec copies were real; the new
  spelling has no drops in the loop and holds ARC-flat at arcLive=1.
  tests/sendlin.fpr is the qosp gate (200 zero-copy bounces + the
  compile-time refusal), wired into check-all.

## Phase 4 groundwork — sendArc on the v1 mechanism **[LANDED]**

* `sendArc` is live as the ONE explicit promotion path:
  fpr_arc_promote_share (count = HOLDERS; the sender's standing
  share is created at first promotion, each send adds the
  receiver's, every holder releases with `drop`; first promotion
  pins the slab so the shared object survives sender death by the
  existing orphan machinery). The pointer crosses uncopied; frozen
  by contract; a Vector is refused at compile time (a bare linear
  use is already a second use) AND at runtime (the generic-typed
  sneak path panics by name). tests/sendarc.fpr: one tuple, three
  holders, arcLive balanced; in check-all.
* Deep trees reclaim SHALLOWLY at count-zero (children are
  pool-scoped) — share flat records/tuples, or accept pool lifetime.
  The full ARC.qa (below) lifts this along with the table.

## Phase 4 — ARC.qa owns promotion (delete the ARC table + orphan slabs)

The sendArc CONTRACT above is final; what remains is replacing the
mechanism underneath it. Today: a 1024-entry open-addressed table
under arc_lock that PANICS when full, plus escaped-counts and
orphaned slabs so cross-actor references never dangle. v2:

* Promotion moves the object into ARC.qa's pool (deep-copy once at
  promotion — promotion is rare by definition);
  ARC.qa spawns a manager actor per object; INC/DEC are messages to
  that manager; the count is structurally atomic because the mailbox
  linearizes it. DEC-to-zero: dealloc + manager exits.
* Holders read through the raw pointer while their count is live
  (the object is frozen); no read ever messages anyone.
* Needs the missing primitive 2026-08-25-MEMORY.md already names: monitor-style
  death notification (subscribe once, get told when a registrant
  dies), so a holder's crash DECs its counts. General-purpose — any
  registration service wants it.
* Delete: arc_lock, the table, the tombstone machinery, slab
  `escaped`/orphaning, and the `total==0` poison tripwire — the
  interaction of three refcounts becomes the interaction of one
  count in one mailbox. Capacity is now ARC.qa's pool: exhaustion is
  a refused promotion (an Err to the sender), never a machine panic.
* mods/arcsvc.fpr keeps its stats/baseline/audit protocol on top —
  unchanged surface, real ownership underneath.

## Phase 5 — delete the locks (each behind its owner)

fpr_lock now backs off exponentially (done); the end-state deletes
each site by giving the structure one owner.  **Stage 1 of Memory.qa
LANDED** (docs/2026-08-25-MEMORY.md, the allocator contract): one memory actor
owns the buddy, every actor-context block is a request to it, the
qosp app owns its arena (ABI v12; the host's buddy, grow callback and
grow mutex are deleted), the grant pool / stack freelist / acb leak
retire on every image with a buddy, and message slabs pack.

| lock                      | site                    | owner in v2                         |
|---------------------------|-------------------------|-------------------------------------|
| buddy_lock                | runtime/buddy.c        | the memory actor serialises the     |
|                           |                         | CONTENDED case (LIVE); the lock is  |
|                           |                         | the uncontended inline path's guard |
|                           |                         | and the direct callers' (boot, the  |
|                           |                         | reaper, IRQ delivery)               |
| fpr_freelist_t mu ×2      | fpr.h (phase 1)         | bucket arrays and channel-block     |
| (bkts/chb)                |                         | extras remain; stacks and grants    |
|                           |                         | retired behind the memory actor     |
| acb_lock                  | runtime/actors.c       | the bump carve stays (acbs are      |
|                           |                         | permanent); its refill is a request |
|                           |                         | taken outside the lock              |
| chb_lock (epoch limbo)    | runtime/actors.c       | owner-hart epochs + messages        |
| arc_lock                  | runtime/runtime.c      | retires with phase 4 (the rehash    |
|                           |                         | block is taken outside it already)  |
| ledger/reap               | runtime/actors.c       | owner-hart only + messages          |
| grow_mu                   | qos/portable/main.c     | DELETED (v12: the app owns the      |
|                           |                         | arena)                              |
| store_mu                  | qos/portable/main.c     | the storage trampoline actor        |
| gfx statics cache         | machine/unix/gfx.c          | the render service actor (already   |
|                           |                         | single-caller in practice)          |

Rules that hold from today onward: an actor that must wait yields
(receive / safepoint), never spins; any remaining CAS loop backs off
exponentially (fpr_backoff); no spinlock is held across a memory
request (take first, lock, re-check); no new fpr_lock site lands
without a row in this table naming the owner that will delete it.

## Phase 6 — masked filter (branch-light conditionals)

After phase 2, `Vec.filter` stops compacting in place per element:

* filter writes a mask column (predicate evaluated branchlessly —
  cmov/SIMD lanes, no per-element taken/not-taken branch);
* scans (map/fold/zip) FUSE the mask — the fixed-function tier and
  the specialized loops both read it as a lane select;
* density is restored by explicit `Vec.compact` or automatically at
  `Sys.poolReset` — a frame-boundary event, one pass, branch-light.

This inverts vec.c's old comment (which chose eager compaction to
keep scans mask-free); the v2 judgment is that per-element branching
in filter poisons the wide path more than a fused mask does, and the
compaction pass at the loop boundary restores density where the old
argument wanted it. If a workload proves otherwise, `Vec.compact`
directly after filter IS the old behavior — the policy moved to the
program, which is where this codebase puts policy.

## Test strategy

* buddy-check.sh: in check-all as a host leg (done).
* Phases 2/3: the existing golden legs are the gate (dtree
  bit-for-bit, frames, arcaudit, vec legs, Sol parity legs) — output
  must be IDENTICAL; a phase that changes a golden line is wrong.
* Phase 4: arcaudit.fpr gains a leg where a holder dies without
  DECing and the death notification balances the count.
* Every deleted mechanism takes its dead declarations with it
  (fpr.h's duplicated buddy block included).

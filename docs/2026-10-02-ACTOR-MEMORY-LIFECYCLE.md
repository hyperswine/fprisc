# Actor memory admission and lifetime

Date: 2026-10-02. Kind: intended contract plus first implementation slice.
FP-RISC working changes based on `bca7278`. Related: [MEMORY](2026-08-25-MEMORY.md),
[LIVE-MEMORY](2026-10-02-LIVE-MEMORY.md), and QOS's memory-owner design.

## Intended lifecycle

Memory.qa grants coarse backing blocks. An actor's runtime subdivides and
recycles its own grant; allocating an individual value is a local operation.
Service traffic should follow admission, exceptional growth and reclamation.

1. **Declare.** Specify a memory policy separately from mailbox policy. Account
   for heap/live data, allocator metadata, stack, mailbox channels/rings and
   message storage. State which infrastructure costs belong to a shared runtime
   reserve. Fixed means no additional backing allocation during ordinary execution;
   growable means explicit bounded initial and maximum grants, not unlimited growth.
2. **Admit before publication.** The spawning runtime asks for backing chunks,
   constructs the actor using admitted resources and publishes it only after all
   required resources exist. Refusal returns `Err`, releases partial reservations
   and executes no child code. The child cannot request its own initial ACB:
   admission belongs to the spawner/runtime, using a separately accounted control
   reserve to bootstrap the request path.
3. **Run locally.** Carve slabs from the grant, bump and recycle locally. Local
   frees retain backing memory for reuse. Pool/frame resets preserve usable
   reservations. No hidden global buddy allocation is allowed by a fixed total
   budget, including scratch arenas, stack extension and message operations.
4. **Grow only by policy.** A growable actor requests coarse additional blocks
   when its local region cannot satisfy a request. A fixed actor exceeding its
   admitted bound fails with a defined actor-local reason. Compiler `live` bounds
   can support admission once converted to runtime footprint; they do not by
   themselves include headers, alignment, stack or communication costs.
5. **Transfer and share explicitly.** Escaped data remains owned/accounted for
   after its source actor exits. It either uses separately admitted transferable
   blocks or keeps the relevant source grant alive. Never return backing storage
   while a receiver, ARC holder or borrow window can still access it. A subregion
   needs its own release law if several slabs share one backing chunk.
6. **Exit, cancel or fail.** Stop execution, close external requests, drain
   borrows and return reclaimable backing blocks. Defer escaped blocks until their
   last holder and borrow end. Requests pending during cancellation must either
   complete into a live admission or return their reservation; no orphan grant.

The memory actor remains the owner of allocation policy and accounting. Fast
paths can execute its uncontended primitive without a mailbox trip; the invariant
is ownership/accounting, not requiring every request to visit one hart. Boot,
interrupt and reaper paths need an explicitly reserved non-parking mechanism.

## Implemented first slice: a fixed local heap

`AC.spawnWithHeap bytes entry` (primitive `spawnHeap`) returns
`Result Int String`. Existing `Static n` / `Dynamic n` continue to describe
mailbox capacity per sender; they are not memory budgets.

Admission obtains one buddy-backed slab before publishing the actor. `bytes`
is the exact cap on pool allocation footprint: block headers and alignment count.
The slab header is additional; buddy rounding can reserve more physical memory
than the logical cap. Allocation uses the existing local bump/free-list paths.
No slab growth is permitted. Overrun calls `fpr_actor_fail` with
`fixed heap: local grant exhausted`, ending the child while the machine continues.

A reset with no escaped data clears local lists and rewinds the retained slab.
It neither returns nor re-requests the grant. Reset with escaped data fail-stops
rather than reusing somebody else's storage. Normal exit uses the existing
orphan/ARC mechanism, retaining the whole grant until escaped data and borrows
are gone. Scratch arenas (`Sys.arena`, `Sys.loopWith`) are explicitly refused
because their separate pools would evade this first heap cap.

Heap denial and non-positive size return static `Err` values before publishing
a child; reporting refusal itself requires no allocation. The success envelope
is reserved before publication. This
is **not yet atomic admission of the whole actor**: stack, ACB, bucket arrays,
channels, messages, ARC-table growth and child spawning keep their existing
allocation paths. Infrastructure exhaustion retains the legacy spawn failure
behavior. Routed native process spawning through the shared scheduler table
returns an explicit unsupported `Err` for this API; default spawning continues
as before. There is no claim of a total actor bound or compiler-certified grant.
Sol does not implement this native runtime API.

## Verification

`tests/base/fixedheap.fpr`, wired into `tests/check_base.py`, checks:

- zero-size and oversized admission refusal;
- local list allocation and a retained-grant reset without additional slab growth;
- overrun and scratch-arena refusal end only the child;
- a later actor still runs successfully;
- promoted data survives owner exit and is reclaimed only after the receiver's
  drop and borrow boundary; a reset with escaped data fails safely; a borrow after the last ARC drop also
  prevents reset while another actor is still reading.

Fresh host execution passed on one and four harts. The existing full Base suite
also passed after the allocator changes. The same test passed as a native RV64 QEMU kernel on one hart. These observations do not establish total-budget admission.

The runtime pool layout changes in this slice. Dependent QOS runtime/process
images need a coordinated rebuild and ABI compatibility decision before a
compiler repin; the current QOS pin is intentionally not updated in this implementation
increment.

## Next implementation steps

- Composite admission descriptor and rollback of every partially admitted resource.
- Actor-owned region allocator supporting several local slabs within coarse chunks.
- Stack, mailbox and message allocations charged to their declared owners/reserves.
- Scratch subarenas and safe escaped-subregion handling within an admitted region.
- Bounded growable policy, cancellation of pending admission, and shared-plane ABI.
- Bind certified `live`/stack/communication bounds to admission, with counters that
  prove fixed actors make no global backing requests during their run.

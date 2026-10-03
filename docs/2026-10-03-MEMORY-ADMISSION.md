# Initial actor admission: rollback, cancellation and the shared plane

Date: 2026-10-03. Kind: implementation and verification record. Extends
[the intended actor lifecycle](2026-10-02-ACTOR-MEMORY-LIFECYCLE.md).

## What is implemented

`AC.spawnWithHeap bytes entry` still grants a fixed actor-local pool. Admission
now reserves all initial resources before registering or scheduling the child:

1. The fixed heap slab.
2. The initial guarded stack.
3. Allocator bucket metadata.
4. The default static mailbox channel block.
5. An independent deep copy of the entry and its captures.
6. The ACB.

A missing resource returns `Err "fixed heap: admission denied"`. Partial
reservations are returned to their allocator or reusable control reserve. An ACB
that was never published may be reused; a published ACB remains immortal so an
old actor handle can still report death safely. Failed attempts do not increment
the published spawn count or add a child to the actor ledger.

The response allocation belongs to the spawner and happens before reservations.
Ordinary refusal frees it; cancellation reclaims it with the spawner's pool.
Exhausting the spawner's own pool while constructing a success response retains
that pool's normal failure behavior. This is not a guarantee that every spawn
attempt can complete under an exhausted caller budget.

The entry copy has its own ownerless slab and a lifetime hold. That avoids
needing an ARC-table allocation to pin it after admission. Captures sent with
`sendArc` retain the slab until the actor's hold, escaped references and borrow
windows all end. Ordinary spawn retains its existing entry-copy policy.

## Cancellation and late replies

A reservation can park the spawner in the memory actor's queue. The admission
record is attached to the spawner's existing cleanup hook; its reaper rolls back
the record before releasing that actor's stack. An already occupied cleanup
slot causes refusal rather than replacing another pending operation's cleanup.

Memory replies now transfer ownership with CAS. Reaping a killed waiter marks
its reply slot cancelled. If the allocation is still pending, the memory actor
returns the late grant rather than publishing it into a dead actor. If the reply
already arrived but was not consumed, the reaper returns it. Successful receipt
clears the slot before ownership passes to the caller. This applies to queued
memory requests generally, not only fixed-heap spawning.

After all reservations succeed, the cleanup hook is cleared and the allocation-
free initializer registers and ships the child. Cancellation is actor-runtime
cancellation: an executing C operation reaches a safepoint before it can be
reaped. This adds no preemption inside arbitrary C operations.

## Shared QOS process execution

The scheduler table now routes `spawn_heap` to the plane's admission code. A
loaded process no longer receives the former "routed process spawn not supported"
refusal. Its child's pid is inherited from the process, its heap comes from the
plane's memory owner, and exhaustion kills the child through the plane's normal
fail-stop path. No private scheduler or buddy allocator is introduced.

`FPR_NATIVE_ABI = 1` records the current shared ACB/pool/vector layout and
scheduler-table contract. QOS process packaging includes this declaration and
checks it before placing an image. A coordinated QOS/compiler rebuild is required;
this constant must change with incompatible shared-runtime structure changes.
The declaration is a compatibility check for cooperative code, not a certificate
or a sandbox boundary.

## Fresh verification

- `python3 tests/check_admission.py`: one/four harts, 306 forced refusals per
  run across all six reservation prefixes, no publication/message from a refused
  child, stable backing usage after warming the control reserves, and a later
  successful child. Cancellation after each prefix is checked too.
- The same runner forces queued allocation and cancellation both before the
  reply is published and after publication but before waking the waiter. Backing
  memory returns within the stated control-reserve allowance; no child runs.
- Fault entry points compile only with `FPR_ADMISSION_TEST`. The runner compiles
  a production object and checks that no admission-test dependency remains.
- The full Base suite passed, including fixed-heap exhaustion, scratch refusal,
  escaped data and borrow/reset lifetime tests, typed/wide vectors, specialization,
  multi-hart RPC stress, external cleanup, and localhost networking. The final
  expanded cancellation injection was additionally run through the targeted runner.
- QOS `tools/admission-check.sh`: a real relocatable process on RV64 QEMU,
  one/two harts; refusal, local vector work/reset without new slab requests in
  that measured region, inherited pid, actor-local overrun, subsequent spawn,
  escaped entry capture, image reclamation and backing-memory return.

These are host and QEMU observations, not physical target timing or resource
certificates. The complete QOS repository sweep was not run for this increment.

## What the budget still excludes

`bytes` remains a cap on the local pool footprint, including block headers and
alignment. Buddy rounding can reserve more physical memory. Initial stack,
channels, entry storage and metadata are admitted separately; they are not
charged against `bytes`. Admission can make several coarse backing requests.
It is not yet one combined region or a declared total actor budget.

Stack growth, outgoing message slabs, ARC metadata growth and child spawning
retain their existing allocation policies. Scratch arenas remain refused for
fixed heaps because they would bypass the heap cap. Mailbox policy remains
separate: `Static n`/`Dynamic n` describes per-sender capacity, not actor memory.
Sol does not implement this native admission API. The memory policy owner is
still the C runtime memory actor, not a new FP-RISC `Memory.qa` service.

## Next slice

Define a composite memory policy with heap, stack, communication and explicit
shared control reserves. Carve actor-owned subregions from coarse grants; charge
stack segments and message/receiver storage to named owners. Add scratch arenas
inside the admitted region, retaining escaped subregions safely. Only then add
bounded initial/maximum growth and connect compiler-certified live/stack bounds
to actual aligned runtime footprint. Keep failed admission and cancellation
fully reversible as each new resource joins the transaction.

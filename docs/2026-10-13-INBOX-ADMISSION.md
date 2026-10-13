# Opt-in aggregate actor inbox admission

`Sys.spawnInbox hart messages bytes entry : Result Int String` creates an actor
with a global inbox limit. Use `hart = -1` for an unpinned actor, or a live hart
index to pin it. Both limits must be positive. Existing spawn APIs keep their
current behavior. Infrastructure is reserved transactionally before publication;
failed admission returns an error and releases partial reservations. Per-slot
charge storage is allocated only for opted-in actors and reused after teardown;
legacy channels do not carry inline charge arrays.

A send reserves one global slot and a conservative byte charge before copying,
across all producers and copies still in progress. It returns `mailbox full`
when the remaining budget is insufficient, `message too large` when a single
representation exceeds the byte limit, or `dead actor` after receiver death.
`sendSureResult` retries only temporary mailbox fullness and preserves permanent
refusals; `sendSure` retains its Bool interface.

The charge includes the copied graph, the message slab floor (64 KiB), allocation
rounding, and a shared/moved root's retained slab span. The bounded graph walk
refuses excessive nesting and exponential expansion before copying. Immediate
values and local immutable statics can cost zero bytes but still occupy a slot.
This is a queued representation budget; it does not cap allocator arenas,
application-held values, all transitive ARC retention or process creation.

Charges follow slots during selective receive. Dequeue, failed publication and
sender cancellation release reservations. Receiver teardown drains queued roots
and charges. An unpublished copied slab is held across a potentially parking ARC
promotion. Reaping a parked sender releases that hold and its reservation.
`sendArc` retains the sender's ownership on refusal; `sendLinear` consumes the
moved value on refusal, as before.

Actor plane ABI 3 appends transactional inbox spawning and ownership-preserving
ARC/linear send callbacks. Native ABI remains 6 and memory plane ABI remains 2.
Rebuild loaded native process images together with the exporting runtime. Their
`Sys.sleepUs` primitive now delegates to the existing plane sleep callback rather
than calling the process image's weak no-op host fallback.

`python3 tests/check_inbox.py` exercises aggregate limits across twelve senders,
shared-ring selective removals, refusal/reuse, exponentially shared graphs,
ARC identity/ownership, linear moves, deterministic sender/receiver kill windows,
and all transactional admission rollback phases on one and four workers. Fault
hooks are absent from the production object. QOS's `tools/native-inbox-check.py`
checks actual loaded-process ownership, sleep delegation and image reclamation
under RV64 with virtio v1/v2 and one/two harts.

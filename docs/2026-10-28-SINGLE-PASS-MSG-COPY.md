# Single-pass message copy

Date: 2026-10-28. Runtime only; no codegen revision change. Follows the
profile in [allocation measurement](2026-10-27-ALLOCATION-MEASUREMENT.md):
in pingpong, `dc_size_in` is 8% of samples and `dc_dup` 6% — two full walks
of the message graph per send, plus the slab arithmetic between them.

## Change

Every send used to walk the message twice: `dc_size` to size the slab, then
`dc_dup` to copy. The copy now runs once against the packing slab with its
end as a hard limit:

- `dctx_t` gains `end`/`overflow` (both zero for every pre-existing caller,
  so state copies, entry copies and `Sys.arena` transfers are unchanged).
- `dc_cell`/`dc_bump` refuse a cell that would cross `end`: nothing is
  written past it, the flag is set, and `dc_dup` unwinds. The partial copy
  sits above the slab's unpublished bump pointer and is overwritten by the
  next copy; the bump pointer commits only on success.
- `msg_copy_held_in` copies straight into the sender's packing slab; on
  overflow it ends the sender's hold and retries into a fresh floor slab,
  and only a message bigger than a floor slab takes the old exact path
  (`dc_size`, then a right-sized slab).
- The per-message byte count for the cost counters and the packing rule is
  the committed bump distance — the same number `dc_size` computed.

Ints, statics and bare actor handles keep their old no-slab early exits
(the first draft dropped them and paid a 64 KiB slab alloc/free per
no-copy message with an empty slot: pingpong ran 7-8x slower until the
exits were restored — a message that copies nothing must never touch a
slab).

## Measurement

`bench/2026-10-28-single-pass-msg-copy.json`: paired rounds, outputs pinned
against the `.expected` files. pingpong 1.20x fastest / 1.16x median in the
quiet round, 1.05x in a later round as the machine's load average climbed
from 3 to 6.5; direction consistent, size load-dependent — as expected for
removing one of two ~14%-of-samples walks while the scheduler
(`block_unless`/`hart_loop`/`deq`, ~32%) still dominates. xpingpong (4
harts) is unchanged: cross-hart cost is the wake/park path, not the copy.

Every send in every program takes this path — std/mvu, std/task and the
services included — so the win is not pingpong-specific.

## Verification

All 149 `check_base` jobs pass, including the admission hold protocol,
autodrop3's exact-zero ARC assertion on one and four harts, deadmail,
swarmkeeper's vector moves across boundaries, and the descriptor checks
through the deep copier.

## Follow-up (not built)

The remaining copy cost is the region allocation of the message value plus
the single walk. Generated code could build small constructor messages
directly in the packing slab (the slab is per-sender and the send is the
value's last use in the common case), removing both; that is a
compiler/runtime ABI change and needs the escape story for partial sends,
so it stays out of this step.

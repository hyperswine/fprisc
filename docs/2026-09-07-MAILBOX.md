# Mailboxes: capacity is a choice, a full ring is an answer

Every actor's mailbox is a set of per-sender rings (docs/SCHEDULER.txt).
Two things about those rings used to be fixed for the proof of concept
and are now part of the contract.

## Capacity: Static n or Dynamic n

A mailbox's capacity is chosen at spawn (std/actor.fpr):

    AC = use "../std/actor".
    w  = spawn worker;                             # Static 64, the default
    fs = AC.spawnWith (AC.Dynamic 64) (QL.actor dev);
    c  = AC.spawnWithOn hart (AC.Dynamic 64) (conn ...);

`Static n` rings hold n messages per sender channel and never grow: a
bound you can reason about, for a driver's queue or a WCET argument.
`Dynamic n` rings start at n and double from the buddy when full, so a
burst costs memory, never messages; the old ring stays reachable until
the channel block is reused, and the reuse path frees the chain.  n
rounds up to a power of two between 8 and a million.  The rule of
thumb: services -- anything many actors send to -- spawn Dynamic; use
Static only where you are sure the queue cannot need to grow and want
the bound.  The runtime's own hubs (actor 0 -- its shared ring included, which
the first cut had left Static: a fan-in of more than seven senders
lands there --, MVU's render worker, the storage and loader services,
FPRLive's acceptor and connection actors, and the memory actor whose
mailbox is the whole runtime's allocation queue) are Dynamic.

Under the hood a channel carries a pointer to the ring in force (its
capacity, slots and, for the shared ring, sender tags, in one block).
The producer publishes a grown ring before the tail index that lands
in it and a reader loads the tail before the ring, so a seen tail is
always covered.  Growth and the selective receive's slot shifting
exclude each other under the actor's lock; the plain head pop stays
lock-free, as before.  On the shared plane a loaded process keeps the
plane's default for now (the policy is not routed through the table).

## send answers: Result Unit String

    send who msg          -> Ok Unit | Err "mailbox full" | Err "dead actor"

Ok means queued.  Err "mailbox full" means a Static ring had no room,
or a Dynamic one could not grow (out of memory, or the ceiling).  Err
"dead actor" means the target has exited.  The runtime never waits for
space any more: the old backpressure yielded the sender's hart and
retried, which hid every burst that outran its consumer and could
deadlock two actors waiting on each other's full rings.  sendArc and
sendLinear answer the same way (sendLinear's payload is consumed either
way: the value left the sender).

The sender decides what a refusal means.  std/actor.fpr carries the
common policies -- `sendOrDie` (a refusal is fatal: the old behaviour,
explicitly), `sendRetry me who msg n` (up to n tries with a yield
between), `sent r` -- and most code never calls send directly: MVU,
the services and the drivers wrap it and choose.  Kernel senders (the
syscall trampoline, a process's reply) retry briefly and then stop the
machine loudly; interrupt and timer notifications are counted when
refused (`fpr_send_full`) and never block.

## The ARC table grows

Shared values (anything sent) are counted in the ARC table.  It was a
fixed 1024-slot array that panicked when full; it now starts there and
rehashes into a buddy block of twice the size whenever live plus
tombstone slots pass 70%, which also compacts the tombstones.  Growth
happens under the ARC lock on the insert path, before the probe.  The
high-water mark (`fpr_arc_hwm`) and the growth count are kept.  An
actor handle is by value here: an acb is immortal and has no
allocation preheader, so a bare handle sent as a message is shared raw
rather than counted (it used to read the word before the acb).

## Verified

tests/mailbox.fpr (a check-all leg): a Static 8 ring refuses 12 of a
burst of 20 and says so, and the 8 it kept drain in order; a Dynamic 8
ring keeps all 20 in order across two doublings; three thousand shared
tuples in flight grow the ARC table past its old ceiling and drain in
order; a dead actor answers Err.  The FPRLive, POS v1 and Terra II
harnesses run unchanged on top.

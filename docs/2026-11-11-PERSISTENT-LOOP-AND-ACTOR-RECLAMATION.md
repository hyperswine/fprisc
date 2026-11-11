# Reclaiming persistent loop state and dead actor execution storage

Implementation and hosted measurements, 11 November 2026, working tree based
on 53a1dbd7. This implements the region copy-out experiment from the
[performance priorities](2026-11-09-PERFORMANCE-PRIORITIES.md) and part of
the live/dead split from the [actor death measurements](2026-11-11-ACTOR-DEATH-COSTS.md).

### Persistent loops

Build with `FPR_PERSISTENT_LOOP=plain fpr build tests/bench/reclamation/fixed_state.fpr -o fixed-state`.
Run `./fixed-state plain 2048`. The value names one compiler function.
The native planner allows variable-size copyable state on that function's
pure tail-loop boundary. The usual checks on effects, liveness and types
still apply. An eligible loop opens a region on allocation pressure, copies
its live arguments out at subsequent slab boundaries and releases the
scratch arena. Existing references into the caller's pool survive.
The selection participates in both cache keys. Unset the variable for the
default policy. QOS process images and Builtin bypass the experiment. Set
`FPR_NO_PERSISTENT_COPY_OUT=1` to override the selection while retaining
ordinary loop regions. Placement notes identify the selected mechanism.
This implements the fallback experiment in the [memory reclamation intent](2026-11-11-MEMORY-RECLAMATION-INTENT.md).

Hosted arm64 peak RSS and median elapsed time, three runs after warmup:

| Workload | Default | With copy-out |
|---|---:|---:|
| 2,048 integers mapped 2,048 times | 131.0 MiB / 24 ms | 3.4 MiB / 80 ms |
| 128-leaf tree, 50,000 path-copy updates | 15.1 MiB / 9 ms | 3.3 MiB / 9 ms |

The regression retains a list tail and a previous tree root, and separately
runs ordered inserts into the tree used by std/map with its comparator kept
outside the changing state. Its checks include the resulting values,
runtime state-copy counters and toggling the option in a shared build cache.
Run `python3 tests/check_persistent_reclamation.py`.

Copy work depends on the size and sharing of the live graph. A measured RSS
plateau alone cannot supply a WCET or live-byte certificate. The native compiler now recognizes fresh list builders, including the
imported builder behind `List.range`. When the caller gives up its last
reference to a proven fresh spine, a private consuming worker can carry
the cells around a recursive backedge and refill them in traversal order.
The public entry continues to borrow its argument. A retained tail takes
the borrowing path and can use the nominated region fallback.

On the hosted fixed-state fixture, mapping 2,048 integers 64 times with
`FPR_PERSISTENT_LOOP=plain` took 2,052 allocation requests and zero
state copies. The checksum was 2,227,200. Compare reuse on and off with
`python3 tests/check_consuming_reuse.py`. These are allocator counters;
the timing and RSS table above predates the consuming worker.

In-place AVL updates still need per-path ownership evidence. Use the
tree/map copy-out fixtures to study shared paths. Copy-out selection
remains explicit while its cost on growing states is under analysis.

### Actor storage

The saved registers, pending call-region storage and deferred slab pointers
now live alongside the channel rings. They are available throughout the
running actor's lifetime and exclusive cleanup. The existing channel grace
period governs reuse. The actor handle, death reason and watcher bookkeeping
remain permanent. On hosted arm64 without cost probes the permanent structure
shrinks from 1,408 to 800 bytes. This changes the distribution of storage
between permanent and recycled blocks. Peak memory with many simultaneously
live actors also depends on channel-block carving and alignment.

The native and actor-plane ABI versions changed. Rebuild paired runtime and
module artifacts together. Host teardown, epoch reuse, module loading and
context-switch checks cover this change. QOS deployment and physical-board
heap headroom require separate qualification.

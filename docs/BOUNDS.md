# Bounds: what is fixed, why, and what happens at the edge

A register of the fixed limits in the runtime and compiler, audited 2026-09-19.
QOS keeps the companion register for the host, loader and memory layout in
`../qos/docs/BOUNDS.md`. The plan that removes these limits at the root -- moving
policy out of C -- is `C-REDUCTION.md`.

## The rule

A limit is legitimate when it comes from the machine (word size, an ISA
immediate, a device's register map, physical RAM), from a protocol (page,
sector, MTU), or from the programmer (`Static n`, a WCET bound they chose).
Anything else is a proof-of-concept decision and should grow on demand, so that
the only bound left is memory -- and running out of memory is the allocator's
named panic.

Whatever the limit, reaching it must never be **silent**. In order of harm:

1. a wrong answer or lost data with no error (fix first);
2. a crash with no diagnostic;
3. a named panic or a refused request (arbitrary, but honest);
4. a graceful fallback (a performance cliff, not a failure).

## Fixed on 2026-09-19

| Limit | Was | Now |
|---|---|---|
| `VEQ_MAX_DEPTH 64` (`hal/core/runtime.c`) | `==` recursed per field and answered **True** at depth 64 as a cycle guard. Two lists differing only past element 64 compared equal; measured: False at length 64, True at 65, 101, 1001. | No cap. `veq` is a worklist: fields are pushed last-first so they pop in order, which holds a list of any length at two pending pairs; a structure nested deeply through a non-final field moves the worklist from the C stack (`VEQ_INLINE 32` pairs) to an `fpr_alloc` block that doubles. Covered by `tests/eq.fpr` (65 and 100,000 elements, a 100,000-deep left nest) on posix, rv64 bare metal and QOS Portable; the new cases fail on the old runtime. |
| `FPR_RBUF_SZ 4096` for `print` of a String | `print s` panicked "render buffer full" for any String past 4095 bytes, though `str` already returned a String unchanged. Found when a 6.9 KB capability blob could not be printed. | A String is written straight to the console, never through the buffer: any length prints. Checked with 20,000 bytes on rv64 bare metal. The buffer still bounds the rendering of a NON-String value (below). |

## Open: a crash with no diagnostic

- **Actor stacks: `FPR_STACK_SZ` 256 KiB, no overflow check** (`hal/core/actors.c`).
  Building a 20,000-element list by ordinary (non-tail) recursion dies with
  SIGBUS on posix; 5,000 is fine. On bare metal the same overflow would write
  below the stack instead of faulting. `QOSSTACK` / `QOSSLAB` being per-BUILD
  knobs (one app ships with `QOSSTACK=65536` "for four times the sessions") is
  the same decision showing through. Directions, cheapest first: a guard page
  (hosted) or PMP region (bare metal) so overflow is a named panic; a per-spawn
  stack size in the manner of `spawnCap`; growable or segmented stacks.
  `tests/eq.fpr` builds its deep values with accumulators for this reason.

## Open: named panics and refusals that could grow

| Limit | At the edge | Direction |
|---|---|---|
| `FPR_RBUF_SZ 4096`, per-hart render buffer | rendering a non-String value (a long list, a big record) past 4095 bytes panics "render buffer full"; Strings no longer pass through it | render into a growable buffer, or straight to the console for `print` |
| `SSTR_CAP 128`, one global `SString` width | `SStr.push` panics | the indexed `SString n` that `sstr.c` already names |
| `RING_MAX 1<<20` messages per `Dynamic` ring | stops doubling | memory should be the bound, as the `MAXSND` comment already says of hubs |
| `IRQ_MAX 64` | `Sys.irqBind` panics | the PLIC's own source count, from the device tree |
| `NPINS 32`, `PIN_TRACE_CAP 4096` (`hal/virt/hal.c`) | a pin past 31 panics by name; the pin trace **stops recording** at 4096 entries without saying so | size from the board description; make the trace a ring or report the truncation |
| `NETCONN 4`, `RXRING 16384`, virtqueue `QSZ 8` (`hal/virt/net.c`, `blk.c`) | small fixed TCP table | allocate connections from the heap |
| `FPR_NHARTS` (compile time, static per-hart arrays) | fixed at build | discover at boot (device tree / `sysconf`) |
| `MOD_MAXATTACH 8` (`hal/core/mod.c`) | `fpr_mod_attach` returns -1 | a growing table; tied to the plugin slot count in QOS |
| `FPR_HEAP_MB 256` (`hal/posix/heap.S`), `LENGTH = 128M` and the fixed `_heap_end` in `hal/virt/link.ld` and `hal/builtin/link.ld` | "heap exhausted" | see the memory-layout section of the QOS register: reserve address space and commit on demand when hosted; read RAM size from the device tree on bare metal |
| Builtin stacks in `hal/builtin/link.ld` (64K main, 4K trap, 64K irq) | overflow unchecked | at least `--defsym` knobs; a board decision, but not one the linker script should hide |

## A graceful fallback

- `VMAXCOLS 8`: a record with more than 8 fields is stored boxed rather than as
  columns. Correct, slower. The `kinds` bitmask could be a full word.

## Legitimate, left alone

- Page and sector sizes, the Ethernet frame size, virtio and UART register maps.
- `FPR_ARGSPILL 56` (native arity 64): bounded by the rv64 12-bit tp-relative
  immediate (~250 cells), and not a user-visible ceiling anyway -- see below.
- `BUDDY_MAX_ORDER 24`: a 1 TiB block at the 64 KiB minimum.
- `Static n` rings: a bound the programmer chose.
- Scheduler tuning, not capacity: `FUEL_QUANTUM`, `FPR_TAU`, `RQ_CAP`, `DONATE_HI`.
- `XCAP`, `SCAP`: wake and steal rings that wait or fall back when full.
- Telemetry rings that overwrite their oldest entry by design: `LOG_N`, `GROWLOG_N`.
- `DP_N 16`: outstanding deferred slab windows per actor; a 17th retires the
  oldest early, which is correct and only costs the deferral.
- `FPR_NBUCKETS 512`: the size-class ceiling; larger blocks take the bigfree path.

## The patterns already in the tree

These are what "done" looks like for the open items:

- **Arity.** 64 is the native fast path; `aritySpill` rewrites anything wider.
- **Mailbox rings.** `Dynamic n` doubles from the buddy when full.
- **Channel slots.** `MAXSND 8` is seven dedicated rings plus one shared
  overflow ring, so a hub is "bounded by memory, not by this constant".
- **Starting sizes that grow.** `ARC_CAP0`, `MEM_CAP`, `VL_B0`, and now `VEQ_INLINE`.
- **One counted gateway for growth** (`fpr_grow_counted`), so the ledger is whole.

## Not audited

The Sol VM (`compiler/Sol/`), the compiler's own internal limits beyond arity,
and the FP-RISC-level libraries in `std/`.

## Found along the way (not bounds)

- FIXED: `print` wrote CRLF on every system; the carriage return is `hal_putc`'s
  to add now, in the HALs that front a raw serial line. See `C-REDUCTION.md`.
- FIXED: `fpr run` / `fpr build` printed nothing when compilation was refused (the
  compiler's stdout, where type and safety errors go, was discarded).

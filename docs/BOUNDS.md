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
| `VEQ_MAX_DEPTH 64` (`runtime/runtime.c`) | `==` recursed per field and answered **True** at depth 64 as a cycle guard. Two lists differing only past element 64 compared equal; measured: False at length 64, True at 65, 101, 1001. | No cap. `veq` is a worklist: fields are pushed last-first so they pop in order, which holds a list of any length at two pending pairs; a structure nested deeply through a non-final field moves the worklist from the C stack (`VEQ_INLINE 32` pairs) to an `fpr_alloc` block that doubles. Covered by `tests/eq.fpr` (65 and 100,000 elements, a 100,000-deep left nest) on posix, rv64 bare metal and QOS Portable; the new cases fail on the old runtime. |
| `FPR_RBUF_SZ 4096` for `print` of a String | `print s` panicked "render buffer full" for any String past 4095 bytes, though `str` already returned a String unchanged. Found when a 6.9 KB capability blob could not be printed. | A String is written straight to the console, never through the buffer: any length prints. Checked with 20,000 bytes on rv64 bare metal. The buffer still bounds the rendering of a NON-String value (below). |

## Fixed on 2026-09-19, continued: the actor stack

An actor that ran off its stack used to say nothing: SIGBUS on a hosted system,
whatever lay below overwritten on bare metal. Two faults fed each other.

- **Half of every stack block was unused.** A 256 KiB request is a 512 KiB buddy
  block (the size plus its 8-byte header rounds up to a power of two), and the
  stack used the low half. An overflow ran down into the PREVIOUS block's unused
  upper half -- harmless by accident whenever the neighbour was also a stack.
  `tests/dtree.fpr` needs between 368 and 496 KiB: it ran past its 256 KiB
  stack on every run and passed its bit-for-bit comparison with GHC anyway.
  A stack is as big as the block it was given now (`acb_t.stack_sz`): the same
  memory, twice the stack, and dtree passes because it fits.
- **No guard.** `actors.c` asks the HAL at the two places a stack changes hands
  (`hal_stack_guard` / `hal_stack_unguard`, weak no-ops by default) and offers
  `fpr_current_stack()` to a fault handler. `machine/posix` makes the lowest page
  inaccessible and catches the fault on an alternate signal stack, per hart
  thread: `*** FPRISC PANIC [actor 2]: stack overflow -- the actor ran off its
  511 KiB stack`, exit 1. QOS Portable apps reach the same code through three
  new HAL-table entries (the host IS a posix FP-RISC program, so it is one
  implementation); the app registers `fpr_current_stack` so the host's handler
  names the right actor, on any hart. `tests/base/overflow.fpr`, `check_base.py`.
  Cost: two `mprotect` calls per actor lifetime, about 0.9 us (2.6 vs 1.7 us per
  spawn-reply-die over 50,000 actors).

Both open ends of this closed on 2026-09-20, below: a stack grows, and the check
that grows it is the guard bare metal never had.

Found on the way: a received message that is never `drop`ped pins its whole
slab; 2,000 sequential spawn-reply-die rounds without the `drop` exhaust a
256 MiB heap ("send: no block for the message slab").

## Fixed on 2026-09-20: the heap, the stack, arity

**The heap is a reservation of address space, not a size.** The posix heap was
`FPR_HEAP_MB` (256) of `.bss`, and the runtime read its span from linker
symbols. The machine layer answers `hal_heap_span` at run time now: a board gives
its RAM; posix reserves the largest span the system will allow, from 1 TiB (the
buddy's largest block) down, `MAP_NORESERVE`, so the OS commits a page when it is
first touched. A freed block of 1 MiB or more gives its pages back
(`hal_heap_release`). What bounds a program is memory. `FPR_HEAP_MB` in the
ENVIRONMENT caps a run (a test of exhaustion, strict overcommit).
`tests/base/bigheap.fpr`: 577 MiB live where 256 was the ceiling; capped at 64,
the named panic. Nothing moves: a heap full of raw pointers cannot be
reallocated, and with address space to reserve it never needs to be. The honest
cost: a leak no longer stops at 256 MiB, it stops at the machine.

**An actor's stack grows.** Every function entry the compiler cannot prove
shallow checks that sp still has the runtime's headroom in the segment it is in
(`sp - stk_lo < stk_span`, two words in the hart block after the spill cells,
sharing the fuel tick's `tp` load). When it has not, `fpr_stack_grow` links in a
segment twice the size of the last -- the mailbox ring's `Dynamic n` doubling --
and the function continues there. Frames are addressed through `s0` and the
epilogue restores sp FROM `s0`, so the function returns into the old segment by
itself: no trampoline, no per-architecture assembly, and nothing moves (a live
stack cannot: C frames and saved frame pointers hold addresses into it). Dead
segments are popped at the next failed check, one kept warm; `reap` frees the
rest. A loaded process's actors belong to the plane, so its scheduler table
grows them. A small frame that calls no FP-RISC function skips the check.
Measured: `fib 40` (331 million calls) 1.19 s before and after; a million plain
frames run on posix and under qosp, 200,000 on a 128 MiB board, where about
5,000 used to overflow. The check IS the guard on bare metal, which never had
one. `tests/base/overflow.fpr`, `tests/deep.fpr`.

**Arity and tuple width have no ceiling.** Tuples stopped at 8 (`Tup2..Tup8`), so
the wide-arity rewrite -- 63 parameters plus one spilled tuple -- stopped at 71.
A tuple wider than 8 is typeid `T_TUPN + n` now, which `render` and the Vec
columns read the arity back out of, and the spilled tuple is as wide as it needs
to be. A C export takes up to 64 parameters (8 from C's registers, the rest from
C's stack into the hart's spill cells); it was 8. `tests/base/wide.fpr` (100
parameters, a 20-tuple), `tests/builtin_export.fpr` `wide12`.

Also: `MOD_MAXATTACH 8` is a table that doubles, and `fpr build`'s runtime object
cache now treats an object as stale when any HEADER is newer (it compared each
object with its own `.c` only, so a changed struct in `fpr.h` linked new objects
against old ones: a crash with no message).

**A pool's slabs start small and double** (added with `docs/LIVE.md`). Every actor
that allocated anything took a whole `FPR_SLAB_SZ` (256 KiB) at once, so a thousand
small session actors cost 508 MiB of arena before doing any work. The first slab
is one buddy block now and each next twice the last, to `FPR_SLAB_SZ`: 196 MiB.
An actor's FIRST STACK is one 128 KiB block (it was a 512 KiB block), now that
stacks grow.

## Deferred: written down, to be addressed another time

In rough order of worth. None of these is silent.

1. **The render buffer** (`FPR_RBUF_SZ 4096`): `str`/`print` of a non-String value
   past 4095 bytes panics. Render into a growable buffer.
2. **`RING_MAX 1<<20`**: a `Dynamic` mailbox ring stops doubling at a million
   messages. Memory should be the bound.
3. **`FPR_NHARTS`**: compile-time, with static per-hart arrays. Discover at boot.
   Partly done (2026-09-22): the cap `fpr build` compiles in is now the build
   machine's core count (`getconf _NPROCESSORS_ONLN`; it was a flat 2, so a
   server on a ten-core machine ran on two threads), and a program starts as
   many harts as the RUNNING machine has cores, up to that cap
   (`machine/posix/main.c`). Still static: a binary built on a small machine
   and run on a big one uses the small one's count unless built with `--harts`.
4. **RAM size on a board**: from the device tree, not `link.ld` (one place now:
   `hal_heap_span` in `machine/virt/hal.c`).
5. **The stack's C headroom** (`FPR_STACK_HEADROOM`, 64 KiB): the runtime's own C
   runs unchecked below the entry check. A single FP-RISC frame larger than the
   headroom, or C recursion deeper than it (a generic release of a very long
   chain), reaches the guard page instead: a named panic on posix and QOS
   Portable, unchecked on bare metal. Iterative release, and a frame-size-aware
   check for the rare giant frame, close it.
6. **Wide functions**: a clause GUARD may not mention a parameter past the 63rd
   (reported by name at compile time), and a function of more than 64 parameters
   cannot be partially applied. A C export stops at 64 parameters (pass a Layout
   pointer) and at 8 under `--float-abi=hard`.
7. **Builtin-profile stacks** in `machine/builtin/link.ld` (64K main, 4K trap, 64K
   irq): no runtime there, so no entry check; at least `--defsym` knobs.
8. **`VMAXCOLS 8`**: a graceful fallback (boxed storage), below.
9. **`fpr build --cc` cross-compiles to another LIBC, not another ARCH.** Three
   decisions in `Build.hs` read the BUILD machine rather than the target: the
   context switch it links (`ctx_a64.S` vs `ctx_x64.S`), `-ffixed-x28`, and the
   Linux-only `-no-pie`. So aarch64-Linux -> aarch64-Linux is sound, and that is
   what `qos/tools/buildroot` does; x86_64 -> aarch64 would build the wrong
   thing. The fix is a `--target` that names the arch, with `--cc` only naming
   the compiler. (The runtime object cache IS now keyed by `--cc`, so a warm
   host build no longer hands its own objects to another toolchain's linker.)

## Open: named panics and refusals that could grow

| Limit | At the edge | Direction |
|---|---|---|
| `FPR_RBUF_SZ 4096`, per-hart render buffer | rendering a non-String value (a long list, a big record) past 4095 bytes panics "render buffer full"; Strings no longer pass through it | render into a growable buffer, or straight to the console for `print` |
| `RING_MAX 1<<20` messages per `Dynamic` ring | stops doubling | memory should be the bound, as the `MAXSND` comment already says of hubs |
| `FPR_NHARTS` (compile time, static per-hart arrays) | the build machine's cores (was 2); the run machine's cores up to that | discover at boot (device tree / `sysconf`) |
| `LENGTH = 128M` and the fixed `_heap_end` in `machine/virt/link.ld`, `machine/builtin/link.ld` | "heap exhausted" | RAM is the bound on a board, but its SIZE belongs to the device tree the firmware hands over (`hal_heap_span` is the one place to read it), not to the linker script |
| Builtin stacks in `machine/builtin/link.ld` (64K main, 4K trap, 64K irq) | overflow unchecked | at least `--defsym` knobs; a board decision, but not one the linker script should hide |

## machine/esp-idf (registered 2026-09-23)

The ESP-IDF machine layer's own limits; why the layer looks as it does is
docs/ESP-IDF.md. Silent ones first, by the harm order above.

| Limit | At the edge | Direction |
|---|---|---|
| Wi-Fi AP password shorter than 8 bytes (`wifi.c do_ap`) | **silent, security**: the access point comes up OPEN instead of refusing | refuse a 1-7 byte password; an open AP only for an empty one, by name |
| Wi-Fi scan capped at 40 records (`wifi.c do_scan`) | **silent**: networks past the 40th are dropped | take `esp_wifi_scan_get_ap_num`'s count as it is |
| SSID past 32 bytes, AP password past 64, BLE name past 26 (`text_of`, `ble.c`) | **silent truncation** | the limits are the protocols' (802.11 SSID 32, WPA2 passphrase 63, a legacy advertisement's 31 bytes), so they stay; reaching them should be a refusal |
| SSIDs are not sanitized for the tab-separated rows | **silent**: a tab or newline in a scanned SSID shifts the row's fields | escape, as `ble.c` does for names, or return typed rows (ESP-IDF.md, decision 8) |
| `JOB_SLOTS 64` jobs in flight (`wifi.c`) | named panic "every job slot is in use" | grow the slot table; the interrupt range 900-963 grows with it |
| job queue of 16 (`wifi.c jobs_start`) | a refusal: the result is the row "error, the job queue is full" | a queue that grows, or a broker per radio |
| `SEEN_MAX 96` devices per BLE scan (`ble.c`) | reported: a final row "more, N not kept" | grow the table |
| AP `max_connection 4`, channel 6 (`wifi.c`) | fixed, not exposed | parameters of `wifiAp`, checked against what the C6 accepts |
| `FPR_ESP_KEEP_KB 192`, and 1/16 of PSRAM, left to IDF (`hal.c`) | fixed at boot; the runtime's heap never grows or shrinks | a heap that grows through `heap_caps_malloc` on demand |
| `ESP_IRQ_MAX 1024` (`hal.c`) | never reached: `Sys.irqBind` refuses a source past the runtime's `IRQ_MAX` first | legitimate: mirrors `IRQ_MAX` |
| Hart task stack 16 KiB, broker 8 KiB (`main.c`, `wifi.c`) | C stack overflow, caught only by FreeRTOS's own checks | legitimate while only the hart loop and the broker's IDF calls run on them |

## A graceful fallback

- `VMAXCOLS 8`: a record with more than 8 fields is stored boxed rather than as
  columns. Correct, slower. The `kinds` bitmask could be a full word.

## Legitimate, left alone

- `SSTR_CAP 128`: **by design.** An `SString` is the fixed-width, stack-friendly
  string -- its width is the point, as a `Static n` ring's is. `SStr.push` past it
  panics by name; text that grows is a `String`.
- `fpr_stack_max` (1 GiB; `FPR_STACK_MAX_MB` for a run): **policy, not capacity.**
  The ceiling on ONE actor's stack, so that recursion that never ends is a named
  panic rather than the machine's memory. Adjustable at run time.

- Page and sector sizes, the Ethernet frame size, virtio and UART register maps.
- `FPR_ARGSPILL 56` (native arity 64): bounded by the rv64 12-bit tp-relative
  immediate (~250 cells), and not a user-visible ceiling anyway -- see below.
- `BUDDY_MAX_ORDER 24`: a 1 TiB block at the 64 KiB minimum.
- `IRQ_MAX 1024`: the PLIC's own ceiling of 1,023 sources (it was 64, which was nobody's limit).
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

- FIXED (2026-09-20): a sleeper woken early was linked on its hart's sleeper list
  twice and the hart spun forever on the cycle (`runtime/actors.c a_sleep_us`);
  posix aarch64 builds did not reserve `x28`, which the context switch does not
  save (`compiler/Build.hs`, `machine/unix/ctx_a64.S`). Both in `docs/LIVE.md`.

- FIXED: `print` wrote CRLF on every system; the carriage return is `hal_putc`'s
  to add now, in the HALs that front a raw serial line. See `C-REDUCTION.md`.
- FIXED: `fpr run` / `fpr build` printed nothing when compilation was refused (the
  compiler's stdout, where type and safety errors go, was discarded).

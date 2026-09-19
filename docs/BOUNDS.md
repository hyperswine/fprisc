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
  `fpr_current_stack()` to a fault handler. `hal/posix` makes the lowest page
  inaccessible and catches the fault on an alternate signal stack, per hart
  thread: `*** FPRISC PANIC [actor 2]: stack overflow -- the actor ran off its
  511 KiB stack`, exit 1. QOS Portable apps reach the same code through three
  new HAL-table entries (the host IS a posix FP-RISC program, so it is one
  implementation); the app registers `fpr_current_stack` so the host's handler
  names the right actor, on any hart. `tests/base/overflow.fpr`, `check_base.py`.
  Cost: two `mprotect` calls per actor lifetime, about 0.9 us (2.6 vs 1.7 us per
  spawn-reply-die over 50,000 actors).

Still open here: **bare metal and the native kernel have no guard** (the hooks
are no-ops; PMP could provide one), so an overflow there is still silent --
though it now has the whole block to fill first. And a stack is still a fixed
size chosen at build time (`FPR_STACK_SZ`, `QOSSTACK`): per-spawn sizes, then
growable stacks, are the real end of this.

Found on the way: a received message that is never `drop`ped pins its whole
slab; 2,000 sequential spawn-reply-die rounds without the `drop` exhaust a
256 MiB heap ("send: no block for the message slab").


# Channel block alignment

Date: 2026-10-27. Fixes the alignment failure discovered while validating
the [C allocator fast path](2026-10-27-ALLOC-FAST-PATH.md).

## Cause and fix

`chan_t` places its consumer head and inline ring on cache-line boundaries
using aligned members. This also raises the alignment of `chan_t` and its
containing `chblk_t`: normally 128 bytes on Apple AArch64, 64 elsewhere.
The channel carve previously rounded its stride to 16 bytes, then used
the raw grant address as its first block. Rounding the stride cannot fix
an unaligned starting address. Buddy payloads follow a single-word header;
loader grants also need only provide word alignment.

`chb_take` now requests four whole channel blocks plus at most
`_Alignof(chblk_t) - 1` bytes of headroom. It queries the capacity using
the original grant pointer, rounds the carve start up to the required
alignment, and subtracts the skipped bytes from the usable span before
seeding its freelist. `sizeof(chblk_t)` supplies a stride that preserves
the type's alignment. Even an exact-sized grant fits four whole blocks;
larger grants contribute only complete cells within the original bounds.

Channel blocks retain their existing type-stable lifetime: unused cells
go to the freelist and retired cells pass through epoch limbo. Their
aligned interior pointers are not returned to the buddy as allocation
bases. Buddy headers, loader interfaces, struct layouts, the native ABI
and the epoch protocol are unchanged.

## Regression coverage

`tests/check_channel_alignment.py` compiles all runtime C with
`-fsanitize=alignment`, stopping on the first diagnostic. A temporary
actor-runtime copy provides controlled grants only inside a C probe;
normal startup and the actor workloads use the actual memory provider.
Production sources contain no test hook.

For both 64- and 128-byte cache lines, on one and four harts, it checks:

- Every byte offset within a cache line, with exact and larger grants,
  including larger spans that end exactly at a cell boundary before the
  start is aligned.
- The first cell and every freelist cell: alignment, complete bounds,
  nonoverlap, and initialized channel fields.
- Four cells from an exact grant and five or six from the larger
  fixtures, depending on tail space, with no additional allocation when
  taking spare cells.
- Untouched canaries before the aligned start and after the last whole
  cell, including unused alignment padding and tail bytes.
- A cell passing through limbo and returning with valid alignment. The
  fixture marks only its own limbo entries quiescent; this checks reuse
  layout, while the production epoch ordering remains unchanged.
- Native contended actor traffic and the twelve-sender shared-inbox
  workload, using the real provider and scheduler.

The original `actors.c` fails the same instrumented test during real
startup, before entering the probe: UBSan reports a misaligned `chblk_t`
access. The corrected implementation passes all six fixture/workload
configurations on one and four harts with empty stderr.

A temporary variant omitting `got -= skip` fails the tight-tail fixture
with `freelist cell outside grant`. This separately checks that the
regression detects an aligned start paired with an incorrectly retained
span size.

## Broad validation

All 145 Base jobs passed across three runs on the same production runtime
and compiler sources. The initial four-worker run passed four jobs, then
the IDEAL HTTP fixture stopped in host Python with `unknown encoding:
idna`. The IDEAL check passed in isolation (234 seconds). The remaining
140 jobs passed in a resumed four-worker run (735 seconds), including
the channel regression, allocator accounting, inbox and actor lifecycle
coverage, native AArch64 execution and RISC-V QEMU checks. This was not a
clean first-attempt suite pass.

After the broad run, the focused regression gained its additional
tight-tail grant case and was rerun successfully in full; production
runtime sources did not change. Validation is local, with no new hosted
CI or physical-board result claimed.

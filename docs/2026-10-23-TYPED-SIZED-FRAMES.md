# Sized reservation for typed RISC-V frames

The typed RV32/RV64 selectors now reserve room for the complete frame before
writing it. Their previous 1 KiB bare-metal hosted ceiling and 32 KiB TLS
ceiling no longer send large functions through the legacy generator. This is
one migration increment; A64/x64 frame limits and final legacy deletion are
still open.

## Entry and return contract

Frames above 1 KiB under a dynamic stack policy check the complete future SP
against the hart's bounded stack window. A miss stages at most 64 parameters
and the return link in a bounded entry shim, then calls
`fpr_stack_reserve(original_sp, frame_bytes)`. The shim restores all arguments,
including the hart cells, after the call. Its maximum staging size is 272
bytes on RV32 and 528 bytes on RV64. This uses the caller's existing C
headroom; the large frame itself has not been allocated or written yet.

The runtime returns zero when the original stack fits, or a new segment top.
The frame header records the original SP so ordinary returns and tail
transfers restore the caller's stack even after segment changes. Self tail
loops reuse the frame. The selected instruction report includes the full
entry shim conservatively and one runtime call site; runtime time remains
unbounded by that report.

Owned reservations validate the supplied SP before reclaiming any segment,
include C headroom, guard arithmetic and rounding, enforce `fpr_stack_max`,
and reuse an adequate spare segment. Unknown foreign stacks cannot request
new sized grants. The zero-low unchecked window remains compatible with
the previously admitted TLS/QOS/ESP frame sizes; larger frames require an
explicit bounded window or an actor-owned reserve. Builtin fixed-stack/no-fuel
policies keep their existing layout and do not acquire actor assumptions.

The plane memory table appends this method and advances its contract to
`FPR_PLANE_MEMORY_ABI=3`. Loaded processes and planes must be rebuilt
together. Native context ABI and register-save layouts do not change.
The fixed 64 KiB Tang Nano Base host supplies a refusal method rather than
pretending it can grow a stack.

The work also enables self-loop argument recovery for indexed hart cells
(parameters 9 through 64). The shared allocator previously recognized only
the named x64 cells for parameters 7 and 8. The normal parallel-copy and
physical-liveness checks still validate the replacement.

Strict-mode diagnostics now inspect scalar refusals before any legacy
rendering or notes. An oversized integer reports the function and typed
reason directly, without a later text-generator exception masking it.
The remaining mixed-startup test uses a synthetic legacy-only Core value;
large source frames no longer serve as a deliberate refusal fixture.

The QOS acceptance run also found a pre-existing typed raw-byte linkage gap:
byte accesses emitted an unreachable alignment slow path, referring to ARC
adapters absent from a hosted raw-unit image. Those accesses now emit no guard
or slow call, matching the legacy byte contract. A freestanding raw library
links without the ARC runtime and passes 2,048 byte-value/address cases with
neighbor canaries. Wider accesses retain their checked alignment adapters.

QOS packaging now preprocesses the runtime header with its actual RISC-V C
target to read native and plane contract versions. Taking the first textual
definition stamped RV64 processes with hosted A64's conditional native ABI 7,
while the RV64 runtime uses ABI 6. `tools/native-abis.py` in QOS selects the
correct target definitions; the loader compatibility test uses it too.

## Evidence and limits

The independent entry ABI oracle executes RV32/RV64 with self loops both
enabled and disabled. It tests all 64 distinct incoming arguments, a 36,016
byte RV32 frame and a 72,032 byte RV64 frame, zero-return and new-stack
reservation paths, fast window checks, exact SP restoration, foreign tail
transfers, preserved registers, and canaries below the usable window. The
reserve and fuel shims deliberately clobber caller registers and hart cells.

The production actor runtime executes 80 nested frames with 512 values held
across each recursive call, a 32 KiB first stack, and forced yields on both
RISC-V widths under QEMU. Separate hosted runtime controls exercise 32
one-MiB reserve/return/reuse cycles, exact plane delegation, address overflow,
stack ceilings, foreign-stack rejection and old/missing plane methods.

Both QEMU and the physical 48 MHz RV32 Tang Nano run a fitting-depth case and
an exhaustion case. The latter independently observes the raw pre-frame SP
inside the old window and the full requested decrement outside it, then
requires the named fixed-stack panic and exit 1. The board run uses checked
RAM uploads after the UART diagnostic; it does not configure the FPGA.

Thirty-one paired measurements compare the old default large-frame fallback
with strict typed generation using the same production C runtime, default
128 KiB first stack, 80 recursive frames and forced yields. Every pair retires
8,538,590 versus 8,251,100 guest instructions on RV32 (3.4% fewer), and
10,036,057 versus 9,748,315 on RV64 (2.9% fewer). QEMU deterministic guest
instruction counts include scheduler/runtime work inside the measured main;
they are not physical elapsed-time measurements. The final compiler and ELF
identities and all samples are in `paired-final.json`.

QOS's complete system native metric remains 1,669 functions over 27 files,
with maximum selected segment 312 and maximum static runtime call sites 67
(7,763 total), at the existing ceilings. This does not supply runtime time or
interprocedural composition bounds.

The relocated QOS process/ABI execution gate passes with virtio 1 and 2, each
on one and two harts. It rejects corrupted images/relocations, missing digests,
wrong native/actor/memory contracts, including the previous memory ABI 2,
then loads and executes the vector process. The final Base sweep passes all
121 jobs in 567 seconds with four workers.
Hosted CI, native x64, Linux hosted
large-frame execution and P4 execution are not claimed here.

See [retained evidence](evidence/2026-10-23-sized-frames/README.md) and the
[full migration goal](2026-10-23-TYPED-IR-COMPLETION.md).

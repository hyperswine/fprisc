# Linked native and C-runtime stack admission

`tools/check_linked_stack.py` derives per-entry stack-pointer bounds from the
**final linked RV64 instructions**, including the C allocator, ARC conversions
and panic paths. This closes a gap left by the compiler's closed-unit stack
summary: an unknown runtime call there can now have a bound when its actual
implementation is present in the image. It does not change the compiler's
earlier refusal policy or supply an assumed runtime frame size.

This is resource-accounting work. It removes no runtime allocations or
instructions and does not establish whole-image arena admission or WCET.

The [compressed-instruction follow-up](2026-11-05-COMPRESSED-STACK-ADMISSION.md)
extends the current gate to mixed RV64 IMC integer code and strengthens the
execution oracle. The measurements below are the initial fixed-width milestone.

## Use and publication

```
python3 tools/check_linked_stack.py \
  --image application.elf --manifest machine/builtin/targets/virt.json \
  --target builtin-rv64-virt-128m \
  --entry callback:400 --report application.stack.json
```

Repeat `--entry` for multiple public entries. The independent image-fit gate
runs first. The stack receipt binds the exact ELF and target manifest by SHA256
and records the instruction-derived call graph, local/total bounds and limits.
An old source summary or sidecar is never accepted as proof of the current code.

The builtin image build can enforce the same gate before publication:

```
make bare-metal-builtin BUILTIN_STACK_ENTRIES="callback:400 other_callback:256"
```

Selected entries must survive the link; an absent entry refuses. A failed stack
check leaves the last admitted image and receipt intact. With this option the
image receipt uses schema 3 and embeds the complete linked-stack proof. Ordinary
image-only builds continue to use schema 2. Switching back to an image-only
build replaces the receipt, so a previous stack claim cannot remain attached
to a new image. This is an optional gate, not a change to existing target RAM,
loader limits or default instruction-set flags.

## Proof contract

The checker decodes reachable executable bytes directly. Symbol names locate
requested strong public entries; symbol sizes, disassembler text and source
annotations do not determine bounds. Direct calls and tail transfers include
their actual linked targets, after relaxation. Constant register values resolve
AUIPC/JALR calls and fixed large-frame adjustments. Both branch arms are
included. Incompatible stack displacements at a join refuse; ordinary loops
with a stable frame converge.

Return reachability is a least fixed point across calls. A call's continuation
is explored only when its callee has a reachable ABI return. Thus a real
non-returning panic/halt path needs no trusted `noreturn` annotation and does
not fall through into padding or the next function. Its own stack and nested
calls still count. Recursive paths with a possible base-case return propagate
that fact before their callers are accepted.

Local stack depths and retained call frames compose with a max-plus fixed
point. Any retaining call cycle refuses. Zero-retaining cycles and tail loops
can have finite stack bounds without terminating. The graph's size determines
convergence; there is no replacement arbitrary recursion or clone limit.

The original v1 gate supported fixed-width RV64 IM integer code. The current
v2 gate also supports compressed integer instructions, mixed-width alignment
and their true continuation addresses. Unsupported instructions,
dynamic SP changes, unresolved indirect
transfers, unbalanced returns, invalid/misaligned stack displacement and
dynamic/interpreted images refuse. Other parts of an image may use extensions
when they are outside every selected entry's reachable graph. The normal
builtin build's compressed integer paths no longer require an IM-only rebuild.

The explicit input contract is valid memory accesses and the ordinary RV64
integer callee-saved/return ABI, also used by FP-RISC's native frame convention.
Calls discard caller-clobbered register facts; preserved registers can retain
frame-pointer evidence. This is **not** a memory-safety or ABI-correctness
verifier for arbitrary machine code. Arguments and their ownership must meet
the entry contract. Entry SP is the reference point: incoming stack arguments,
caller frames and external storage remain separate obligations.

## Evidence

The [execution record](../bench/2026-11-05-linked-stack.json) contains seven
test groups, 216 independently constructed acyclic call graphs, relaxed and
unrelaxed calls, and explicit unsafe-boundary refusals. Replacing a 48-byte
linked callee frame with 96 bytes changes its caller's bound from 80 to 128;
the old 80-byte budget refuses, with a different image identity. A failed CLI
check preserves the previous receipt.

| Allocating callback | Linked bound | Observed SP high-water |
| --- | ---: | ---: |
| Word identity | 224 bytes | 208 bytes |
| Twelve Word arguments | 400 bytes | 384 bytes |
| Bool selecting between Words | 256 bytes | 240 bytes |

These bounds include checked C adapters, generated native frames, the C
allocator/release graph and panic paths. The largest static paths include
`fpr_cpanic`; the successful executions do not take them. Both ordinary and
heap-counter images execute eight calls, covering full-width Words, both Bool
branches and stack-passed arguments. QEMU runs one instruction per translation
block and observes SP without modifying the image. Every observed high-water
is below its bound; exact limits pass and one-byte-short limits refuse.
Heap guards and complete reclamation remain checked independently. Trace
digests and sample counts are recorded; large temporary traces are removed.

The existing raw callback harness separately executes 192 calls per mode on
its guarded fixed stack. The linked proof exactly reproduces the compiler's
32/80/32-byte bounds for loop, nested-call and scalar-product callbacks.

The [build record](../bench/2026-11-05-linked-stack-image-gate.json) covers the
real virt manual/ARC staged publication paths, exact/short/missing-entry checks
and removal of old stack claims when the option is disabled. Existing Tang
BRAM/SDRAM image-fit and preservation checks also pass; Tang execution is not
claimed. The new check is registered in Base and required in the RISC-V CI
configuration; these recorded runs are local host/emulator evidence, not a
remote CI result. The compiler binary remains codegen 180 and generated code
is unchanged, so no new compiler speedup is claimed.
The [initial validation manifest](../bench/2026-11-05-linked-stack-validation.json)
binds the source changes, build checks and unchanged default 256-callback heap
regression to this milestone.

## Remaining composition

The later [controlled activation builder](2026-11-05-STATIC-ACTIVATION-ARENAS.md)
uses this linked bound to provision the actual caller/runtime stack, bind the
C heap contract and reserve non-overlapping storage for a single fresh callback.
It supplies a controlled startup and no resumable interrupts; the general
composition obligations below remain outside this standalone per-entry proof.

A per-entry SP bound does not provision or select its stack. Startup, external
caller frames, incoming stack arguments, asynchronous traps/interrupt nesting,
stack switching and concurrent entries remain outside this proof. It proves
neither termination nor response time. Hardware qualification remains open.

The heap proof still depends on the builtin C allocator contract and a fresh,
aligned, exclusively used arena. Binding those compiler heap facts and arena
geometry to the linked runtime, composing all storage regions without overlap,
and enforcing actual startup/dispatch placement remain necessary for
whole-image static-arena admission. Other instruction sets and
unresolved runtime control flow require additional checked support.

# Fixed arenas for a controlled builtin activation

`tools/build-static-arena.sol` now composes the compiler's heap-demand proof,
the actual linked C/native stack proof, runtime identity, startup and physical
memory placement for **one fresh, exclusive RV64 builtin activation**. It
builds the image itself; it does not accept an arbitrary ELF and trust an old
heap report or a familiar allocator symbol name.

This is a static-resource admission milestone. It does not introduce a compiler
optimization or complete admission for general applications, allocating loops,
concurrent dispatch or physical-board deadlines. The compiler remains codegen
181 with the same binary as the owned-product qualification.

## Use and admitted boundary

Given a builtin library declaring `identity : Word -> Word`:

```
sol tools/build-static-arena.sol callbacks.fpr \
  --entry identity --arguments '[18364758544493064720]' \
  --heap-bytes 416 --stack-bytes 352 \
  --image build/identity.elf --execute
```

The output directory must exist. The image and `identity.elf.admission.json`
are published only after admission and, when requested, successful execution.
The receipt contains the exact image/compiler/source/assembly/runtime hashes,
checked signature, arguments, physical regions, heap demand, linked stack graph
and build commands. A receipt applies only to its exact image hash; it is not
an authentication mechanism for replacement artifacts. Output replacement is
atomic per file, rather than a two-file crash transaction.

The checked C entry supports up to 64 Word/Int/Bool/Unit parameters and one of
those result types. Arguments are JSON integers, checked against the exact
domain, including both Int endpoints and all Word bits. Unit consumes a zero
placeholder in the supplied argument list. Pointer, owned-object and floating
boundaries are not admitted by this recipe. No external caller, live incoming
heap object or unaccounted caller stack is part of the invocation.

Heap space is a multiple of 16 bytes and at least 112 bytes when nonempty.
`--heap-bytes 0` requires a proved zero demand and omits heap initialization.
Stack space is a positive multiple of 16; the final linked proof must fit it.
Neither budget is reduced to the observed high-water mark. A budget that is
large enough in one execution but smaller than the proof still refuses.

## Where the authority comes from

1. The tool invokes the compiler afresh with ARC, one explicit renamed export,
   and heap-budget admission. An isolated cache and cleared inherited FPR flags
   prevent stale sidecars or rollback settings from silently selecting another
   representation. The checked export description supplies the C signature.
2. The [audited contract](../machine/builtin/contracts/rv64-c-heap-v1.json)
   binds the heap analysis, physical calling convention, C allocator, ARC
   adapters and their project-local headers/includes. Changes refuse until the
   contract is reviewed and requalified. Updating hashes alone does not prove
   a new allocator's geometry or allocation behavior.
3. A closed link recipe chooses the C allocator, generated caller/startup,
   fixed target linker script and compiler-produced assembly. It accepts no
   extra objects, alternative heap, arbitrary C, link overrides or user flags.
   Input hashes are checked again after linking. The compiler, source and
   linked image are checked for changes before publication.
4. The final image passes the independent target-image gate. Selected target
   identity is fixed by the recipe, independently of the manifest. Allocated
   sections cannot overlap; heap and stack symbols must describe their exact,
   aligned writable NOBITS sections with no executable-section flag. This is
   ELF metadata, not hardware memory protection.
5. Linked stack analysis starts at the generated ordinary C entry. It includes
   caller frames, incoming stack arguments, the heap setup, native callback,
   actual allocator/ARC routines, output and panic paths. No assumed runtime
   frame size or old stack sidecar supplies a bound.

This trusts the compiler and C/assembler/linker toolchain, as the existing
compiler resource proofs do. The receipt records their identities and the
actual linked inputs. It does not claim to verify a malicious toolchain.

## Startup, ownership and storage composition

The controlled machine-mode startup disables ordinary interrupts, parks other
harts without memory accesses, sets GP/TP and the reserved stack, clears BSS
and tail-transfers to the C entry. It makes no stack accesses before that entry.
The synchronous fatal path writes the QEMU finisher and parks without using a
second stack. It installs no resumable interrupt handler or scheduler.

Static data, allocator state, a checked-capacity hart argument area, heap and
stack all reside in the linked image's accounted RAM extent. The heap and
stack have distinct 16-byte guards at each end. For a nonempty heap, the caller
checks the actual allocator's 80-byte prefix/96-byte minimum geometry, then
initializes exactly the selected range before making the single callback.
No other code in the closed caller allocates. After return it requires complete
reclamation and intact guards, reports the scalar result and halts the emulator.

The heap bound remains cumulative, with the allocator's fragmentation/bitmap
allowance. It is not a peak-liveness optimization. A zero-demand activation has
no heap payload or heap setup, while the guard/accounting metadata remains
included in the image's static size. Valid-memory semantics and immutable code
remain assumptions; NMI/debugger/DMA interference is excluded. Unsafe memory,
CPU-control and unknown runtime calls currently fail the compiler heap gate.

## Qualification

The [execution record](../bench/2026-11-05-static-arena.json) covers ten callback
configurations, full-width Words, both Int endpoints, Bool/Unit values, both
selection branches, mixed argument kinds and the full 64-argument convention.
Each runs at its proved stack limit; the next smaller aligned limit refuses
and preserves the previous image and receipt.

| Callback | Required/reserved heap | Linked whole-activation stack | Observed stack, traced run |
| --- | ---: | ---: | ---: |
| Word identity | 416 bytes | 352 bytes | 336 bytes |
| Twelve Word arguments | 2,640 bytes | 560 bytes | 544 bytes |
| Sixty-four Word arguments | 13,120 bytes | 1,808 bytes | not traced |
| Bool selecting two Words, either branch | 624 bytes | 384 bytes | 368 bytes |

The four traced executions log **all executable sections**, independently of
the predicted call graph. They verify the exact BSS initialization stores,
initial C-entry SP, every subsequent executed PC and stack high-water through
termination. Panic paths remain in the static bound even when not executed.
Integer/Bool/Unit identity cases also execute successfully with zero heap bytes.

Negative cases include short heap/stack budgets, invalid scalar arguments,
unsupported boundaries, unknown printing/overflow paths, interrupt controls,
oversized signatures, altered runtime contracts, wrong target identity, weak
or inconsistent arena symbols, overlapping regions and a deliberately corrupted
runtime guard. Failed builds/execution preserve existing artifacts. Inherited
heap selections and compiler/link flags cannot replace the closed recipe.

The check is registered in Base and requires execution in the RISC-V CI
configuration. These results are local host and RV64 QEMU evidence, not a new
remote CI run or physical board result. The previous 41-suite and compiler-cost
qualification remains tied to the same unchanged compiler binary; no new
compiler performance measurements are claimed here.
The [validation manifest](../bench/2026-11-05-static-arena-validation.json)
binds the final tools, runtime contract, documentation and records. The existing
heap-count/capacity execution suite also passes on the same compiler, including
256 callbacks per mode in plain and measured images; registry checks pass with
the new required configuration.

## Still unfinished

The admitted language subset remains narrow: scalar callbacks whose reachable
allocation costs the compiler proves. Codegen 182 adds shared evidence for
[non-trapping scalar selections](2026-11-05-SCALAR-ARENA-ADMISSION.md), including
Word arithmetic and zero-allocation computational loops. Guarded shifts,
checked arithmetic trap paths, general conversion graphs and allocating loops
still need explicit resource contracts. The gate does not infer termination, useful
loop bounds, peak live storage or WCET from successful examples.

General application startup, resumable/stacked interrupts, multiple entries,
concurrent dispatch, broader Base arenas and physical reference-target timing
remain roadmap work. This controlled activation closes runtime selection,
provisioning, caller/startup composition and placement for its subset; it does
not automatically qualify QOS, the Pi or the separate FP-RISC allocator.

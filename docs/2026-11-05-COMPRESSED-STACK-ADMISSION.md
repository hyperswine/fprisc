# Compressed instructions in linked stack admission

The linked stack gate now supports mixed RV64 IM and integer C instructions.
The ordinary RV64 builtin build already enables compressed instructions; the
gate no longer requires its selected integer call graph to be rebuilt without
them. Unsupported floating-point/other extensions, unresolved control flow,
dynamic stack changes and retaining recursion still refuse.

This broadens resource admission. It does not add a compiler optimization,
change generated instructions, reduce allocations or establish whole-image
arena admission. The compiler remains codegen 180 with the same binary identity.

## Decoding and control flow

`tools/riscv_compressed.py` expands supported short instructions to their base
integer encodings. The analysis retains their actual two-byte length, including
the continuation after C.JALR. Full-width instructions may start at a halfword
boundary when the ELF RVC flag permits it. Short fetches at a section end do
not require nonexistent extra bytes. Reserved, breakpoint and unsupported
encodings refuse, as do truncated or longer-than-supported instructions.

The implementation follows the [official RV64 C 2.0 specification](https://docs.riscv.org/reference/isa/v20260120/unpriv/c-st-ext.html).
RV64-only word operations remain distinct from RV32 encodings. Integer loads,
stores, stack/frame address arithmetic, branches, jumps, constants and register
operations share the existing stack/call analysis after normalization. HINT
encodings retain their architectural integer behavior; they supply no assumed
frame or call bound.

Stack receipts use `linked-rv64-stack-v2`, identifying this expanded decoder
and recording the compressed-instruction count for each analyzed activation.
The enclosing optional image receipt remains schema 3; ordinary image-fit
receipts remain schema 2. All ABI, valid-memory, entry-SP and no-asynchronous-
interrupt assumptions from the [original contract](2026-11-05-LINKED-STACK-ADMISSION.md)
still apply. A bound is neither termination nor a scheduling/WCET guarantee.

## Decoder and execution evidence

The [qualification record](../bench/2026-11-05-compressed-stack.json) includes:

- All **49,152** compressed-prefix encodings considered. The **38,550** supported
  integer/HINT encodings match independent GNU disassembly of their expanded
  base instruction at the same address, including registers, immediates and
  branch destinations. Explicit reserved, breakpoint, malformed and unsupported
  cases refuse. The disassembler's legacy `slli64`/`srli64`/`srai64` names for
  zero-shift encodings are interpreted according to RV64's HINT semantics.
- **216** independently constructed acyclic call graphs in each of IM and IMC
  form, plus relaxed/unrelaxed calls, tail cycles, changing-frame and unresolved
  call refusals. Mixed-width alignment, short/truncated section-end fetches and
  the two-byte C.JALR continuation and frame-preserving zero-shift HINTs have
  dedicated tests.
- Plain and heap-counter images in both IM and IMC modes. Each executes four
  allocating callbacks under a full instruction-step trace: identity, twelve
  Word arguments, and both Bool-selection branches. Full-width Word values,
  incoming C stack arguments, heap guards and complete reclamation are checked.
- Separate raw-callback harnesses execute **192 calls per mode**, in both IM
  and IMC configurations, on their guarded fixed stacks. Compiler bounds,
  linked bounds and observed high-water still agree at **32/80/32 bytes**.

| Allocating callback | Linked bound, IM and IMC | Observed high-water, all modes |
| --- | ---: | ---: |
| Word identity | 224 bytes | 208 bytes |
| Twelve Word arguments | 400 bytes | 384 bytes |
| Bool selection | 256 bytes | 240 bytes |

Static bounds retain panic paths; these successful calls do not execute them.
Exact limits pass and one-byte-short limits refuse in every encoding mode.
The [image-build record](../bench/2026-11-05-compressed-stack-image-gate.json)
uses a genuinely compressed entry under normal builtin flags. Virt manual/ARC
publication and refusal preservation pass, as do the existing Tang BRAM/SDRAM
image-fit checks. This is local host/emulator/cross-build evidence; no new
physical Tang execution, hardware timing or remote CI result is claimed.
The [final validation manifest](../bench/2026-11-05-compressed-stack-validation.json)
binds the decoder, tests, build integration and documentation to these results.

## Trace oracle correction

The initial linked-stack trace filtered logging to predicted reachable PCs.
That could hide a path accidentally omitted by the static analysis, so agreement
with that filtered trace was weaker evidence than an independent execution
oracle. The new trace covers **all executable sections**, independently of the
predicted control-flow graph. It measures every instruction between entry and
the final ABI return, and refuses if execution visits an unpredicted PC.

A fault-injection test supplies a trace entering executable code absent from
the predicted graph; the oracle rejects it. The final record has twelve test
groups and explicitly identifies the full-executable trace scope. Temporary
traces are hashed and removed. This evidence supersedes the earlier filtered
trace for validating path coverage. The shorter four-call traced run limits
trace volume; the ordinary heap regression still runs 256 callbacks per mode.

## Remaining work

This removes the compressed-integer restriction on linked stack accounting.
Heap-contract/runtime binding, arena placement and overlap checks, incoming
arguments/caller frames, startup/interrupt nesting and concurrent dispatch still
need composition. Other instruction extensions and unresolved dynamic runtime
paths require their own checked support. Broader Base/owned aggregates and
physical scheduling qualification remain part of the active roadmap.

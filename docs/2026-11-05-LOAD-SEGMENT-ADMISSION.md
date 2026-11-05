# Complete load-segment accounting

The builtin target-image gate now measures complete ELF `PT_LOAD` extents.
This closes a correctness gap in the C2 image-budget/static-memory foundation;
it is not an abstraction-removal speedup or a dynamic-arena certificate.

## Reproduced undercount

A valid 256-byte text section in an 8,192-byte RAM fixture was accompanied by
a load segment declaring 8,193 memory bytes. The previous gate checked the
section's extent and accepted the image, reporting only 256 static bytes.
The revised gate refuses the out-of-RAM load. Similarly, unsectioned zero-fill
inside RAM now consumes the reserve, and unsectioned file-backed segment tails
consume the loaded-image budget. Extra ELF bytes that are not loaded still
consume neither budget.

Every load segment must now have identical physical/virtual addresses, an
extent inside the selected RAM range, valid file bounds, and valid alignment.
The gate rejects overlapping occupied load ranges because a subsequent load
could overwrite the bytes used to validate the entry point. Empty segments
have no extent. The existing section/segment agreement, executable entry,
target identity, image limit and minimum free RAM checks remain required.

Loaded-image and static-memory spans include gaps from the target origin.
The loaded span ends at the furthest segment's file bytes; the memory span
ends at its complete reserved extent, including zero-fill. On targets that
boot a section-derived flat binary, this is a conservative load-image bound;
it does not change the target's loader or raw-binary format.

Receipts now have **schema 2**, distinguishing complete load accounting from
the earlier section-only schema 1. Target manifests retain schema 1. Re-run
admission to obtain a schema-2 receipt; old receipts are historical evidence,
not proof that the new checks ran. Each receipt still binds the image and
selected target manifest by SHA256. This changes no compiler-generated code
or cache revision; the validated compiler remains codegen 179.

The later optional [linked-stack gate](2026-11-05-LINKED-STACK-ADMISSION.md)
retains these load checks and embeds its per-entry proof in a schema-3 image
receipt. Image-only receipts remain schema 2; target manifests remain schema 1.

## Validation

The [target record](../bench/2026-11-05-load-segment-admission.json) contains
the tool/test/compiler identities and four linked-image receipts:

- Twelve boundary tests pass, covering RV32 and RV64 tails, entire extra
  segments, exact/short reserves, image limits, malformed alignment, address
  overflow, overlap, empty segments and section/entry disagreement.
- Builtin virt with ARC disabled/enabled builds, passes admission and executes
  in RV64 QEMU. Both Tang BRAM and SDRAM variants build and pass admission;
  these are build checks, not physical-board or emulator execution claims.
- Each target refuses tighter limits and mismatched target identities while
  preserving its previous ELF, receipt and optional flat binary.
- Both plain and measured fixed-stack callback images pass the revised gate
  and execute 192 invocations each in RV64 QEMU. Their stack peaks remain
  32/80/32 bytes; see the [callback record](../bench/2026-11-05-loader-callback-stack.json).

No Haskell/compiler/runtime source changed in this correction. The completed
[codegen-179 compiler checks](../bench/2026-11-05-callback-stack-validation.json)
remain applicable; compile-cost gates were not changed or rebaselined.

## Remaining dynamic storage work

Source requested-byte equations still cannot authorize a physical heap arena.
The builtin allocator adds its block metadata and 16-byte object prefix,
rounds payloads to 16 bytes with a nonzero minimum, consumes an unsplittable
remainder when necessary, and reserves an aligned live-start bitmap outside
the blocks. Runtime allocation/conversion paths and region scratch storage
must be included before deriving and enforcing an arena capacity. Peak-live
storage, fragmentation, runtime C stack, interrupt nesting and startup/caller
storage remain separate obligations. Neither this gate nor callback stack
admission establishes a scheduling time bound or hardware WCET.

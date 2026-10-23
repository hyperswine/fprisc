# Typed builtin manual and conservative-GC profiles

This increment starts at `1fe219f` and admits builtin manual/GC code to
the typed RV32/RV64 selectors. It is part of the
[complete migration goal](2026-10-23-TYPED-IR-COMPLETION.md). Builtin ARC
remains a separate, refused ownership policy and still uses legacy
emission. The RISC-V legacy rollback remains available until retirement.

## Runtime contract

The new `Builtin32` and existing `Builtin` policies use 31-bit and 63-bit
tagged Ints respectively, with a **fixed stack and no actor fuel**.
`StackStatic` makes that distinction explicit. Hosted policies cannot
select it; builtin policies cannot request actor fuel or hosted stack
growth. A64/x64 explicitly refuse these RISC-V builtin profiles.

Lowering inserts neither a hosted stack check nor an entry tick. The RV
selector verifies that the entry agrees with the policy and emits a
zero-instruction `entry.static` marker. The allocator can place its
self-tail-loop label after that marker, so recursion reuses its frame
without inventing a scheduler boundary. Ordinary generated calls in this
profile are not marked as fuel safepoints either.

The fixed stack retains the port's existing reservation and responsibility
for stack capacity. It does not inherit the hosted runtime's headroom
ceiling or claim stack growth. Frames still have explicit layout,
callee-save preservation, spills, frame-relative returns and legal large
offset expansion.

The runtime initializes `tp` as the calling-convention/render context,
including argument spill cells. It is not an actor scheduler. Parameters
9–64 retain that convention. Constructor allocation uses the existing
`fpr_alloc` ABI. Manual reference operations and conservative collection
remain runtime operations with their existing contracts.

Native loops without fuel may honestly report `segmax=UNBOUNDED`. This
is admitted for a no-fuel profile, not converted into a fabricated finite
preemption bound. Hosted/QOS policies still reject unbounded native cycles.
Native reports remain instruction counts with separate runtime-call counts;
they are not elapsed-time certificates or bounds on callees' internals.

The generator revision is 75; RV selection revision is 15. There is no
runtime ABI or context-layout change. Existing mode/profile cache keys
separate the legacy rollback and typed compilation.

## Preserve the existing indexed-memory optimization

The manual builtin generator previously applied `indexedMemory` only
inside its text-emission function. Typed lowering now applies the same
Core rewrite before building IR. Its proof is unchanged: a private address
has one volatile access, is immediately released, does not escape or alias,
and has no intervening effect or effectful write argument. Primitive
shadowing is respected.

The resulting private `$mem.*at` names lower as direct calls to the
existing checked C entries in `machine/builtin/unsafe.c`, only under the
manual builtin policy. Base and ARC do not gain this admission. This keeps
the allocation-free private address path and its alignment/errors, rather
than replacing it with ordinary temporary address boxes.

## Correctness evidence

The full local Base regression sweep passes **114 jobs in 352 seconds**
on four workers, including the new generated-root gate
([log](evidence/2026-10-23-builtin-typed/base-final.log)). Hosted CI has
not been run for this milestone.

- **Full RV64 builtin runtime:** `check_builtin.py` passes standalone QEMU,
  a scheduler-free link, shift/mask/size/alignment failures, profile cache
  separation, and the existing heap ASan/UBSan checks
  ([log](evidence/2026-10-23-builtin-typed/builtin2.log)).
- **Generated roots under real GC:** strict all-native RV32 and RV64
  programs keep twelve allocated objects live across calls, recurse with
  roots in older frames, pass twelve arguments and execute a self-tail
  loop. The real C heap collects before every allocation, using the actual
  RISC-V register snapshot and root scanner. More than 2,000 collections
  reclaim over 1 MB of churn in a 64 KiB heap. Removing register/stack
  root scanning makes the same program fail on both widths
  ([log](evidence/2026-10-23-builtin-typed/gc-negative-final.log)).
- **Independent root-adapter gate:** the existing RV32/RV64 register,
  stack/static/interior-pointer, realloc and pressure tests pass; omitting
  one caller-register root fails their negative control. The graph heap
  also passes its native sanitizer cases
  ([log](evidence/2026-10-23-builtin-typed/root-adapter.log)).
- **Full scalar semantics:** the existing IM/IMC runtime gate passes on
  RV32 and RV64 with all builtin functions required native. It covers an
  independent arithmetic oracle, imported helpers, generic application,
  primitive shadowing, overflow/division/bit/memory errors, indexed-memory
  escape/effect boundaries and warm caches. The legacy rollback passes
  the same gate separately
  ([typed](evidence/2026-10-23-builtin-typed/scalar-native-final.log),
  [legacy](evidence/2026-10-23-builtin-typed/scalar-legacy-final.log)).
- **RV32 port checks:** linking, allowed ISA, CSR emission, memory bounds,
  ownership refusals and UART protocol controls pass
  ([log](evidence/2026-10-23-builtin-typed/rv32-port.log)). Those checks alone
  do not execute an FPGA; the physical results below are separate.

The generated-root harness supplies small independent arithmetic/HAL
entries; it uses the actual heap and root scanner. The full-runtime scalar
and manual smoke tests independently cover the real runtime entries.
Exploratory failure logs are retained separately and are not successful
acceptance evidence.

For the local RV64 IM-only scalar gate, the installed GCC's default
`libgcc` has incompatible hard-float modules. The test accepts an explicitly
configured `FPR_SOFTFLOAT_ROOT` and links the project's IM-only bridge
instead. ISA/ABI assertions remain enabled; no A/C/F/D requirement is
silently added to the uncompressed IM test. This checkout reused the
existing sibling build read-only; its library hash is recorded in
[metadata](evidence/2026-10-23-builtin-typed/metadata.json).

## Physical Tang Nano results

The already configured board answered its UART diagnostic at 48 MHz.
The generated RV32 GC program completed **three consecutive runs** with
its real root adapter, 12 live roots, recursive frames, high-arity calls
and allocation-stress collection. Every run returned the expected answer,
printed `FPR EXIT 0`, and returned to the loader with `DONE`
([log](evidence/2026-10-23-builtin-typed/gc-board-final.log)).

The full manual runtime's `builtin_tangnano20k.fpr` also ran with strict
native coverage and printed `TANG NANO BUILTIN HOLDS`, `FPR EXIT 0`, `DONE`
([compile](evidence/2026-10-23-builtin-typed/board-manual-build.log),
[execution](evidence/2026-10-23-builtin-typed/board-manual.log)).

These runs load application RAM through the existing UART loader. The FPGA
bitstream was not reprogrammed or read back here. They establish execution
on the responding board, not new FPGA timing or SDRAM PVT qualification.

Reproduce generated-root acceptance (omit `--port` for QEMU only):

```sh
python3 -u tests/check_typed_ir_builtin.py --require-execution \
  --port /dev/cu.usbserial-20250303171 --freq-mhz 48 --board-runs 3
```

## Paired guest instruction counts

The preserved compiler at `1fe219f` emits the same fixture through legacy;
the new compiler uses strict typed emission. Both link the same heap,
root scanner, arithmetic oracle and test CRT. QEMU runs with deterministic
`-icount shift=0`; the timer is guest `instret` around the generated call,
including its real allocation/collection work. Setup, report printing and
process startup are outside it. Every answer and GC statistic is checked.

| Target | Legacy guest instructions | Typed guest instructions | New/old | Reduction |
|---|---:|---:|---:|---:|
| RV32 | 71,271,984 | 57,653,092 | 0.8089 | 19.1% |
| RV64 | 75,192,482 | 62,294,119 | 0.8285 | 17.2% |

All 31 paired rounds produce the same counts for their target/variant.
A final three-pair check after the indexed-memory change produces the same
counts; that fixture contains no indexed-memory fusion candidate. These
are deterministic guest-work measurements, **not physical elapsed-time
speedups** or claims about all builtin workloads.

[Raw 31 rounds](evidence/2026-10-23-builtin-typed/paired-results.json),
[run log](evidence/2026-10-23-builtin-typed/paired-final.log) and
[final-code check](evidence/2026-10-23-builtin-typed/paired-final-check.log)
are retained. Compiler identities are in the metadata.

```sh
python3 -u tools/bench-builtin-typed.py \
  --against /private/tmp/fpr-builtin-baseline \
  --output /private/tmp/fpr-builtin-paired-final --runs 31
```

## Remaining retirement work

ARC/raw constructors, consuming adapters, representation metadata and
section/link/export behavior still require typed lowering. The compiler
must also migrate native-metric consumers and complete the other open
roadmap items before deleting the generator and peephole path. This
increment does not mark the overall retirement goal complete.

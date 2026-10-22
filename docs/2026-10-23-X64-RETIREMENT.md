# x86-64 translator retirement

Date: 2026-10-23. Kind: implementation and local validation record.
Branch: `typed-ir-retire`, starting at `f1ba409` in `fprisc-typed-ir-next`.

## Change

Typed `qx64` emission now borrows the host TLS block through the published
`fpr_g_tlsoff` displacement. The block's three words are the hart pointer
at offset 0 and argument cells 7/8 at offsets 8/16, matching `runtime/fpr.h`.
This applies to entry stack/fuel checks, kernel safepoints, argument arrivals,
normal and tail calls, and parameters 9–64 in the hart spill area.

Borrowed stores use reserved scratch registers, choosing the scratch that
does not hold the value. The selected instructions expose those clobbers
and early definitions to placement/allocation. Hosted x64 retains its ELF
TLS access; QOS x64 never names the app's `@tpoff` symbols.

- Deleted `compiler/X64.hs` (524 lines) and its Cabal registration.
- Removed the translator's `X64Frames.hs` unit test. RISC-V vector fallback
  frame checks remain, alongside typed x64 emission and runtime oracles.
- Both `x64` and `qx64` require native emission for every function and kernel.
  `legacy`, `0` and `off` are refused for code generation. Analysis-only
  checks and Sol keep their independent paths.
- A named strict subset cannot permit another function to fall back. A
  refusal happens before writing that root or imported unit's assembly.
- The native selector revision advances to 19. Both x64 targets also use the
  `-native1` cache policy, preventing pre-retirement fallback units from
  being reused. Module interface identities stay `x64r10` and `qx64r10`.
- Legacy optimization marker checks now target the surviving RISC-V
  generator. Hosted x64 scalar/ABI, self-loop and vector checks exercise
  typed emission with independent C answers instead of translator output.
- Base and CI include the QOS x64 ABI and retirement regressions. The old
  globally forced legacy Base stage is replaced by a RISC-V rollback
  check; the default Base suite retains explicit RISC-V legacy legs.

RISC-V text emission, `RV64.hs`, `Peephole.hs` and the legacy opt-in modes
remain for their existing consumers. This change does not migrate QOS's
admission metric or implement typed RISC-V QOS/modules/ESP-IDF.

## Local validation

The existing hosted x64 Rosetta suite passed before source changes,
including its legacy and typed differential modes.
[Log](evidence/2026-10-23-x64-retirement/rosetta-before.log).

The first typed QOS scalar/ABI run passed before deleting the translator.
[Log](evidence/2026-10-23-x64-retirement/qx64-before-retirement.log).

The expanded local suite passed after deletion:

- Six typed scalar modes on each of `x64` and `qx64`: normal, workers,
  self loops disabled, shallow checks, forwarded parameters, and both entry
  optimizations. Disabling self loops exercises actual wide recursive tail
  transfers as well as the loop-converted form.
  Each mode runs 32,114 independent C-reference cases and 13 exact slow-path
  traps, including foreign Bool objects, generic applications, 7/8-argument
  non-tail calls, 7/8/9/64-argument rotations, live values across calls,
  callee-save sentinels, call alignment and volatile-register destruction.
- The QOS model switches between two borrowed argument blocks at fuel
  hooks, then clobbers their argument cells and the hart spill cells.
  Offset loads, indexed accesses and scratch choices execute unchanged;
  the FS segment base alone is substituted as described below.
- Unadapted hosted and QOS scalar output assembles as x86 ELF with clang.
- Self loops off/on: 2,100 C-reference argument permutations per mode,
  exact fuel accounting and flat stack use.
- 3,500 kernel cases per target across integer and F32/F64 scalar/record
  maps, stable compaction, folds, fusion and write-back, guard fallbacks,
  empty columns, 9/64/300-column filters and hostile fuel calls. Five
  arithmetic trap cases per target also pass. The pair-sum test supplies a
  GPU hook substitute; it does not exercise physical GPU dispatch.

[Initial five-mode pass](evidence/2026-10-23-x64-retirement/rosetta-final.log),
[final six-mode pass including wide tail calls](evidence/2026-10-23-x64-retirement/rosetta-tail-calls.log).

The retirement regression passes on both targets: native-only roots and
imports, default/mixed/whole-unit cache separation and reuse, all rollback
aliases refused without overwriting existing output, unsupported 65-argument
foreign calls refused in default/whole/named-strict modes, unchanged module
interface stamps, and surviving RV32/RV64 rollback emission.
Its real x64 executable-cache check runs only on a matching native host.
[Log](evidence/2026-10-23-x64-retirement/retirement.log).

Shared selected-instruction, bound-analysis, frame-ceiling and register
allocator checks passed, including a QOS borrowed-hart selection assertion.
[Log](evidence/2026-10-23-x64-retirement/selected-ir.log).

The QOS `f9c00ae` source catalog completed: **198 native-only roots** and
native-only imports, **zero native-emission failures**, 49 frontend refusals
under standalone plugin flags, and the same one pre-existing frontend
exception as the A64 catalog. `programs/mods/blockep.fpr` hits `head []` in
`Exhaust.hs:191` before code generation; the catalog reproduces it with
`--check-only`. It is not counted as successful native emission.
[Per-source results](evidence/2026-10-23-x64-retirement/qos-emission.json).

Seven representative full QOS roots and their imports assemble unadapted
as x86 ELF: **88 unique assembly files**, **16,749 borrowed-offset
relocations**, **zero app TLS relocations**. The roots cover GUI shell,
disk, Main Profile, logs, editor, terminal preferences and large storage.
This is an assembly/relocation check, not a link or runtime check.
[Results](evidence/2026-10-23-x64-retirement/qx64-elf.json),
[log](evidence/2026-10-23-x64-retirement/qx64-elf.log).

The standalone F64 oracle passes 400 hosted edge-case pairs with fast paths
and inlining independently enabled/disabled, plus 1,280 Rosetta pairs.
[Log](evidence/2026-10-23-x64-retirement/float-after.log).

The full post-retirement Base rerun passed: **107/107 jobs, exit 0**, in
403 seconds with four workers and a separate cache root. This includes the
QOS x64 scalar/ABI and retirement regressions, six-mode hosted/QOS scalar
oracles, typed kernel oracles, the corrected F64 test, and the surviving
RISC-V legacy checks. Matching-native x64 runtime integration remains a
host skip on this ARM machine; the separate Rosetta checks above execute.
[Full log](evidence/2026-10-23-x64-retirement/base-after.log),
[compiler/source hashes and validation metadata](evidence/2026-10-23-x64-retirement/metadata.json).

Changed Python files parse, the workflow YAML parses with Ruby's YAML
parser, and `git diff --check` is clean. Hosted CI has not run for this
uncommitted change.

## Evidence boundary

This machine is Apple Silicon. Execution uses Rosetta and test-owned C
runtime hooks. Hosted TLS is replaced by harness cells; for QOS, the harness
publishes a block pointer in place of the host FS displacement, removes the
FS segment override, and applies Mach-O symbol spelling. It preserves the
emitted offset load, addressing, argument, arithmetic, frame and call code.
The original output is separately assembled as ELF.

This validates emission and the substituted ABI. It is not execution of
real Linux TLS, a loaded x86-64 QOS image, multithreaded scheduling, actor
migration, real stack growth, or native x86 performance. Those remain
separate acceptance gates; no x86-64 QOS run environment is available here.

An initial post-retirement local run exposed two stale self-loop harness
assumptions: a missing stack-check stub and the translator's loop label.
The harness now gives the bounded probe full stack headroom, rejects any
unexpected stack growth, and checks the native allocator's loop label.
The failed run is retained in
[its log](evidence/2026-10-23-x64-retirement/rosetta-after.log).

The first full post-retirement Base run reached the floating-point check,
which still explicitly requested the removed x64 legacy backend. That leg
is removed; the typed F64 check and independent C reference remain.
[Failed run](evidence/2026-10-23-x64-retirement/base-after-attempt1.log).

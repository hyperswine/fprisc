# Typed native generation: final retirement candidate

Kind: implementation and acceptance record. Applies to codegen revision 89 in
`fprisc-typed-ir-next`, after local commit `042a6d8`. The final local acceptance record is collected below; synchronization follows
the completed gates. This supersedes the remaining-generator
inventory in the earlier retirement pages; those pages retain their historical
measurements.

The compiler now produces native code exclusively through verified typed IR.
`Codegen.hs` retains Core normalization, workers, fusion and column-kernel
planning. Scalar functions and planned kernels both lower to typed CFGs, then
use the RV32/RV64, AArch64 or x64 selector. Selection refusals are compile errors
before assembly output; they never invoke another generator.

The removed code includes the RISC-V scalar renderer, unboxed callback clones,
text-template vector kernels, their mutable rendering state, `RV64.hs` host
translation, ESP text substitution, `Peephole.hs`, slot promotion/compaction and
the old instruction-bound analysis. A64.hs and X64.hs were removed in earlier
milestones. About 2,900 lines were removed from Codegen.hs alone.

`Codegen.NativeData` independently owns static PAPs, module registry/schema
strings, visibility, ARC object sections and immortal constructor constants.
Complete outputs were compared against the preceding generator before wiring in
this owner, then frozen as independent fixtures. Native function literals and
boxed RV32 numeric leaves retain their existing native owners.

## Interfaces

- All supported native targets require complete scalar and kernel coverage.
  `FPR_TYPED_IR_BACKEND=legacy`, `off` and `0` fail on every ISA, including when
  output and unit caches already exist. The supported `mixed` and `1` spellings
  retain their diagnostic granularity and cache separation; neither permits
  legacy code.
- The old `FPR_SELF_LOOPS`, `FPR_RETAINED_REGISTERS`, `FPR_COSTED_REGISTERS`,
  `FPR_COMPACT_FRAMES`, `FPR_NO_REGISTERS` and `FPR_NO_RV32_FAST` modes and cache
  keys are removed. Typed allocation and `FPR_TYPED_IR_SELF_LOOPS` remain.
- `FPRC_NATIVE_INSNS=1` summarizes `native-insns-v1`. The former `FPRC_WCET`
  reporting mode and `# wcet:` emission are removed. The metric counts selected
  target instructions between safepoints and static runtime call sites. Runtime
  elapsed time and interprocedural call/return composition are still unprovided;
  this is not a latency certificate.
- Sized frame reservation uses plane memory ABI 3. Target-specific native context
  ABI remains 7 for hosted A64 and 6 for the other supported contexts. QOS now
  obtains ABI values from preprocessing the actual target runtime header.

## Acceptance evidence

The [evidence directory](evidence/2026-10-23-generator-retirement/) records compiler
and source hashes, commands, logs and explicit exit status. Failed migration-test
expectations are retained under `development/`; they are not passing acceptance.

- The focused migration gate passed eight jobs, including one/four-hart actor
  behavior, exact fuel, cycles through 2/7/8/63 arguments, effects, fairness,
  stable vector results, SIMD tails, retired-mode refusals and cache transitions.
- Static-data predecessor snapshots pass for RV32/RV64, A64 Mach-O, x64 and ARC,
  including weak/strong exports, PAP layout, module schema and byte strings.
- Linux RV64 cross-builds passed all 17 execution cases under QEMU user mode:
  arithmetic/floats/vectors, actors, sleep/wake, I/O, context switching and
  actual dynamic module loading, with one and four harts.
- Linux x64 production-runtime tests passed 9,000 held fields across nine nested
  generated frames and forced yields, on one/four harts with both default and
  32 KiB first stacks. The ELF assembly and TLS are used directly, without the
  Mach-O/Rosetta oracle substitutions.
- The full Base sweep passed all 123 jobs in 524 seconds on four workers.
- The source package includes the native data owner, excludes retired modules,
  builds from fresh objects in its own offline Cabal project, and builds/runs a
  hosted smoke program successfully.
- Across 20 scalar/record/float/kernel compilations on four selectors, 5,762
  selected function bodies, their order and instruction reports match the
  predecessor after normalizing cache revision spellings.
- The final compiler passed QEMU and physical 48 MHz Tang Nano fitting-frame
  and pre-frame-exhaustion checks. Only RAM images were uploaded.
- The complete QOS sweep passed 155 legs with no failures and seven registered
  dependency skips. Additional partial skips are identified in the evidence README.
  The missing WebSocket dependency was then installed in a private environment;
  both complete WebSocket suites pass: FPRLive protocol/adversarial/persistence,
  and POS1 including four crash windows and 300 receipts against a 50-row page.
- QOS's target ABI helper now reads the RV64 preprocessed header. Supplemental
  checks repaired pre-existing HTTP startup races, stale CSS/client assertions and
  strict decimal overflow handling, with independent failure/readiness controls.
  Parser boundary tests pass on Portable and RV64 QEMU. The fresh QOS system
  instruction audit covers 1,699 functions in 28 files, keeping both the 312
  instruction and 67 runtime-call-site ceilings.
- Native Linux A64 execution passes 10,000 complete FP context roundtrips,
  the integer-only-context negative control, 12 live FP values across yields
  and calls, and nine nested 9,000-field frames on 32 KiB first stacks,
  each actor workload on one and four harts.

Linux execution uses isolated ARM64 Ubuntu containers: native A64 GCC/runtime
execution, and matching cross GCC sysroots with QEMU user mode for x64/RV64. It exercises the real Linux runtime/loader contract;
it is not physical x64/RV64 performance evidence or a hosted CI result. Rosetta,
A64, QEMU-virt and earlier physical Tang results remain scoped to their recorded
compiler snapshots. The attached ESP serial adapter identified as an ESP32, not
an ESP32-P4; its flash was unchanged, and this run makes no physical P4 claim.

Fused map/filter SIMD, extending the floating register pools to more targets and
further dynamic-width compaction are performance follow-ups. They do not supply
missing functionality for the retired generator.

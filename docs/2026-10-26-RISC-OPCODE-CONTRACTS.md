# AArch64 and RISC-V selected operation contracts

Date: 2026-10-26. Kind: compiler architecture stage and validation record.
Applies to main `d190e1a` plus this stage. Codegen revision remains 120.
The full [compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) stays active.

## Per-ISA operation vocabulary

Every production native selector now constructs operation identities directly.
`Codegen.Opcode.Types` owns shared protocols, conditions, float widths/banks and
SIMD payloads. `Codegen.Opcode.A64`, `.RV` and `.X64` own the ISA vocabularies;
`Codegen.Opcode` carries their tagged union through shared placement/allocation.
No selector or renderer interprets a string as an operation or condition.

The A64 FP pool matches operation constructors and changes the explicit bank
from word bits to FP registers. Tree leaves/results carry the same bank choice.
The renderer consumes that bank and width directly. RISC-V raw adapters retain
typed arithmetic, comparisons and load/store variants in their lookup tables;
they do not manufacture mnemonics by concatenating strings. RVV operations and
float-tree steps retain constructors as well.

The shared shrink-wrap save marker is a protocol constructor. Redundant-move
elimination compares actual opcode identity. Diagnostic spelling is confined to
`siOp`/name rendering. Synthetic allocator tests may still construct invented
text operations; all three native form checkers refuse that vocabulary and
instructions belonging to another ISA.

## Checked effects and physical operands

Dedicated A64/RV form checkers verify the selected stream and the final physical
stream before rendering. A64 also verifies the input/output of FP pooling and
entry forwarding. `Codegen.Target.Forms` owns shared register/operand checks,
entry/transfer/cell forms and explicit call-accounting roles. Each ISA checker
owns its opcode forms and effects.

The checks cover GPR/FPR banks, fixed argument/result registers, operand counts
and roles, FP/SIMD scratch indices, control targets and call metadata. A64 keeps
its explicit condition-flag dependencies; RISC-V rejects flag dependencies.
Malformed SIMD operations outside the existing checked gate are refused during
selection instead of producing an unsupported instruction spelling.

Runtime structures, context switching, physical ABIs, codegen/cache revision
and source AST Binary identity are unchanged. The saved-compiler comparison
checks assembly bytes and dependent-unit cache keys without normalization.

## Validation

The selected/allocation invariant suites pass. New checks refuse wrong pooled
FP banks, synthetic/cross-ISA instructions, malformed branch/fuel metadata,
RISC-V condition flags, missing load offsets, out-of-bank tree steps and wrong
call result registers. Existing x64 constraints and shared entry/loop checks
remain active.

The emission oracle passes all 167 root/dependent-unit outputs and cache
identities across 85 configurations on eight targets: x64, qx64, x64mac, a64,
a64mac, qa64mac, RV64 and RV32. It includes hosted A64 with its FP pool, RVV
plugins and builtin ARC/managed-raw/raw-library fixtures. Assembly and keys are
compared byte for byte with no normalization.

The float-tree oracle passes 5,427 F64/F32 triples and six predicates with exact
rounding, signed-zero and NaN behavior on native A64, Rosetta x64 and RV64 QEMU.
The RV64 ARC/raw suite passes sharing/escape and deep-drop checks, sanitizer
checks, qualified library/C-export boundaries and the FP-RISC allocator. Its
raw byte library passes 2,048 value/address cases with neighbor canaries;
dropping constructor field metadata fails the real ownership runtime as
required. The independent Python word/Int oracle passes all 879 checks,
including every shift/bit index, wrapping, high bits and checked arithmetic.

The final fixed-source, fresh-cache Base sweep passes all 136 jobs in 586.74
seconds on six workers, with no reused configurations and unchanged timeouts.
The preceding x64 stage took 577.36 seconds under the same worker count. Sol
argument/shared-language checks pass; self/mutual tail calls each complete three
million iterations with an 86 MB reported peak and terminal `TailCall` bytecode.

The local sweep skips native Linux x64 runtime execution on this macOS host and
the POSIX RV64 artifact check when clang lacks its RISC-V backend. Rosetta x64
and the registered RV32/RV64 QEMU gates pass. No physical-board execution is
claimed.

Local records use
`/private/tmp/fpr-risc-opcodes-*.log` and the complete sweep's timing JSON.

The preceding integrated x64 commit `d190e1a` passed
[hosted CI run 40222451310](https://github.com/hyperswine/fprisc/actions/runs/40222451310),
including Linux x64 native execution, RISC-V runtime gates and the final Base
sweep. That checkpoint also includes the region-control implementation.
The region-control run `40220603207` was cancelled when that commit superseded
it; cancellation is not a complete hosted pass. This stage needs its own hosted
result after push.

The integrated native-opcode commit `9c12c6b` subsequently passed
[hosted CI run 40225611701](https://github.com/hyperswine/fprisc/actions/runs/40225611701),
including Linux x64 execution, native RISC-V runtime gates and the final Base
sweep. That result covers the per-ISA constructors and form contracts here.

## Remaining cleanup

Typed later inlining/fusion/workers/reuse, remaining compatibility source forms
and layout temporaries, source ranges/diagnostics, existing call conventions,
symbol roles and multi-purpose instruction annotations remain required. Moving
ISA operations to constructors does not complete the original compiler goal.

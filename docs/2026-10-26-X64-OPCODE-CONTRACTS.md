# Constructor-based x64 selected operations

Date: 2026-10-26. Kind: compiler architecture stage and validation record.
Applies to main `820eb22` plus this stage. Codegen revision remains 120.
The full [compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) stays active.

## Operation identity through placement

`Codegen.Opcode` defines shared entry/transfer/cell protocols and the x64
operation vocabulary. x64 selection now constructs operations directly. Branch
conditions, F32/F64 widths, arithmetic/comparison operations, float-tree steps
and SSE2 pair operations retain their constructors through placement and
allocation. The x64 renderer matches those constructors and prints assembly;
it no longer decodes string prefixes or operation/condition names.

`SInstr.siOpcode` carries that identity. `siOp` is an ordinary diagnostic-name
accessor. The shared allocator, forwarding-entry and shallow-entry passes use
constructors when recognizing and splitting entry sequences, recovering wide
arguments, or replacing self tail transfers with loop jumps.

The A64/RISC-V selectors still use the explicit `TargetText` migration input
for ISA-specific operations. Their shared entry/cell operations are normalized
at construction. x64 refuses this transitional vocabulary rather than letting
it reach its renderer. Migrating the other ISA vocabularies remains required.

## One checked form contract

`Codegen.Target.X64.Forms` verifies opcode/operand forms before allocation and
again on the final physical stream before rendering. It checks word-register,
symbol, immediate, label and frame operand roles; float/SIMD scratch indices;
control destinations, flag effects and call-accounting metadata. It also checks
the actual x64 constraints: two-address ties, the division dividend/result and
hidden remainder register, the variable shift count, and call/return argument
and result registers. Shared register/liveness/allocation checks remain active.

Both the vocabulary's name renderer and the form checker require exhaustive
constructor matching. Synthetic allocator tests and the other ISA selectors
retain an explicit transitional constructor; it is not an x64 escape hatch.
The x64 source's semantic comments now point to the evaluator/runtime contracts
rather than the deleted text generator.

This refactor preserves instruction sequences, native bounds, cache keys,
runtime structures and physical ABIs. There is no codegen-revision bump because
the two-compiler oracle requires exact assembly and dependent-unit identity.

## Validation

Selected/allocation invariants pass, including new refusals for transitional
x64 operations, operand count/kind mismatches, dropped call metadata, wrong
branch/flag effects, invalid float scratch indices, missing division constraints
and lost arithmetic ties. Shared shallow-entry rewriting retains its typed
operation and fuel event.

Hosted and QOS x64 scalar probes pass under Rosetta across six modes, each with
32,114 independent C-reference cases, 13 exact slow-path traps, wide argument
rotations through arity 64, non-tail arguments seven/eight, generic applications,
register pressure and ABI preservation. These probes substitute Linux TLS/the
scheduler or QOS's borrow block; they do not claim a running x64 QOS kernel.
The existing vector and record/F32/pair-sum kernel oracles pass on x64 and qx64.
The float-tree oracle passes 5,427 F64/F32 triples and six comparisons with exact
rounding, signed-zero and NaN behavior on A64, Rosetta x64 and RV64 QEMU.

The Mach-O test assembles 301 typed functions in two files. Actors, mailboxes,
confinement, wide arguments, segment growth, large frames, floats, I64 and the
loop probe execute under Rosetta using the real runtime and Darwin TLV cells;
stdout and status match native AArch64 executions.

The exact-emission oracle passes 120 root/dependent-unit outputs across ten
configurations on each of x64, qx64, x64mac, qa64mac, RV64 and RV32. It compares
all assembly bytes and dependent-unit cache identities with the saved compiler,
including scalar entry/loop modes, float trees, vector/record/F32/pair-sum
kernels and a prelude-linked wide-argument program. No normalization is applied.

The final fixed-source, fresh-cache Base run passed all 136 jobs in 577.36
seconds on six workers, with no reused configurations and unchanged timeouts.
The preceding stage took 572.64 seconds. Sol argument/shared-language checks
pass; self/mutual tail calls each complete three million iterations with an
86 MB reported peak and terminal `TailCall` bytecode.

The macOS sweep explicitly skips native Linux x64 runtime execution and the
POSIX RV64 artifact check when clang lacks its RISC-V backend. Rosetta x64 and
the available RV32/RV64 QEMU gates pass. No physical-board execution is claimed.

Local records use
`/private/tmp/fpr-x64-opcodes-*.log`. The comparison tool is
`tests/compare_native_emission.py --against PATH_TO_SAVED_FPR`; it is an explicit
two-compiler gate, not a redundant normal Base job.

Hosted validation for this stage follows its push. The preceding region-control
run is [40220603207](https://github.com/hyperswine/fprisc/actions/runs/40220603207);
its status does not substitute for this stage's own hosted result.

The integrated x64 commit `d190e1a` subsequently passed
[hosted CI run 40222451310](https://github.com/hyperswine/fprisc/actions/runs/40222451310).
It includes Linux native execution and the earlier region-control work; the
region-only run was cancelled when superseded rather than completing a pass.

Later typed inlining/fusion/workers/reuse, remaining compatibility forms and
layout temporaries, source ranges/diagnostics, A64/RISC-V operations and existing
call-convention contracts remain part of the original active goal.

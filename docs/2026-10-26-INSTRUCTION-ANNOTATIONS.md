# Typed instruction annotations and allocator events

Date: 2026-10-26. Kind: compiler architecture stage and validation record.
Applies to main `9c12c6b` plus this stage. Codegen revision remains 120.
The full [compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) stays active.

## Separate semantic payloads from accounting

Selected instructions no longer carry the overloaded `siNote :: String` field.
`siAnnotation` distinguishes ordinary instructions, typed entry labels, an A64
save-group index and a shrink-wrap exit that skips restores. `siAllocation`
independently records a spill store, reload or register copy. Allocation
statistics consume those events directly; a label named `copy`, `reload` or
`spill` cannot change the counters or overwrite an instruction's semantic data.

Entry expansion uses shared `StackReady`, `SameStack` and `FuelReady` roles.
Both the renderers and the scope checker derive labels through the same typed
role builder. Printers do not decode annotation tags or integer strings. A64
save operations carry numeric group indices checked against the final frame's
actual save table before rendering.

## Explicit annotation contracts

`Codegen.Annotation` checks payload/operation roles, required entry data,
implicit entry-label collisions with local blocks or other expansions, and
allocation-event roles on physical copies/loads/stores. Native form checkers
invoke it before allocation and on the final physical stream. x64/RISC-V cannot
inherit A64's conditional-restore marker. The existing shrink-wrap dominance
analysis still decides which A64 exits skip restores; typing that decision does
not change the analysis or allocation strategy.

Self-loop formation preserves an entry's annotation while splitting its stack
check and fuel tick. The two halves share their checked stem and expand to
disjoint label roles. Entry forwarding and shallow-entry rewriting preserve the
same payload contract. Accounting events retain their separate ownership when
instructions are copied or annotated by later passes.

## Validation

Expanded selected/allocation invariants pass. They refuse missing or misplaced
entry/save data, captured or duplicate implicit labels, out-of-frame save
indices, events on the wrong instruction or virtual operands, and conditional
restore markers on an always-restore target. They also verify typed shrink-wrap
exits and self-loop entry splitting, and compare real allocation statistics
under adversarial entry spellings.

The saved-compiler oracle passes all 167 root/dependent-unit outputs and cache
identities across 85 configurations on eight targets, with no normalization.
It includes hosted A64/FP pooling, QOS A64, x64's three formats, RV32/RV64, RVV
plugins and builtin ARC/managed-raw/raw-library fixtures. Assembly, bounds,
allocation statistics and unit keys are unchanged, so codegen/cache revision
120, runtime structures, physical ABIs and source AST Binary identity remain
unchanged.

The final fixed-source, fresh-cache Base run passes all 136 jobs in 584.02
seconds on six workers, with no reused configurations and unchanged timeouts.
The preceding stage took 586.74 seconds under the same worker count. Sol
argument/shared-language checks pass; self/mutual tail calls each complete three
million iterations with an 85 MB reported peak and terminal `TailCall` bytecode.

The macOS sweep explicitly skips native Linux x64 runtime execution and the
POSIX RV64 artifact check when clang lacks its RISC-V backend. Rosetta x64 and
the registered RV32/RV64 QEMU gates pass. No physical-board execution is claimed.

Local records use `/private/tmp/fpr-annotations-*.log` and the complete sweep's
timing JSON. The preceding integrated native-opcode commit `9c12c6b` passed
[hosted CI run 40225611701](https://github.com/hyperswine/fprisc/actions/runs/40225611701).
This annotation stage requires its own hosted result after push.

Existing call conventions and symbol roles, later typed transformations,
remaining compatibility forms/layout temporaries and source ranges/diagnostics
remain required. This stage does not complete the original compiler goal.

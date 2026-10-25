# Checked native column-kernel plans

Date: 2026-10-26. Kind: compiler architecture stage and validation record.
Applies to main `127c8fd` plus this stage. The full
[compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) remains active.

## Operation and plan owners

`Compiler.VectorOperation` owns `Map`, `Filter` and `Fold` independently of
Core optimization and native CFG construction. The vector planner retains
its compatibility reexports and existing symbol serialization. Native column
stages carry those constructors through lowering, rather than converting
them to strings and classifying the strings again. Column and record fallback
calls use explicit runtime entry declarations with their boxed signatures.

`Codegen.Kernel.Plan` owns the column plan and its admission checks.
`CheckedKernel` is opaque and retains the exact policy, callback snapshot and
draft it checked. The CFG builder consumes that product; clients cannot attach
an unchecked plan to another callback snapshot or policy.

Checks cover nonempty stages and symbols, entry/callback arity limits,
capture and accumulator bounds, accumulator kinds, the single terminal fold,
available boxed callback interfaces, SIMD capture/fuel evidence and RVV's
capture-free sum shape. Out-of-line callbacks remain supported: the deliberate
pipeline inline opt-out supplies no bodies to the builder. This is native
representation checking, not a claim to recover source types from a CFG.
Available callback CFGs are checked at the target word width before copying
blocks, preventing malformed operands/edges from reaching the copier's maps.
SIMD fuel multiplication must fit the host count representation.

The remaining erased Core inliner still needs a separate migration that
preserves argument effects, fresh identities, imported code ownership and fuel
ticks across the region/ARC pipeline. Record and layout-changing kernel plan
ownership, remaining source/data/linker interfaces, compatibility/layout forms
and source ranges/diagnostic producers also remain full-goal work.

## Validation

The existing `KernelIR.hs` job covers malformed capture/accumulator indices,
fold order, callback interfaces, stage/entry arities, SIMD/RVV restrictions
and exact runtime fallback signatures, alongside its native whole-unit checks.
The final saved-compiler oracle passes all **170 complete root/unit outputs
and cache identities across 88 configurations on eight targets**, without
normalization. Native bounds, allocation statistics and dependent-unit cache
keys remain unchanged. Codegen revision 120, ARC revision 6, source AST Binary
identity, runtime/context structures and physical ABIs are retained.

The fixed-source fresh-cache full Base sweep passes **136/136 jobs in
604.04 seconds on six workers**, with no reused configurations or timeout
changes. Sol argument/shared-language checks pass; self/mutual tail calls each
finish three million iterations with an 86 MB reported peak and terminal
`TailCall` bytecode.

The sweep covers native A64 C interoperability, stack growth and one/four
harts; Rosetta x64/qx64; RV32/RV64 QEMU wide frames, plugins and RVV; real
ARC/raw/export and actor-runtime oracles. macOS explicitly skips native Linux
x64 runtime execution and the POSIX RV64 artifact check when clang lacks its
RISC-V backend. No physical-board execution is claimed. Local records use
`/private/tmp/fpr-kernel-plans-*`, including the complete timing JSON.

The preceding runtime checkpoint `127c8fd` is awaiting its hosted result at
[run 40239373934](https://github.com/hyperswine/fprisc/actions/runs/40239373934).
This stage also requires hosted validation on the synced main revision.

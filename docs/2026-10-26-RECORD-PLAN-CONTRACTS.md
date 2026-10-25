# Checked record and layout kernel plans

Date: 2026-10-26. Kind: compiler architecture stage and validation record.
Applies to main `18a600f` plus this stage. The full
[compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) remains active.

The [column-kernel stage](2026-10-26-KERNEL-PLAN-CONTRACTS.md) now extends
to record and layout-changing kernels. `Codegen.Kernel.Plan` owns their
descriptions and admission checks. Opaque `CheckedRecord` and `CheckedMapAs`
products retain the exact policy and plan; record products also retain the
callback snapshot. `Codegen.Kernel` builds CFGs from those products and no
longer combines plan definitions/admission with CFG construction.

Record checks preserve existing kind, word-width, GPU and field-coverage
rules. They additionally bound column-count arithmetic and projection
displacements, reject contradictory duplicate column descriptions, check
entry/callback arities and boxed callback interfaces, and verify callback CFGs
before copying their blocks. Scalar fold captures, capture-free filters and
record maps' tuple captures have different entry interfaces; malformed plans
cannot silently mix them. A field reading a capture requires a tuple, and
every field's column reference must have a descriptor. Nullary field callbacks
remain supported, as do generated out-of-line callback calls.

Layout-changing maps retain the existing zero-through-seven capture limit,
boxed calling convention, generic fallback and opaque layout specification.
The checked product also requires valid policy and nonempty entry names.
These checks do not reconstruct source-language types from boxed native IR.
Later typed Core transformations, remaining source/data/linker contracts,
compatibility/layout forms and diagnostic ranges/producers remain goal work.

## Validation

The existing kernel test job now includes record/layout admission and refusal
cases, malformed callback operands/edges, tuple/scalar capture distinctions,
sparse columns, projection/column-count bounds, nullary callbacks and `mapAs`
boundary cases. It retains the whole-unit selector and column tests.
The saved-compiler oracle passes all **170 complete root/unit outputs and
cache identities across 88 configurations on eight targets**, without
normalization. Native bounds, allocation statistics and dependent-unit keys
are unchanged. Codegen revision 120, ARC revision 6, source AST Binary
identity, runtime/context structures and physical ABIs are retained.

The final fixed-source fresh-cache Base sweep passes **136/136 jobs in
596.98 seconds on six workers**, with no reused configurations or timeout
changes. Sol argument/shared-language checks pass; self/mutual tail calls each
finish three million iterations with an 86 MB reported peak and terminal
`TailCall` bytecode.

Native A64 C interoperability, stack growth and one/four harts, Rosetta
x64/qx64, RV32/RV64 QEMU wide frames/plugins/RVV, real ARC/raw/export and
registered actor-runtime oracles pass. macOS explicitly skips native Linux
x64 runtime execution and the POSIX RV64 artifact check when clang lacks its
RISC-V backend. No physical-board execution is claimed. Local records use
`/private/tmp/fpr-record-plans-*`, including the complete timing JSON.

The preceding runtime checkpoint `127c8fd` passed
[hosted CI run 40239373934](https://github.com/hyperswine/fprisc/actions/runs/40239373934).
Hosted validation of the combined column/record/layout changes on the synced
main revision remains required.

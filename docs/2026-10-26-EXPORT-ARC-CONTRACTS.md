# Checked C export plans and ARC representation evidence

Date: 2026-10-26. Kind: compiler architecture and correctness stage.
Applies to main `871845e` plus this stage. The full
[compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) remains active.

## Export pipeline

`Compiler.Native.Exports` owns declaration lookup, physical arity admission,
C-representable type projection and source-owned export errors. It produces
checked plans instead of sending surface types to an assembly helper in
`Compile.hs`. The driver selects the float ABI, supplies the already resolved
native target and consumes the resulting descriptions/assembly.

`Codegen.Export.Plan` retains the declared boundary signature, distinct public
C/native entry symbols, argument source locations, native destinations,
conversion operations, result conversion, adapter frame and emission order.
Its checker validates signature coverage, C integer/FP banks, FP-RISC argument
locations, conversion types, frame/immediate bounds and read-before-overwrite
scheduling. Only its opaque checked product reaches
`Codegen.Target.RV.Export`, which renders explicit operations without counting
argument banks or inferring conversions from source types.

Existing supported limits remain: RV64 builtin C exports, up to 64 parameters
under the soft-float ABI and eight total parameters under hard-float. The
separate raw-unit register-only limit is retained. This stage adds no arbitrary
foreign C stack/FP calling capability.

## Reproduced ARC failure and retained evidence

The independent mixed/wide C execution probe fails on the saved compiler
`871845e` with `Builtin panic: Builtin: invalid allocation pointer`. It passes
an interior address from the real builtin stack/heap to an explicitly declared
`Addr` parameter. An identity-style body does not constrain that parameter in
the erased representation solver. Its unknown defaults to managed, so ARC
attempts to retain/release a raw address. The same omission affects unboxed
Word/F32/F64 parameters that lack constraining operations in their bodies.

`Compiler.Native.Representation` now projects concrete representation evidence
from the retained checked/closed interfaces and checked compatibility calling
declarations. ARC consumes those signatures before use constraints/defaulting;
the solver checks them against actual function identities, physical arities,
calls and bodies. Unknown type variables remain unconstrained. The driver does
not reconstruct these signatures from pretty-printed or re-inferred Core.

Representation kinds and primitive signatures use constructors rather than
character tags. The existing `t/w/a/d/f` field-layout tags are serialized only
at the runtime boundary. ARC ownership decisions consume the typed kinds.
The representation solver and ownership rewrite still operate on erased Core;
this retained interface boundary does not claim their complete migration to
typed expression transformations.

Corrected ownership code advances `arcRev` from 5 to 6. General codegen revision
120, native calling conventions, runtime/context structures and source AST
Binary identity remain unchanged.

## Validation

The new independent C callers pass 2,176 soft-float and 1,024 hard-float calls
under RV64 QEMU with the real ARC runtime. Every parameter gets a position-
specific value. Coverage includes all seven boundary types, negative Ints,
raw Word bits, interior addresses, Unit conversion, F32/F64 IEEE bits,
independent C integer/FP banks, positions 9 through 64 and hart cells. The saved
compiler reproduces the ownership panic; the corrected compiler passes.

Checked-plan/representation invariants cover malformed kinds, source/native
locations, conversions, duplicate/missing parameters, overwritten input
registers, frame/offset overflow, stale signature identity/arity, contradictory
representation evidence and source declaration refusals. They also admit a
safe alternative schedule and retain unknown-type defaulting. The probes run
inside the existing export job and the invariants inside the existing Core job.

Across 88 configurations on eight targets, the saved-compiler comparison passes
168 complete root/dependent-unit outputs and cache identities unchanged, plus
25 byte-identical C adapter bodies. The new adapter fixtures intentionally
correct ARC function bodies; independent execution validates that change rather
than asserting equivalence to the saved compiler's panic.

The final fixed-source, fresh-cache Base sweep passes all 136 jobs in 582.59
seconds on six workers, with no reused configurations or timeout changes. The
new probes/invariants execute inside that sweep. Native A64, Rosetta x64/qx64,
RV32/RV64 QEMU, real ARC/raw ownership and the registered runtime oracles pass.
Sol arguments/shared-language checks pass; self/mutual tail calls each finish
three million iterations with an 86 MB reported peak and terminal `TailCall`
bytecode. Source Binary/cache and existing diagnostics checks pass.

The macOS sweep explicitly skips native Linux x64 runtime execution and the
POSIX RV64 artifact check when clang lacks its RISC-V backend. No physical-board
execution is claimed. Local records use `/private/tmp/fpr-export-plans-*`,
including the saved-compiler negative control and full timing JSON.

The preceding native-call checkpoint `871845e` passed
[hosted CI run 40231567763](https://github.com/hyperswine/fprisc/actions/runs/40231567763).
This export/representation stage passed [hosted CI run 40235445898](https://github.com/hyperswine/fprisc/actions/runs/40235445898)
at commit `ce77e9f`.

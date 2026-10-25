# Explicit native word calling conventions

Date: 2026-10-26. Kind: compiler architecture stage and validation record.
Applies to main `4dc7acd` plus this stage. The complete
[compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) remains active.

## Owned call contracts

`Codegen.Calling.Types` separates logical FP-RISC word entries from existing C
runtime entries. The lowering product's local, imported, generated and foreign
callee kinds determine that logical contract; selection combines it with the
explicit fuel policy. Runtime calls cannot accidentally inherit a generated
callee's fuel-reset event through a pair of Boolean arguments.

`Codegen.Calling` owns physical argument placement, result registers and caller
clobbers for A64, x64 and RISC-V. The three selectors use these contracts for
ordinary calls, tail transfers, runtime slow paths and parameter arrival. A64
and RISC-V use eight integer argument registers; x64 uses six registers and
private cells for arguments 7 and 8. All three use hart argument cells for
arguments 9 through 64. Runtime calls use their supported native register bank;
an unsupported wide C call is refused instead of staging private FP-RISC cells
and truncating its register operands.

Every selected direct call/tail transfer retains its full arity, convention and
result mode. Native form checks validate argument/result registers, the complete
caller-clobber set, target/fuel/runtime events and call-versus-tail control
before allocation and after physical placement. The staging verifier checks
exact cell membership, rejects missing/duplicate cells, and prevents a staged
argument from crossing a call, safepoint or control-flow boundary. Allocation
preserves the contract; converting a self tail call to a local loop removes the
transfer and its cell stores together.

x64 argument-cell operands carry `Argument7` or `Argument8`, separately from
linker symbols. The allocator recovers those typed cells when forming self
loops; TLS, borrowed-QOS and Darwin TLV rendering consume explicit hart/argument
roles. The renderer no longer parses a cell name to decide its borrowed offset.

The existing C export trampoline in `Compile.hs`, indirect apply/panic/entry
expansions, general symbol roles and remaining kernel stages are not claimed
as completed by this stage. Existing opcode/form checks still validate the
embedded runtime events. New foreign ABI capabilities, arbitrary C stack/FP
arguments and allocator improvements remain separate work.

## Validation

Selected-instruction invariants cover all three ABIs at arities 0, 6, 7, 8, 9
and 64, with/without fuel, returning/discarded results and tail transfers, over
both virtual and physical operands. Negative cases cover malformed conventions,
unsupported C arities, result/register/clobber/event mismatches and staging
across control/call boundaries. Allocator and typed-IR verifier/evaluator checks
also pass.

The saved-compiler comparison passes all 167 root/dependent-unit outputs and
cache identities across 85 configurations on eight targets, without
normalization. It covers A64 FP pooling, QOS A64, all x64 formats, RV32/RV64,
RVV plugins and builtin ARC/managed-raw/raw-library fixtures. Assembly, native
bounds, allocation statistics and unit keys are unchanged. Codegen revision
120, source AST Binary identity, runtime/context structures and physical ABIs
remain unchanged.

The final fixed-source, fresh-cache Base sweep passes all 136 jobs in 584.39
seconds on six workers, with no reused configurations or timeout changes.
The preceding annotation stage took 584.02 seconds with the same worker count.
Sol argument/shared-language checks pass; self/mutual tail calls each finish
three million iterations with an 85 MB reported peak and terminal `TailCall`
bytecode.

Native A64 C interoperability, segmented stacks, one/four harts, Rosetta x64
and qx64 scalar/QOS oracles, Darwin TLS execution, RV32/RV64 QEMU wide frames,
plugins/RVV and production actor-runtime checks pass. The macOS sweep explicitly
skips native Linux x64 runtime execution and the POSIX RV64 artifact check when
clang lacks its RISC-V backend. No physical-board execution is claimed.

Local records use `/private/tmp/fpr-call-conventions-*.log` and the complete
timing JSON. The preceding annotation checkpoint `4dc7acd` passed
[hosted CI run 40228013834](https://github.com/hyperswine/fprisc/actions/runs/40228013834).
This calling-convention stage passed [hosted CI run 40231567763](https://github.com/hyperswine/fprisc/actions/runs/40231567763)
at commit `871845e`.

# Home-owned private code imports

Date: 2026-10-26. Kind: implemented compiler architecture stage and validation
record. Applies to main `5b52aed` plus this stage. Codegen revision 117.
The full [compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) remains active.

## Reproduced identity defect

A provider defines `produce f x = _ = f x; fn y -> y` and a `home` entry that
calls it. A root calls `produce` with a known callback, calls `home`, and compares
the two returned function objects. The source lambda is the same capture-free
expression in both cases. The saved compiler reports `False` with specialization
enabled and `True` when disabled. Imported callback cloning copied and renamed
the private helper and its static PAP into the root, changing observable pointer
identity. The corrected compiler reports `True` in both modes.

Captured closures still allocate distinct PAPs for distinct constructions, while
an alias retains the same PAP. The regression also checks this distinction and
strict argument/callback effect order.

## Explicit declaration and emission boundary

`Compiler.Native.Imports` derives opaque code declarations from the checked
linked artifact catalog. Each declaration retains its home artifact, source
owner, canonical `CodeId`, and complete capture/parameter/result `CodeContract`.
Its physical arity is the count of capture cells plus ordinary parameters,
independently of the number of logical arrows in the result type.

An opaque `ReadyProgram` attaches the owned erased program, its symbol policy,
actual private imports and reachable read-only templates. Preparation rejects
private definitions copied away from home, missing home definitions, changed
physical arities, absent exports and templates without an imported calling
contract. Scope-aware reference collection does not mistake a shadowing local
for an imported symbol. Imported private arities reach native lowering directly.

`Codegen.Target.Common` owns a typed symbol policy separating public, hidden
implementation and unit-local symbols, plus a shared directive renderer. Hidden
implementation entries are strong even in weak library units. Both the native
function and static PAP use this policy: ELF uses `.globl` with `.hidden`, and
Mach-O uses `.globl` with `.private_extern`. Public export tables and the static
PAP layout retain their existing schema. Existing weak directive conventions
remain unchanged.

Every checked private helper in a home unit has this linkable hidden contract,
independently of the current root's import requests. Unit caching therefore does
not depend on which private helpers a caller happens to need. The actual driver
prepares unit and root emission through this product.

## Read-only optimization context

Checked private code is excluded from imported-helper renaming/copying. Existing
`Mono` clones reference its canonical home label instead. The remaining erased
inliner, vector fusion/nesting and native kernel planning can inspect read-only
private templates, without emitting another ordinary function or static PAP for
them. A focused probe first demonstrated that simply removing copies lost an
imported map kernel; the read-only context restores that optimization.

Kernel implementations built from those templates are unit-local, including the
specialized scalar callback entries. Multiple units may specialize the same home
callback without publishing duplicate kernel symbols. These implementations do
not acquire first-class PAP objects or replace the home function's identity.

Compatibility helpers and helpers introduced by erased region transformations
still use the explicit legacy copied-helper path. Looking through a read-only
checked template preserves the dependencies that path needs. This stage does not
claim those helpers have acquired typed contracts.

## Compatibility and remaining work

Revision 117 versions the corrected identity behavior, new hidden linkage,
local kernel linkage and changed emitted references/cache contents. Physical
native calling conventions, context structures, source AST Binary identity and
runtime object layouts are unchanged. Compiler-owned module/interface ABI stamps
advance with the codegen revision as usual.

The declaration boundary retains checked interfaces; it does not reconstruct
checked bodies from erased templates. Global callback cloning itself still uses
`Mono`, and inlining/fusion/region/worker/reuse transformations still need their
full typed migration. Typed source-clone provenance, imported private code
references in transformed typed graphs, and region/cost provenance remain the
next steps toward retiring `Mono`. The broader diagnostics and machine/call
contract register also remains active.

## Validation

All 136 Base jobs passed in 515.82 seconds on six workers, with a fresh
cache, no reused CI coverage, and fixed compiler/test sources. The suite retains
its explicit platform/toolchain skips: x64 execution is skipped on this Mac;
AArch64 native execution and the registered RV32/RV64 QEMU gates passed.

The expanded invariant checks cover declaration ownership, physical capture
arity, refusing copied/missing/changed home definitions, lexical shadowing and
read-only template contracts. Static-data predecessor goldens remain exact,
including PAP layout, weak/strong conventions, module tables and raw strings;
new policy checks cover hidden code/PAP authority and Mach-O spelling.

The native callback suite checks identity/effects in all existing optimizer
modes, one/four harts, transitive imports and warm mode transitions. The new
fixture checks home-versus-cloned capture-free identity, captured allocation and
alias identity, strict effects, and cached home reuse when the root stops or
starts importing private helpers. Root and provider objects assembled for
A64 ELF/Mach-O, x64 ELF/Mach-O, RV32 and RV64 (Clang for A64/x64 and the GNU RISC-V
assembler for RV). It verifies both code and static PAP are defined only at
home, with the expected hidden linkage. Imported map and fused pipeline native
answers and kernel emission also pass, and kernel copies have local linkage.

Sol argument handling and the shared-language fixture pass. Measured self and
mutual tail calls each complete 3,000,000 iterations at an 85 MB peak; the
bytecode listing ends in TailCall with no Ret after it.

Local records: `/private/tmp/fpr-private-base.{log,json}`,
`/private/tmp/fpr-private-contracts.log`, `/private/tmp/fpr-private-data.log`,
`/private/tmp/fpr-private-callbacks.log`, `/private/tmp/fpr-private-sol-*.log` and
the saved-compiler probe in `/private/tmp/fpr-private-import-probe/`.
No physical board execution is claimed. Hosted validation of this integrated
commit follows the push. The preceding linked-owner baseline at
`5b52aed` passed hosted CI run
[40194815858](https://github.com/hyperswine/fprisc/actions/runs/40194815858).

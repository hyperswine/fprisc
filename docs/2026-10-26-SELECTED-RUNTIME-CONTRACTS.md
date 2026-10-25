# Selected runtime protocols and symbol roles

Date: 2026-10-26. Kind: compiler architecture stage and validation record.
Applies to main `ce77e9f` plus this stage. The full
[compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) remains active.

## Typed references and events

Selected instructions no longer carry `OS String`. Callable entries use
`OCode CodeSymbol`; addresses use `OAddr AddressSymbol`, distinguishing static
objects, code addresses and opaque external addresses. Named x64 argument cells
remain separate `OC` operands. Direct-call constructors accept a code symbol;
an address with the same spelling cannot silently become a call operand.
Renderers erase these roles only when printing linker names. Shared callee
resolution derives callable symbols from the IR's local/imported/foreign/
generated callee kinds. Self-loop formation retains the callable identity.

`Codegen.Call` replaces independent runtime/safepoint Boolean fields with
callee-entry, runtime-C and fuel-exhaustion effects. Accounting predicates
derive from those constructors. Known apply, panic, stack-growth, fuel and
stack-reservation entries have one runtime identity/spelling owner used by
selection, checking and rendering. No native instruction consumer classifies
these events by parsing a helper name.

## Owned embedded protocols

`Codegen.Protocol` owns the entry stack/fuel checks, counted ticks, static
entries, generic apply, panic and pushed-argument contracts. It supplies and
checks runtime events, implicit scratch/argument registers, complete caller
clobbers, result/forwarded parameter constraints, flags and control flow.
Selection, target form checks and final physical validation use that contract.
Entry selection takes explicit stack-and-fuel, stack-only or fuel-only checks;
the absence of checks has its own outcome instead of masquerading as a tick.

Forwarded entry definitions preserve their parameter registers around slow
calls, so the clobber contract excludes those explicit definitions. Existing
entry splitting and shallow-entry rewriting retain the same typed effects;
ISA checkers delegate embedded flag/control expectations to their owner.

Generic apply also has a stream invariant: the pushed head and arguments must
match its count, and no call, safepoint, label or control transfer can split the
staged packet. Allocation may insert ordinary register/slot transfers between
its instructions. Orphaned, missing and excess pushes are compiler errors.
Panic requires a static message object, not a callable entry or code address.

The frame-reservation/TLS assembly expansions remain in their existing target
owners. Their known runtime names now come from typed runtime identities; this
stage does not claim to replace those ABI expansion builders with a new frame
planner. Other source/data/linker interfaces and kernel stages, later typed
Core transformations, compatibility/layout forms and source ranges/diagnostic
producers remain full-goal work.

## Validation

Expanded selected/allocation invariants pass across A64, x64 and RISC-V, over
virtual and physical operands. They cover forwarded entry preservation,
static-entry target restrictions, call effects, missing scratch/clobber data,
apply packet lifetime/counts and code-versus-address confusion. Existing
annotation, save/restore, shrink-wrap, entry splitting, slot placement and
allocation checks pass.

The saved-compiler oracle passes all 170 complete root/dependent-unit outputs
and cache identities across 88 configurations on eight targets, without
normalization. This includes whole corrected ARC bodies and the soft/hard
export fixtures; wrapper-only comparison for the pre-ARC6 ownership regression
is now an explicit opt-in mode. Assembly, native bounds, allocation statistics
and unit keys remain unchanged, so general codegen revision 120, ARC revision
6, source AST Binary identity, runtime/context structures and physical ABIs
remain unchanged.

The final fixed-source, fresh-cache Base sweep passes all 136 jobs in 602.42
seconds on six workers, with no reused configurations or timeout changes.
Sol arguments/shared-language checks pass; self/mutual tail calls each finish
three million iterations with an 86 MB reported peak and terminal `TailCall`
bytecode.

Native A64 C interoperability, segmented stacks and one/four harts, Rosetta
x64/qx64, Darwin TLS, RV32/RV64 QEMU wide frames/plugins/RVV, real ARC/raw/export
and registered actor-runtime oracles pass. The macOS sweep explicitly skips
native Linux x64 runtime execution and the POSIX RV64 artifact check when clang
lacks its RISC-V backend. No physical-board execution is claimed. Local records
use `/private/tmp/fpr-protocol-symbols-*` and the complete timing JSON.

The preceding export/ARC checkpoint `ce77e9f` passed
[hosted CI run 40235445898](https://github.com/hyperswine/fprisc/actions/runs/40235445898).
This selected-runtime stage requires its own hosted result after push.

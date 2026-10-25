# Checked physical region interfaces and provenance

Date: 2026-10-26. Kind: implemented compiler architecture stage and validation
record. Applies to main `38673d2` plus this stage. Codegen revision 118.
The full [compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) remains active.

## Owned region input

`Compiler.Native.Regions` prepares an opaque region program from `NativeCore`.
The product retains that checked native parent, checking namespace, layout
authority, checked nominal model, physical interfaces, shared identities, erased
representation projection and join set. Source and checked private interfaces
retain their actual binders, including capture schemes, unique IDs and ownership
shapes, plus checked result types/shapes and source/code provenance.

Region placement no longer peels logical source types to guess native parameter
types. Hidden layout arguments count as physical arguments; a returned function's
arrows belong to the result. `Core.Calling` records an explicitly supplied
physical count. The declaration producer uses the layout-aware calling schema.

An unchanged compatibility body can retain its checked source declaration,
without acquiring typed body/binder evidence. Clause identity is checked by the
frontend that owns the original source. Changed clauses retain no declaration,
and the region consumer suppresses any same-named interface in its context.
This prevents an erased rewrite from borrowing a formerly checked result type.
The existing signed-recursion assumptions are not strengthened into ABI proofs.

## Type and cost ownership

`Core.Region.Types` classifies copyable/bounded values from checked types,
constructor schemes and linear type names. It substitutes each constructor's
own quantified parameters, handles structural records directly, and distinguishes
recursive copyable values from bounded loop state. `ReceiveTurns` no longer
imports the surface AST/desugarer or converts source type syntax in its backend
analysis. Compiler layout descriptors have explicit bounded value treatment.

A region context retains the exact analysis projection and its derived cost
equations alongside checked measures. Changed/local typed bodies get equations
from their actual projection rather than a name-based borrowed cost. Checked
private code identities can participate in the whole-program effect/cost view.
Compatibility auxiliary counters are scoped separately in local/context analysis
projections, using a shared lexical renamer; emitted names remain unchanged.
Independent `lifted_1` definitions therefore do not become the same graph node.

Representation-identity Layout cast erasure now has one owner in
`Core.Opt.Representation`. The region/cost view and emission use the same
projection. Actual artifact emission and specialization projections consume a
shared placed-region product per artifact, retaining the metadata rather than
re-running placement for its notes and program separately.

## Generated helper contracts

The result records generated loop bodies, loop cycles, receive thunks and receive
joins as distinct roles. Each has a source name/interface, ordered physical
parameters and the state fields its generator handles. The result verifier
checks declaration/emission agreement, helper collisions, preserved original
entries, parameter uniqueness/limits and newly unbound references.

This is provenance and a structural ABI contract for an erased rewrite, not a
claim that generated helpers are already typed Core. In particular, the receive
step's existential `(continue, payload)` protocol is distinguished from its
source function's result. Bookkeeping/body eligibility is decided from explicit
interfaces/helper roles rather than a `$` name test.

Pure loops that would need more than the native 64 physical parameters after
adding their two control cells are explicitly declined. Receive state bundling
retains its existing two-parameter protocol. No runtime structures or physical
calling conventions change.

## Reproduced missing private coverage

The saved compiler cannot place a region around a checked local recursive
receiver: its notes say the private entry has no checked source interface. A
30,000-message regression captures its actor ID, carries string/integer state,
and checks the final result, caller value and a 4 KiB heap bound. The saved
compiler fails with `private receiver grew 196480` on both one and four harts.
The corrected compiler places the receive region and passes the same fixture.
The explicit receive-turn opt-out remains a failing control.

Revision 118 versions the changed region placement/emission/cache contents.
Source AST Binary identity, runtime object/context layouts and native physical
ABIs remain unchanged. Native typed global cloning, typed region helper bodies,
worker/reuse/inlining transformations, remaining compatibility forms, source
diagnostics and machine/call contracts remain full-goal work.

## Validation

Local integrated validation passed on the fixed revision-118 sources:

- `make fpr`, the complete receive-turn suite and the complete typed-Core suite,
  including checked interface/provenance invariants, declaration quarantine,
  layout-context refusal, helper collisions and generated argument limits.
- Fresh-cache `check_base.py -j 6 --times`: all 136 jobs passed in 509 seconds,
  with no reused configurations. This includes native AArch64 execution and
  available RISC-V QEMU checks. Native Linux x64 execution was skipped on this
  macOS host; the POSIX RV64 artifact check was skipped because the available
  clang has no RISC-V backend. Shared emission/IR checks passed.
- Sol argument preservation, the shared native/Sol fixture and three million
  self/mutual tail-call iterations passed (85 MB reported peak).
- Saved-compiler differential: the private receive fixture fails its 4 KiB heap
  bound with 196,480 bytes of growth on one/four harts; the corrected compiler
  passes both. Disabling receive turns remains a failing control.

The private-import baseline `38673d2` passed
[hosted CI run 40198814856](https://github.com/hyperswine/fprisc/actions/runs/40198814856).
That result precedes this stage. The integrated region-interface commit
`bd2830b` also passed [hosted CI run 40205756522](https://github.com/hyperswine/fprisc/actions/runs/40205756522).
No physical-board execution is claimed by these checks.

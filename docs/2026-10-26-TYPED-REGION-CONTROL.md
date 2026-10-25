# Typed region control

Date: 2026-10-26. Kind: compiler architecture stage and validation record.
Applies to main `134a992` plus this stage. Codegen revision 120.
The full [compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) remains active.

## Checked bodies and internal control sorts

Region placement now publishes an owned typed control program before emitting
its Core projection. `Core.Region.Syntax` distinguishes ordinary checked value
parameters from region marks, sequence cells, receive ticks and state bundles.
A receive helper returns an internal receive-step sort carrying its checked
source result type. Existential continuation/state packaging does not pretend
to have a source tuple or function type.

`Core.Region.Flow` retains typed expressions, binders, patterns and guards while
making protocol tail calls explicit. Calls retain their checked witness and
derive their physical operands from it, including hidden captures. Generated
functions receive fresh binder identities and retain the ordered mapping from
their source parameters. The renderer preserves argument evaluation even when
an argument is forwarded into a dead state slot.

Receive state bundles retain each live field's complete scheme. Dead logical
slots have no typed runtime value; their erased placeholder is allowed only
under the planner's liveness proof. Source types are never reconstructed from
rewritten erased helpers. Unchanged source definitions reuse their immutable
checked parent projection.

## Verification and ownership

`Compiler.Native.Regions.Typed` owns construction, checked helper rewrites and
emission. `Compiler.Native.Regions.Verify` checks the complete graph: source
ownership and parameter provenance, globally unique emitted binder identities,
physical banks and internal sorts, target roles and arities, state schemas,
explicit tail structure and lexical scope. Control cells cannot capture a
language symbol or protocol helper. Typed code identities and call-region hooks
also refuse erasure under a conflicting local spelling.

Changed helper bodies must remain well typed under the checked parent program.
An alpha-equivalent checker projection retains the original planner proof.
Other changes recompute liveness, invariance, receive/region effects,
non-returning behavior and the boundary cycle condition before publication.
Making a dead parameter observable or weakening an invariant argument cannot
silently keep an old state-packing contract.

Typed protocol helpers enter the linked declaration catalog with their home
artifact, source owner, code identity and internal contract. Native code and PAP
visibility use the existing home-owned private-symbol policy. Imported helpers
are not copied into a caller by the remaining erased specializer.

## Explicit remaining boundary

The existing region planner still computes placement and costs on a scoped
Core analysis projection. Its liveness/invariance/non-return analyses now live
in `Core.Region.Analysis`; the placement policy is unchanged. A group containing
an untyped compatibility definition remains wholly on the compatibility
rewrite. Checked groups use the typed control renderer.

`Mono` is restricted to the remaining compatibility definitions/helpers.
Compatibility forms, layout temporaries, later inlining/fusion/workers/reuse,
parser ranges and machine/call contracts remain full-goal work. This stage does
not retire those passes or complete the compiler cleanup.

Revision 120 versions changed emission and cache contents. Runtime structures,
context switching, physical ABIs and source AST Binary identity are unchanged.

## Compile-time check

A fresh-cache compile of `examples/ideal/todo.fpr` took 11.90 seconds with the
saved revision-119 compiler and 14.71 seconds with this stage. An initial
21.27-second result exposed a repeated whole-world call-target scan; the planner
now queries only names referenced by each function while sharing the candidate
set. The remaining verification overhead is recorded rather than hidden by
larger test timeouts. These are compile-regression probes, not statistical
kernel-performance measurements.

## Validation

The expanded `RegionInterfaces.hs` invariant checks pass, including malformed
sorts/banks, state-scheme mismatch, dead-slot and invariant-proof invalidation,
source-equivalent helper rewrites, call witness scope, protocol/language symbol
capture, foreign planner input and typed-helper home declarations. A typed loop
projection is alpha-equivalent to the existing representation oracle. Focused
receive, typed-Core and loop-state suites passed during implementation.

The final fixed-source, fresh-cache Base run passed all 136 jobs in 572.64
seconds on six workers, with no reused configurations and unchanged timeouts.
The preceding stage took 540.74 seconds under the same worker count. Coverage
includes the expanded region-control invariants, native receive/loop state,
one/four-hart execution, private imports and callback identity, strict effect and
trap order, warm-cache transitions, complete applications, allocation/reuse
ratchets and registered RV32/RV64 QEMU execution.

Native Linux x64 execution is skipped on this macOS host. The POSIX RV64
artifact check is skipped because the installed clang lacks its RISC-V backend;
shared IR/emission checks and the registered QEMU gates pass. No physical-board
execution is claimed.

Sol argument preservation and the shared-language fixture pass. Self and mutual
tail calls each complete three million iterations in bounded memory, with a
reported 86 MB peak and terminal `TailCall` bytecode.

Local records are `/private/tmp/fpr-typed-regions-complete.{log,json}`,
`/private/tmp/fpr-typed-regions-invariants.log`, the
`fpr-typed-regions-sol-*.log` files and the `fpr-regions-perf-confirm-*` compile
probes. Earlier implementation checks do not substitute for this complete run.

The preceding global-cloning commit `134a992` passed
[hosted CI run 40210518302](https://github.com/hyperswine/fprisc/actions/runs/40210518302).
This stage still requires its own hosted validation after push.

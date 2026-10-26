# Checked Base inlining before erasure

Date: 2026-10-26. Kind: compiler architecture stage and validation record.
Applies to main `0b41312` plus this stage. The full
[compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) remains active.

## Owned transformation

`Core.Typed.Inline` copies checked expression trees, retaining annotations,
ownership shapes and source origins. `ContractInstance` exposes the checked
freshening and solution used by code-call verification: caller variables stay
rigid and a capture's local forall cannot escape into the ordinary interface.
The existing instantiator applies those substitutions and clones every lexical
identity. No optimized erased body is inferred again.

The pipeline owns bounded rounds and a shared immutable catalog per round.
All inputs agree on checking namespace/layout authority. Elided constructor
stubs have one emitting template owner, even when visible in several inputs.
Each changed closed program is checked before publication. Root parameter
identities/types and entry arities stay fixed; display names become hygienic
where copied globals would otherwise be captured during erasure.

Eligibility uses the catalog's complete strongly connected components,
including source entries and private code/join references. Recursive wrappers
cannot be copied into their own generated join. A direct-self-reference test
alone missed that cycle and moved clause/case receive loops away from their
checked entry; the existing heap-bound fixture caught the resulting growth.
Mutual recursion and generated joins now have explicit cycle regressions.
The reproduced fixture retained 5,760,640 bytes with the direct-reference
guard. With full cycle exclusion it passes its original below-4-KiB retention
and zero-root-growth assertions on both one and four harts. The receive-region
note assertions remain unchanged.

Imported private code keeps its original code identity, contract and emitting
home. Inlining does not manufacture new PAP definitions. Linker-private source
globals cannot leak through a copied template: a body depending on another
artifact's private source entry remains a call unless earlier owned rewriting
has removed that dependency. Link validation runs again after the transform.

## Effects, captures and scheduling

Ordinary arguments are evaluated once, left to right, before the copied body.
Known function values may replace parameters only when no lexical capture
slot or staged match needs that binder. CAFs, effectful values and captured closure construction
retain their strict bindings. Code-call captures are already evaluated lexical
references and retain their checked schemes, including polymorphic captures.

Lexical call resolution additionally recognizes construction evidence for a
static capture-free closure. Its object has no owned environment to duplicate.
An arbitrary function parameter, a closure with an unknown/owned environment,
or a stored partial application still requires the existing generic path;
the arrow type alone does not establish unrestricted ownership.

The second callback pass can trim an unused callback parameter forwarded
through a lexical alias into a staged match. Cleanup now removes an unused
irrefutable match slot consistently with liveness before removing that formal.
The regression verifies both input and output scopes; scope checking stays
strict. Errors identify which callback/inlining stage rejected the graph.

`EntryTick` is an explicit Unit-typed effect, inserted after arguments and
before each copied entry body. Erasure renders the one compatibility spelling
owned by `Core.Primitives`; native lowering emits the existing safepoint.
Cost/region analysis knows the tick has scheduling work and zero actor
allocation. Introducing an entry tick cannot turn a nonallocating loop into
an opaque allocating one.

Region placement also carries per-caller saturated-application facts.
A scoped recursive checking assumption may leave an occurrence less precise
than the callee's published result. Such an occurrence cannot inherit a
copyability proof from that declaration alone after inlining changes the call
graph. All typed occurrences of a selected target in a caller must have
copyable results; the erased plan and typed reconstruction use the same gate.
Missing checked sites are denied. Compatibility bodies retain an explicit
declaration-only boundary. The call-region verifier remains strict.

## Pipeline and compatibility boundary

Base performs checked callback specialization, checked inlining, another
checked callback pass for newly exposed values, then region placement and
erasure. `FPR_NO_INLINE=1` disables inlining as before. The erased compatibility
inliner cannot edit checked owners or use checked entries as templates. Its
unscoped Base entry points are retired; the untyped staging oracle explicitly
uses the compatibility entry point. ARC retains its post-ownership inliner.

This moves Base inlining, not all later optimization, across erasure.
Typed ARC rewriting, vecPeek, fusion/workers/normalization/reuse, remaining
compatibility/layout forms, source/data/linker contracts and diagnostic
ranges/producers remain full-goal work.

Inlining before region planning and hygiene can change optimized bodies,
placement choices and dependent-unit identities. Codegen revision **121**
intentionally invalidates older executable/module caches and interface stamps.
ARC revision 6, source AST/Core Binary formats, runtime/context layouts and
physical calling conventions stay unchanged. QOS derives its codegen admission
stamp from the compiler source; images from this revision need a matching
rebuilt host. No new foreign ABI is introduced.

## Validation

The existing typed-program test process runs the new inliner invariants and
independent machine-IR evaluator comparisons, including admitting large-budget
polymorphic capture cases, strict unused-argument traps, fuel counts,
allocation/trap order, hygiene, imported closure homes and constructor elision.
Existing ownership and stored-partial negative cases remain required.

The existing Base on/off fixture also exercises F64/F32 and linear arguments.
The optional `check_typed_inline.py --against SAVED_FPR` oracle runs saved/new
compilers with inlining on/off and one/four harts, then all eight native
emission targets and distinct cache revisions. It adds no umbrella job.
The saved revision-120 and new revision-121 binaries pass all eight runtime
comparisons and 32 emission configurations. QOS rebuilds its real hosted
runtime, application and plugin against revision 121: the application returns
55, the plugin returns 42, and an executable-page range extending beyond the
image is refused without crashing the host.
The final QOS check uses an empty unit cache. Sol arguments and the shared
language fixture pass; measured self and mutual tail calls each complete
3,000,000 iterations with an 86 MB reported peak and a terminal `TailCall`.

The native-backend fixture checks every source entry and all emitted native
metrics. Its counts follow emitted entries, allowing checked specialization to
add private entries. Finite-bound, refusal, arithmetic/trap, native-only and
assembly checks remain required.

The pending-stack reset fixture runs both normal optimization and an explicit
non-inlined build. Earlier inlining can collapse its ten-wrapper chain before
region placement. The non-inlined variant must still report stack growth past
the eight inline pending slots; both variants must preserve all three computed
results across the reset on one and four harts. Its original grown-stack safety
coverage is retained explicitly rather than relying on optimizer placement.

The preceding main `0b41312` passed
[hosted CI 40243385596](https://github.com/hyperswine/fprisc/actions/runs/40243385596).
That proves the preceding kernel stages, not this inliner. The fixed-source
full suite and this stage's hosted status follow below.

The final fixed-source fresh-cache Base sweep passes **136/136 jobs in
666.50 seconds on six workers**, with no reused results or timeout changes.
All receive-region note/heap/ownership assertions pass unchanged, including
the opt-out heap-growth reproductions. The pending-stack test proves its
deliberate grown-stack case and normal optimized behavior. The preceding
record-plan checkpoint recorded 596.98 seconds; these are elapsed suite runs,
not a paired compiler-performance benchmark.

The sweep includes independent AArch64 execution, Rosetta x64/QOS emission
oracles, RV32/RV64 QEMU execution, IEEE/vector cases and real actor-frame tests.
Explicit host/toolchain skips remain: native Linux x64 execution in the
matching-host suites and the POSIX RV64 artifact check where this clang lacks
that backend. No physical-board validation is claimed. This stage still needs
its own hosted result after push, and the complete cleanup goal stays active.

Local records: `/private/tmp/fpr-typed-inline-final4.{log,json}`,
`/private/tmp/fpr-typed-inline-oracle-cycle.log`,
`/private/tmp/fpr-typed-inline-qos-loader-fresh.log` and
`/private/tmp/fpr-typed-inline-sol-final.log`. Earlier failed sweeps remain
failure evidence and are not counted as passes.

Hosted follow-up: [run 40255244633](https://github.com/hyperswine/fprisc/actions/runs/40255244633)
for `5ac6b4d` failed when the POS application compilation exceeded its existing
180-second limit. The arithmetic oracle passed first; this checkpoint is not
hosted-green. [The next checked-pass stage](2026-10-26-TYPED-VECTOR-READS.md)
records the shared-catalog fix and isolated before/after compilation evidence,
with the original timeout retained.

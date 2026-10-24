# Checked inference handoff

Date: 2026-10-25. Kind: implementation record. Applies after `3be6efa`,
as part of the [compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md).

## What this stage preserves

`Infer.Result` owns a named inference result. Native compilation consumes it
instead of unpacking the six-element compatibility tuple. A successful checked
run retains the inferred declaration schemes, inferred linearity signatures,
interfaces, rewritten surface program, vector layout requirements, operator
resolution choices and source checking evidence together. The existing tuple
APIs remain projections for Sol and compatibility callers.

`Infer.State` owns inference state and lexical context. `Infer.Trace` records
what the existing inference algorithm checks; it does not run a second checker
over the rewritten program. `Infer.Evidence` records each expression's final
type, enclosing declaration, source offset, local environment and reference
identity. Clause, lambda, local, pattern and guard bindings receive distinct
`Core.Identity.BinderId` values from a supply independent of inference's type
variables. Shadowed spellings receive separate identities; a recursive local
retains the same identity when its placeholder scheme is generalized. A
namespace supplied by the compilation unit distinguishes independent runs.

`Infer.Elaboration` owns the operator target vocabulary and records each
resolved site's checked type, target and originating expression occurrence.
This preserves decisions needed when lowering stops using surface markers.

Final substitutions apply to the retained types. Quantified schemes are first
alpha-renamed in an isolated solver state: applying a substitution directly to
their bodies would confuse bound scheme variables with solver metavariables.
Snapshotting does not advance the checking run's counters or change diagnostic
type-variable numbering. Detached type snapshots and strict context projections
avoid retaining old solver states through deferred field access.

The evidence builder seals only completed checking occurrences with valid local
references, matching namespaces, owners, spellings and scope identities. Native
compilation refuses an invalid handoff before surface lowering. Programs with
type errors or unresolved named holes do not receive sealed evidence.

## Limits and the next consumer

This is evidence for source checking occurrences, **not typed Core**. Inference
may check a synthesized expression more than once, so occurrence identity is
not a permanent source-node identity. The recorded source is before elaboration;
the generated layout parameters, hole wrappers, specialized clones, joins and
region helpers still need typed construction and identity-preserving lowering.

The type-derived ownership shapes are not a proof that every resource is used
once or that every capture is safe. The existing linearity checker still owns
those checks. `Core.Syntax` remains string-named and untyped, and the Core
optimizer's structural result is not a full type/scope proof.

The next migration must consume this evidence in typed surface-to-Core lowering,
make generated binders/types explicit, and carry the checked result through
Core transformations. Re-inferring optimized untyped Core would not satisfy the
goal. Retaining this handoff alone does not complete the cleanup.

## Validation

`tests/check_inference_evidence.py` checks shadowing, captures, recursive local
identity, tuple/guard bindings, final float types, owned parameter shapes,
polymorphic type and row schemes, elaboration origins and named-hole/type-error
refusals. It also constructs malformed builder inputs to check unfinished,
out-of-scope, cross-owner and cross-namespace refusals. The checked result's
compatibility projection matches ordinary inference, including diagnostics,
schemes, type-variable IDs, holes, rewrites and interface identities.

Full Base passed **133 jobs in 422.37 seconds on six workers**, with no reused
CI coverage. Three existing host/toolchain-dependent subchecks explicitly
skipped; the native, portable and installed cross-target checks passed.

Fresh output directories matched the saved pre-frontend compiler at `04206f1`
for **128 root and dependent-unit assembly comparisons**, including unit keys,
across RV32, RV64, A64, A64mac, x64, x64mac, qx64 and qa64. These cover default
and worker/reuse-disabled configurations plus selected fusion-disabled cases.
This is cumulative emission evidence for both the frontend and inference
refactors, not a claim that every program is covered.

Sol's argument and shared-language fixtures passed. Its measured self and
mutual tail calls each completed 3,000,000 iterations under the memory guard
(peak 86 MB), with the listing ending in TailCall rather than Ret.

Local records: `/private/tmp/fpr-evidence-base.{log,json}`,
`/private/tmp/fpr-evidence-final-parity.log` and
`/private/tmp/fpr-evidence-sol-{args,both,tail}.log`.
Existing runtime/ABI/cache formats are unchanged by this stage; no
physical-board execution is claimed.

## Compiler cost sanity check

After Base finished, an isolated archive of the exact parent `3be6efa` was
built with the same default Make/Cabal configuration. Each comparison used a
fresh output/unit directory, `--target=a64mac` and the same source/library tree.
Three scalar pairs alternated order; medians were 0.66 → 0.63 seconds elapsed,
0.59 → 0.58 seconds CPU and 144 → 157 MiB peak RSS. These short timings are
too small/noisy to claim a speedup.

One bounded cold POS pair (`examples/pos1.fpr`) took 23.53 → 24.00 seconds
elapsed and 23.32 → 23.73 seconds CPU; peak RSS was 981 → 1,064 MiB. This is
a roughly 2% time and 8.5% memory cost in that pair, not a performance gate or
proof for all compiler workloads. Retained source facts and the old untyped
lowering coexist during migration. The typed-Core consumer should replace that
duplication; it must not silently discard the preserved facts to recover space.
Records: `/private/tmp/fpr-evidence-parent-perf{.log,/results.json}`.

## Follow-up consumer

[The first native typed-Core lowerer](2026-10-25-TYPED-CORE-LOWERING.md) now
consumes these facts for its covered expression forms and verifies types,
scope identities and ownership-shape consistency. The rest of source lowering
and the transformations after its explicit erasure boundary are still pending.

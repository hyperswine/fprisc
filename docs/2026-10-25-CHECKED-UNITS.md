# Checked unit ownership and cache inputs

Date: 2026-10-25. Kind: implementation and validation record.
Applies after typed generated traps at `37253eb`.

Native prelude and dependency units now consume owned projections of the
merged source-checking result. The compiler no longer runs a second inference
pass over a unit plus prelude, discards its errors and pairs its rewritten
bodies with plans from a different checking run. Eligible unit definitions
retain their actual inferred types, binder identities, layout evidence and
closure contracts through the same checked lowering used for root entries.

## One producer, explicit owned inputs

`CheckedPlans` retains its exact elaborated source clauses. Its private
`CheckedUnit` projection selects definition owners, rejects absent names and
keeps those clauses attached to their plans. Native compilation consumes the
opaque product; callers cannot replace its bodies while retaining its proof.
An empty unit is valid. Unsupported source forms retain their explicitly
declined compatibility lowering; the projection does not claim that those
forms have become typed.

Physical global call arities come from the same elaborated source result,
including hidden layout arguments and root-owned entries referenced by a unit.
Prelude and dependency emission use that global context. Surface specialization
clones remain owned by the root's compatibility path until specialization
itself preserves typed contracts. The existing stale-plan equality gate remains
in force for arbitrary transformed source input.

## Lowered-input cache identity

Unit source, prelude and shape identities do not describe every decision made
from a merged checking context. `Core.CacheIdentity` owns a versioned `core1`
fingerprint of the actual lowered program before native optimization, together
with its referenced external global/primitive call arities. Global and primitive
classification is distinct. Equal logical types can require different code for
a flat entry and a curried entry with fewer physical parameters.

The fingerprint retains reachable elided constructor stubs transitively because
the inliner can read their bodies. It omits unreferenced elided stubs and
unrelated external contracts, so unrelated root declarations do not invalidate
reusable unit code. Lexically bound names are not external dependencies. Existing
target/options/contract identities and atomic cache writes remain in place.
The cache key covers receive-region decisions already present in the lowered
program; no types are reconstructed from that program.

The corrected checking/code generation and unit cache filenames advance the
codegen revision from **110 to 111**. Native calling conventions and runtime
memory/context structures are unchanged. Source parser Binary formats and
module content hashes are unchanged; the new fingerprint versions its private
use of existing Core Binary data.

## Independently reproduced failures

The saved `37253eb` compiler accepts merged checking of a client that adds two
F64 values returned by a transitive import. Its unit-local inference cannot
see that dependency's type, defaults the operation to Int, and native execution
panics with an integer overflow. The new compiler prints **5** for two returned
values of 2.5.

Adding a captured recursive local to that client exposes a second failure:
the saved compiler refuses the unit's generated `$localVector.loop` reference
as an unknown primitive. The checked projection retains the recursive binding's
identity and typed closure conversion. The new compiler prints **2.5** for the
local call. These are explicit correctness corrections, not normalized-away
differences in an emission comparison.

## Validation

`tests/TypedUnits.hs` checks owned clauses, missing-owner refusal, empty units,
typed recursive products and composition of separately lowered units with exact
machine-IR evaluator answers. It checks cache sensitivity to operations, call
arity/classification and transitive constructor bodies, plus independence from
unrelated declarations and lexically shadowed names.

`tests/check_typed_units.py` executes transitive F64 and recursive imports on one
and four harts. One shared cache exercises Float/Int root contexts, return to an
earlier context, unrelated root types/functions, and flat/curried calling-arity
transitions. It checks both fixed native answers and file identity/mtime reuse.
Portable x64/RV32/RV64 emission also passes; the new fixture's execution proof is
host-native A64. These checks run under the existing bounded Core job without
an extra compiler build or a new pool of workers.

The focused Core suite passes. The frozen-tree sweep passed **all 136 Base
jobs in 452.84 seconds on six workers**, with no reused CI coverage. The expanded
Core job took 41.7 seconds. Platform/toolchain subchecks retain their explicit
execution or skipping evidence; no physical-board validation is claimed.

Saved/new controls agree on the fixed dictionary/capture and vector-layout
answers. These controls are separate from the two explicitly reproduced
import failures above. Sol argument/shared-language compatibility and bounded
tail calls pass: 3,000,000 self/mutual iterations, peak 85 MB, with TailCall and
no following Ret. Hosted validation of this integrated checkpoint follows push.

Local records: `/private/tmp/fpr-units-build.log`,
`/private/tmp/fpr-units-contracts.log`, `/private/tmp/fpr-units-native.log`,
`/private/tmp/fpr-units-focused.log`, `/private/tmp/fpr-units-base.{log,json}`
`/private/tmp/fpr-units-control.log`, `/private/tmp/fpr-units-sol-{args,both,tail}.log`
and `/private/tmp/fpr-unit-probe/{before,after,float-before,float-after}-{build,run}.log`.
The saved combined-case compiler refusal has no run log because no executable
was produced.

## Remaining full-goal work

Surface and Core specialization, computed recursive initializers, remaining
generated forms, typed layout temporaries and optimization/worker/reuse/region
transformations still require evidence-preserving products. Full lint, remaining
diagnostic/span producers, machine/calling-convention contracts and obsolete
architecture references remain required. This stage does not complete the
compiler cleanup goal.

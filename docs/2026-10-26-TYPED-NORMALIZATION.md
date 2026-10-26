# Checked Base normalization

Date: 2026-10-26. Kind: compiler architecture stage and validation record.
The complete [compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) remains active.

`Core.Typed.Normalize` owns literal/local-alias elimination, strict let sinking
and let/conditional commuting in checked closed functions. It transforms roots
and their local code together, preserves checked types, ownership shapes and
surviving binder identities, and verifies the complete closed graph before
publishing a new linked product. It never re-infers an erased expression.

The driver runs it after checked inlining and vector-read planning, before
region planning and erasure, under the existing 64-bit Base reuse policy.
`FPR_NO_REUSE=1` disables it along with the later reuse optimization. ARC/raw
retain their existing pipeline. Codegen revision **123** invalidates optimized
artifacts and QOS admission stamps; ARC revision 6, source/Core Binary formats
and physical/runtime ABIs remain unchanged.

Only literals and local aliases disappear. Global references, including CAFs,
remain strict. Pending bindings can sink into the next consuming RHS only when
no later reference remains, preserving effect, trap and entry-tick order.
A canonical occurrence ledger transfers alias uses and debits their target
when subsequent expressions consume them. Alias replacement retains each use's
instantiated type and checks compatibility with the target binder's scheme.

`Core.Typed.Walk.pinnedLocals` shares lexical-snapshot requirements between
inlining and normalization: closure/direct-code captures, staged match
scrutinees and pair-free vector handles remain locals. Rewrites also decline
ambiguous display spellings and hoists over explicit or layout-generated
global names, because the current compatibility printer still uses spellings.
Vector-producing bindings also remain explicit for the late fusion pass; this
is a documented migration boundary rather than a new fusion representation.

The late erased normalizer remains responsible for generated/layout scaffolding.
This stage does not retire that boundary. Typed ARC, fusion/workers/reuse and
the remaining interface/diagnostic work are still required by the full goal.

## Validation

The typed-program job checks real alias removal and strict dead-binding
retention, stable interfaces/code homes, no new binder identities and
idempotence. Its independent native-IR evaluator compares 98 input cases,
including values, traps, allocation fields and entry-tick order. It covers
polymorphic aliases, linear data, captures, CAFs, staged matches and vector
snapshots, with an explicit display-shadowing regression.

The existing native typed-Core job adds a normalization fixture exercising
ordinary/captured/polymorphic values, a CAF and strict trap ordering with one
and four harts. No new umbrella test job is introduced.

The preceding vector-read checkpoint `d14fe58` passed
[Linux hosted CI](https://github.com/hyperswine/fprisc/actions/runs/40260883874),
including the existing POS compile timeout. This normalization checkpoint
requires its own hosted result after push.

Saved revision-122/new revision-123 compilers pass **16 native executions,
32 trap-order checks and 64 emission configurations** across AArch64,
x86-64, RV32/RV64 and QOS A64/x64 targets. Reuse and inlining each run on/off;
native executions use one/four harts. Emission success is not execution proof
for the nonhost targets. Fresh unit caches remain separated by codegen revision.

Local records: `/private/tmp/fpr-typed-normalize-unit.log`,
`/private/tmp/fpr-typed-normalize-unit2.log`,
`/private/tmp/fpr-typed-normalize-oracle.py` and
`/private/tmp/fpr-typed-normalize-oracle-final.log`.

The first full sweep stopped at the original `vecfuse` diagnostic assertion:
let sinking hid a vector-producer chain from the late fusion pass. Its POS
core/reload checks had passed, but the sweep is not counted as green. Keeping
vector bindings explicit restores the original refusal diagnostic, two-pass
effect order and zero-allocation pure F64/Int fusion checks. These checks and
the original inlining/vector-read jobs pass in the focused rerun. A typed
regression also checks that normalization preserves vector-producer identities.

After the fix, fresh-cache QOS host/application/plugin rebuilds pass normal
loading and malformed executable-page-range refusals. Sol argv and the shared
language fixture pass; three-million-iteration self/mutual tail calls pass at
an 86 MB reported peak. Local records:
`/private/tmp/fpr-typed-normalize-qos.log` and
`/private/tmp/fpr-typed-normalize-sol.log`.

The final fixed-source, fresh-cache Base sweep passes **136/136 jobs in
667.98 seconds on six workers**, with no reused configurations or timeout
changes. The original fusion diagnostic/order/allocation assertions pass;
2,000 pair-free vector reads still allocate 96 bytes versus 96,096 without
planning. POS core passes in 139.10 seconds and POS reload in 306.09 seconds
as whole jobs in the parallel sweep, retaining their existing per-compile
timeout gates and quantity/cash/allocation contracts.

The sweep includes native AArch64, Rosetta x64 and RV32/RV64 QEMU execution.
Existing explicit skips remain for native Linux x64 actor execution on this
host and the POSIX RV64 artifact check where this clang lacks that backend.
No physical-board run is claimed. Full local records:
`/private/tmp/fpr-typed-normalize-final.{log,json}`. The entire compiler
cleanup goal remains active, including its required hosted validation.

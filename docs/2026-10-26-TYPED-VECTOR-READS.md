# Checked pair-free vector reads

Date: 2026-10-26. Kind: compiler architecture stage and validation record.
Applies to main `5ac6b4d` plus this stage. The complete
[compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) remains active.

## Owned transformation

`Core.Typed.VectorRead` plans an immediately destructured `Vec.at`, `Vec.get`
or `Vec.len` read on an evaluated local Vector. `Core.VectorRead` owns the
operation constructors, source names, physical adapter names and arities.
The checked RHS retains its logical pair type, ownership shape, source origin
and operands; its tuple pattern and body keep their original binder identities.
Closed local code is transformed alongside the root, and the complete product
is verified before publication and relinked before region planning.

`VectorReadPair` is valid only as the immediate RHS of a two-field tuple-pattern
binding. Verification checks the index arity/types, local handle and Vector
element type, exact logical pair result, pattern types and lexical scope.
An escaped pair-free result or malformed operation cannot reach erasure.
Whole-pair bindings, escaping pairs and computed handles retain ordinary reads.

Erasure emits the audited pair-free adapter, matches the returned value and
binds the original handle. A fresh physical alias keeps the original handle
available even when an element pattern shadows its display spelling. Index
expressions run once before the read; nested value patterns retain their
checks and the original pattern-failure diagnostic. Ordinary and region-flow
pattern bindings use the same lowering owner.

This removes the erased `vecPeek` entry point for checked source and region
owners. The explicitly protected compatibility adapter remains for definitions
whose frontend forms have not migrated. The rollout option still disables both
paths, independently of inlining. ARC/raw bypass this Base-only optimization;
their ownership rewrite still requires a broader typed layout boundary.

The removed allocation is the `(value,handle)` wrapper. A float or product
element may still require boxing or row construction in `runtime/vec.c`.
The compiler does not infer that all pair-free reads allocate zero bytes.

## Compatibility and remaining work

Planning precedes region analysis and can change physical temporary/call graphs,
so codegen revision **122** invalidates older optimized artifacts and QOS
admission stamps. ARC revision 6, source/Core Binary formats, physical call
conventions and runtime context layouts remain unchanged. QOS images need a
host rebuilt against the matching compiler revision.

Remaining layout temporaries, typed ARC, fusion/workers/normalization/reuse,
compatibility forms, source/data/linker contracts and diagnostic producers/
ranges remain required by the full cleanup goal.

## Validation

The preceding inlining checkpoint's
[Linux hosted run](https://github.com/hyperswine/fprisc/actions/runs/40255244633)
failed when the real POS application exceeded its existing 180-second compile
limit. Its arithmetic oracle passed first. That checkpoint is not recorded as
hosted-green. The first local sweep for this stage was interrupted to address
the compile-time regression; it is not counted as a pass.

Local phase profiling attributed roughly 13 CPU seconds to each callback pass,
7 to checked inlining and 2 to vector-read planning. The linked callback driver
now owns one shared snapshot per pass instead of rebuilding the whole catalog
for each artifact. Constructor elision chooses a unique emitting template owner
while each artifact keeps its original stubs and root identities. Existing
clone/source/parameter checks and relinking remain required. A differential
unit check compares shared results with the separate-catalog facade.

Inlining admission is also cached once per round, with budget-bounded weighing.
Hygiene records only changed spellings and preserves unchanged binders/trees.
Temporary pass timing instrumentation was removed before production validation.
The initial admission-only change preserved all 61 POS assembly files/cache
identities but did not materially reduce allocation; it is not claimed as the
timeout fix. Sharing catalogs reduced the isolated cold compile from 87.02 to
69.61 seconds and heap allocation from 149.1 to 131.9 GB, with all 61 outputs
and unit identities byte-identical. The final isolated compile takes 69.09
seconds and allocates 131.6 GB through the Haskell heap (maximum sampled
residency 2.29 GB), with all 61 outputs and identities still byte-identical.
Binder sharing is a small additional allocation reduction; the main measured
improvement comes from sharing catalogs. These are sequential cold-cache
measurements on this host; the Linux 180-second gate still needs hosted proof.

The existing typed-program process runs scoped-plan and malformed-contract
checks, whole-pair/computed-handle refusals, closed local-code coverage,
idempotence and stable entry/binder identity checks. A deliberately colliding
display spelling exercises handle reuse through the independent native-IR
evaluator with explicit primitive stubs; real runtime coverage remains separate.

The first focused native run passes the original allocation oracle: 2,000
integer reads allocate 96 bytes with planning and 96,096 without, with the
same values and out-of-range trap. Receive-region, vector-layout and scalar
pipeline checks pass.

The final saved revision-121/new revision-122 oracle passes **16 executions,
80 trap checks and 64 emission configurations** across eight targets. Planning
and inlining each run on/off, with one/four harts. F64/F32, nested products,
records, computed handles, index effects, range/pattern failures, index traps
and ignored-value bounds checks agree. Unit cache revisions remain distinct.
The new real-runtime cases also run in the existing typed-Core job; no new
umbrella job is added.

Fresh-cache QOS host/application/plugin rebuilds pass normal loading and the
malformed executable-page range refusal. Sol arguments/shared-language and
three-million-iteration self/mutual tail calls pass with an 86 MB reported
peak. The final fixed-source Base and hosted results follow after verification.

The final fixed-source fresh-cache Base sweep passes **136/136 jobs in 657.10
seconds on six workers**, with no reused configurations or timeout changes.
`check_pos_core.py` passes in 139.66 seconds total under the parallel sweep;
`check_pos_reload.py` passes in 300.04 seconds. Those job totals are distinct
from the isolated single-compile measurements above. Original receive-region,
allocation and pending-stack assertions remain required and pass.

The sweep includes native AArch64, Rosetta x64, RV32/RV64 QEMU, real ownership
and actor-frame execution. Existing explicit skips remain for native Linux x64
execution on this host and the POSIX RV64 artifact check where this clang lacks
that backend. No physical-board execution is claimed. This revision requires
its own hosted result after push; the full compiler cleanup goal remains active.

Local records: `/private/tmp/fpr-typed-vector-read-final.{log,json}`,
`/private/tmp/fpr-typed-vector-read-oracle-validated.log`,
`/private/tmp/fpr-typed-vector-read-qos-final.log`,
`/private/tmp/fpr-typed-vector-read-sol-final.log` and the isolated measurements
and complete emitted files under `/private/tmp/fpr-typed-vector-read-perf/`.

Hosted follow-up: `d14fe58` passed the
[Linux run](https://github.com/hyperswine/fprisc/actions/runs/40260883874),
including the unchanged POS compile-time gate. This resolves the hosted
confirmation required above; it does not complete the full compiler cleanup.

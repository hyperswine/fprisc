# Sol cache completion and incremental REPL checking

Date: 2026-11-02. Local macOS arm64 measurements, starting at `e085e87`.

## Completed cache work

The pending changes now build and pass their differential checks. Sol resolves
trusted library paths on demand, keys compiled scripts with the root source and
ordered SHA-256 import stamps instead of the expanded import AST, and reuses
verified library record-shape artifacts. Transitive imports are still resolved
before cache lookup. Alias, resolved path, content, trust, compiler identity,
prelude and compiler options remain part of cache identity. The artifact schema
is now 8; old artifacts are disposable misses.

Validation found and corrected two problems in the pending implementation:

- A `Maybe` comparison required an unavailable `Eq STop` instance; use an
  explicit presence test.
- Library verdict establishment stopped before lowering. A library can pass
  inference but fail record-layout/lowering without application shapes. Verdicts
  must cover the whole compiler, including bytecode, before they permit slicing.

Content stamps use SHA-256. FNV selects cache filenames and checks disposable
cache-file corruption; it does not establish source identity. Cached standalone
library shapes are only reused in a compatible user declaration context.
Cancellation during verdict establishment propagates rather than recording a
negative verdict.

These changes alone produced **no material REPL gain**: print 1.48 → 1.45 ms,
arithmetic 7.49 → 7.46 ms, JSON/CSV 11.16 → 10.99 ms, and queries after 500
bindings 33.11 → 34.20 ms. The fresh-process import workload improved from
92.45 → 64.04 ms on cache misses and 19.68 → 17.50 ms on hits. File-read workloads
did not improve consistently: the 1 MiB miss case was 99.10 → 113.17 ms in this
run. This is cache/frontend work, with no claimed general VM or I/O speedup.

## Incremental user definitions

The REPL now parses the new command and retains accepted syntax. Source marks
are shifted by the accepted source's decoded-character length, including marks
in guards, struct fields and signature preconditions. On incomplete or invalid
command parsing, the full-source parser produces the established diagnostics.
Rejected commands never enter the accepted syntax.

`Infer.Session` owns a session-local snapshot of exact original clauses,
closed HM schemes and resolved clauses. The shared inference engine can seed a
new checking run from that snapshot and skip unchanged definition SCCs. A fresh
helper (or a fresh mutually recursive group) is checked against the earlier
closed interfaces. Every top-level eval, including earlier evals, is inferred
again. Tests deterministically show 400 arithmetic definitions' defaulting work
falling from 400 visits to zero on a query, and one visit when one fresh
arithmetic helper is added.

Reuse requires an exact match for old clauses and the non-binding declaration,
signature/struct and inference-profile context. A conservative name check refuses
reuse when a new global could shadow a name in earlier clauses or evals,
including implicit operator/member targets and dotted names. Changed or removed
clauses, new type/signature/struct declarations, and changed imported definitions
fall back to full inference. Prelude/library slice changes may also invalidate
reuse. String literals and bound local names can cause harmless extra misses.

Only schemes without free solver variables are cached. Errors and holes produce
no candidate. The snapshot is forced and published only after safety, ownership,
specialization, layout, lowering and bytecode compilation have succeeded. A
rejected trial uses the existing full compile for authoritative diagnostics.
Inspection modes also use full checking. Solver state, substitutions, site IDs,
JIT state, transactions, resource handles and evaluated results are never cached.

Imports are re-resolved per command. Effects remain scoped to a fresh transaction
per command; previous evals are checked but never executed again. Panic/interrupt
handling retains the existing consume-once semantics.

Controls:

- Default: incremental command parsing and checked-definition reuse.
- `SOL_REPL_INCREMENTAL=0`: disable both for a differential control.
- `SOL_REPL_INCREMENTAL=trace`: report reused/total definitions on stderr.
- Existing `SOL_INCREMENTAL=0`, `SOL_TYPES=1` and `SOL_WIDTHS=1` retain their full
  compiler paths; this optimization is specific to the Sol REPL.

## Paired REPL measurements

The second experiment compares the completed cache patch with incremental
checking. Real PTYs, echo disabled, write-to-next-prompt wall time, validated
output, GPU off, default JIT, isolated caches, four sessions per compiler and
workload in ABBA BAAB order. Each session measures 30 commands, or 20 after
100/500 bindings. Definition setup time is excluded from query latency.
Compiler builds and test runs finished before timing. Raw samples, identities
and method metadata are in the [evidence directory](evidence/2026-11-02-sol-repl-incremental/summary.json).

| Work | Completed cache patch | Incremental checking | Reduction |
| --- | ---: | ---: | ---: |
| Print a short string | 1.41 ms | 1.18 ms | 17% |
| Arithmetic | 7.22 ms | 4.88 ms | 32% |
| JSON + CSV | 10.24 ms | 7.40 ms | 28% |
| Query after 100 bindings | 9.76 ms | 5.94 ms | 39% |
| Query after 500 bindings | 33.12 ms | 20.89 ms | 37% |

A second run uses the **same binary**, with `SOL_REPL_INCREMENTAL=0` on the
control side. Arithmetic is 8.06 → 5.45 ms; JSON/CSV 11.92 → 8.76 ms;
100 bindings 11.28 → 6.73 ms; 500 bindings 34.91 → 20.88 ms. This reproduces the
benefit without attributing an unrelated compiler build difference to reuse.

The two runs are separate paired experiments; do not combine their absolute
numbers as one measurement. Startup was not counterbalanced and is variable;
there is no startup improvement claim. Separate-process script timings remain
around 21 ms. Rejected commands still take the full diagnostic path.

## Validation and remaining cost

- All 37 Cabal unit suites pass, including native inference/evidence suites.
- All 28 supported suites in the local `tools/sol-ci.sh` run pass. Its two
  documented exclusions remain: the cross/QEMU AArch64 hand-JIT check and the
  daily-script check requiring explicit user inputs. This is not hosted CI.
- `SolReplIncremental` checks exact source marks, polymorphic/row interfaces,
  clause order, new-helper elaboration, shadowing/context invalidation, holes,
  failure refusal and avoided inference work.
- 34 REPL differential sessions compare exact output, diagnostics, exit status
  and committed data with reuse disabled, with JIT off/on. They cover appended
  functions, mutual recursion, signatures, builtin shadowing, records, imports,
  same-size/same-mtime transitive edits, Unicode, continuation, errors, holes,
  safety, ownership, panic and transactions.
- 193 library and 173 prelude differential cases pass; cache corruption/content
  invalidation, trust paths, 11 REPL contracts and 8 ownership cases pass.

Checking is incremental; compilation is still proportional to the retained
program. Safety/ownership, specialization, lowering and bytecode generation still
run over it, and old eval expressions are rechecked. The follow-up profile below identifies repeated graph construction and metadata
assembly as cheaper first targets than post-check artifact caching.


## Follow-up: remaining compilation cost (after sync to main)

All pending work was committed and synced in `acf85ff` (Sol) and `f05f089`
(existing board preset metadata). The production compiler is unchanged by this
follow-up; the new `tools/sol-repl-profile.py` records validated PTY phase timings.
Finer probes were built only in an isolated checkout from the same compiler
sources. Their exact overlay and raw samples are in the
[profile evidence](evidence/2026-11-02-sol-repl-incremental/remaining-cost-profile/summary.json).

Three sessions per case, 15 queries per session, first query omitted from the
summary: 42 measured queries per case, GPU disabled and default JIT. Every setup
and query output was checked. The 0/100/500/1000 cases use constant definitions
and a tiny arithmetic query; JSON/CSV uses the earlier paired benchmark command.
These are attribution measurements with extra forcing/timing boundaries, not new
uninstrumented latency results. Totals are nested; medians do not add exactly.

| Instrumented phase | 100 definitions | 500 definitions | 1000 definitions |
| --- | ---: | ---: | ---: |
| Whole compile | 8.33 ms | 21.40 ms | 56.87 ms |
| Safety | 1.19 ms | 10.69 ms | 35.38 ms |
| Inference / checked-interface matching | 0.52 ms | 1.44 ms | 5.24 ms |
| Ownership-signature list spine | 0.06 ms | 0.57 ms | 2.84 ms |
| Ownership checking / table construction | 0.57 ms | 0.89 ms | 1.33 ms |
| Prelude dependency slicing | 1.27 ms | 1.88 ms | 2.48 ms |
| Core specialization | 1.12 ms | 1.17 ms | 1.31 ms |
| Lowering / lifting | 0.36 ms | 0.63 ms | 1.03 ms |
| Bytecode generation | 0.48 ms | 0.53 ms | 0.61 ms |
| Transaction commit | 0.06 ms | 0.08 ms | 0.09 ms |

**First: index the safety graph once per check.** `Safety.callGraphOf` currently
uses `nub` for definition names, rescans all tops for each function's clauses,
and recomputes `callsOf` in graph and taint/measure queries. At 500 definitions
safety consumes about half the measured compile time; at 1000 it dominates.
Use the existing order-preserving `Frontend.Traverse.sourceGroups`, index
clauses, and share each function's call edges. Continue running the same SCC,
termination-measure and unsafe-taint rules. This is an indexing change, with no
need to cache a safety verdict across commands.

**Second: build inference metadata lists in batches.** Although definition SCCs
are reused, `Infer` still appends one element at a time to `iNotes`,
`iInterfaces` and `iLinSigs`. The `iLinSigs` list spine alone takes about 2.84 ms
at 1000 definitions. Build these lists once in source order. Inferred notes are
also forced in the typecheck bucket; ownership-signature assembly was previously
charged to the ownership phase through laziness. The separate spine probe avoids
mistaking all that cost for ownership analysis. Preserve type-variable freshness,
interface order, ownership signatures and diagnostic order.

**Then: avoid rebuilding immutable dependency indexes.** Prelude slicing takes
about 1.9 ms at 500 definitions and 2.5 ms at 1000. It rebuilds name/member maps
and discovers dependencies by rendering ASTs with `Show` and reading their string
fields back. Cache immutable prelude/library indexes by exact context and/or use
an exhaustive AST string-field traversal with the same conservative seed set.
Changing the dependency policy needs semantic differentials, including operator
resolution, shadows, record shapes and diagnostics.

**Reprofile before caching lowered Core or bytecode.** The old `bytecode` timer
also forced lazy Core specialization. Split probes put actual bytecode generation
near 0.5-0.6 ms, lowering at 0.6-1.0 ms and Core specialization at 1.2-1.3 ms.
Their combined budget is much smaller than safety graph construction here.
A cache must account for constructor/shape IDs, polymorphic record dispatch,
call arities, specialization dependencies and generated names. Pruning unused
source before validation could suppress lowering errors, so it is not a safe
shortcut. JSON/CSV also spends about 1.7 ms re-resolving imports; keep source/pin
verification intact.

Acceptance for the next implementation: paired uninstrumented latency before and
after each change; unchanged diagnostics, source/clauses order, SCC membership,
termination-measure verdicts, unsafe-marker policy and ownership behavior; native
and Sol regressions because the safety and inference code are shared. The timings
identify a budget to reduce, not a promised speedup.

Reproduce the stock compiler profile:

```sh
python3 tools/sol-repl-profile.py --sizes 0 100 500 1000 \
  --output /tmp/sol-stock-profile
```

For the finer split, use a throwaway checkout (the patch contains timing probes):

```sh
git worktree add --detach /tmp/sol-phase-probes f05f089
git -C /tmp/sol-phase-probes apply --unidiff-zero \
  "$PWD/docs/evidence/2026-11-02-sol-repl-incremental/remaining-cost-profile/timing-probes.patch"
make -C /tmp/sol-phase-probes fpr
python3 tools/sol-repl-profile.py --binary /tmp/sol-phase-probes/fpr \
  --home "$PWD" --sizes 0 100 500 1000 --output /tmp/sol-split-profile
```

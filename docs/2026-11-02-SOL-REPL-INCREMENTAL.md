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
run over it, and old eval expressions are rechecked. The next useful work is to
measure those remaining phases and cache dependency-keyed post-check artifacts,
without caching effects or weakening whole-program ownership/safety checks.

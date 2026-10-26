# Five compiler/runtime follow-ups

Date: 2026-10-27. User-requested implementation goal after the structural
checkpoint. Deliver useful first implementations, focused correctness evidence
and representative measurements for later analysis. A full benchmark campaign,
all-target hardware qualification and unrelated CI repairs are not gates.
Plans and analysis scaffolding alone do not complete an item.

| Item | First useful milestone | State |
|---|---|---|
| Reset-safe reuse and loop-aware inlining | Sound reset barriers, larger bounded budgets at recursive callers, focused native checks and paired hot-loop measurements | First milestone complete |
| Scalar vector fast paths | Guarded direct flat Int/F64/F32 reads and length, exact bounds/trap behavior and a C fallback | Next |
| Request/reply locality | A bounded handoff/locality policy with fairness/migration coverage and paired message measurements | Pending |
| Loop optimizations | Shared native-IR loop analysis used by a conservative, useful optimization such as pure invariant motion; traps/effects remain ordered | Pending |
| Generational persistent-state copying | A safe initial immutable-state path that avoids copying retained old subgraphs at each cycle, with bounded retained generations/compaction and conservative fallback | Pending |

## 1. Reset barriers and loop-aware inlining

The starting tree at main `2201e4b` already had an uncommitted draft of the
loop budget and linked resetter analysis. This stage adopts and hardens that
work. Ordinary calls retain a 24-node budget; callers in recursive groups
can inline nonrecursive templates up to 64 nodes, over the existing three
rounds. Template weights are bounded and cached once per snapshot. Recursive
callees are still not inlined, and entry ticks/types/identities remain checked.
This is a recursive-caller heuristic, not a profile-guided hot-block analysis.

Constructor reuse introduces a write to an old allocation, even if the source
would no longer access that allocation. It therefore cannot cross a reset.
The effect summary covers direct resets, transitive source/imported helpers,
bare CAF evaluation, region closing/cycling, calls through local/computed
function values and opaque foreign references. Primitive entries with known
nonresetting behavior remain available; known source bodies are summarized
transitively. Unknown calls are conservative barriers, rather than assumed
safe because the old constructor is dead in the source.

The same effects reach every emitted artifact from the linked program.
Referenced external reset effects enter the unit cache identity (`core2`),
just like imported call arities; unrelated reset effects do not invalidate
otherwise unchanged units. Codegen revision 126 invalidates previously
optimized artifacts and admission stamps. Runtime/physical ABIs are unchanged.

### Safety evidence

`ReuseCheck` covers direct/field/CAF/callback/foreign reset barriers,
transitive summaries, legitimate child escape through a known nonresetting
callee, shape/alias/last-use rules and consuming workers. `TypedProgram`
checks distinct ordinary/recursive budgets, refusal bounds, checked
instantiations, code homes, fuel and independent evaluator answers.

`tests/check_reset_reuse.py` creates a source-valid program whose old tuple
is dead before the reset. It resets through an imported CAF, imported wrapper
or opaque C entry, then allocates noise and returns a fresh tuple. Clean main
`2201e4b` fails the first optimized CAF case with a stack-overflow panic; the
candidate passes all 24 executions across reuse/inlining controls and one/four
harts. No source access to freed state is required to reproduce the old bug.

The original fresh/consuming reuse native suites pass, retaining ordered
failures, private/general ABI compatibility, 1/4-hart answers and the
20,000-to-10,000 allocation ratchets. Conservative barriers can lose reuse
opportunities around opaque calls; richer verified effect contracts can recover
them later without weakening the safety rule.

### Measurements

A clean archived `2201e4b` compiler and the candidate run the existing helpers,
byte-loop and SHA benchmarks, with their checked-in expected outputs. Runs
alternate before/after order across seven pairs on one hart, after warmup.
Raw timings, compiler binary hashes, patch identity, compile times and binary
sizes are recorded in `/private/tmp/fpr-followups-step1-paired.json`.
The final report includes the reset-effect cache-key update.

Final-source median wall times (milliseconds, seven paired runs, Darwin arm64):

| Fixture | Main before | Candidate | Before / after |
|---|---:|---:|---:|
| helpers | 108.76 | 85.41 | 1.27x |
| byteloop | 87.94 | 87.56 | 1.00x |
| sha | 128.05 | 114.90 | 1.11x |

These measure the combined change, not isolated inlining attribution. SHA's
executable grows from 771,704 to 787,640 bytes (about 2.1%); helpers' size is
unchanged. Single observed build times were 3.25/3.16 seconds for helpers,
1.38/1.43 for byteloop and 3.66/3.97 for SHA. Unit caches were reused between
fixtures for each compiler; these are not cold compile-budget measurements.
The raw report is checked in at `bench/2026-10-27-inline-reuse.json`.

Final compiled `ReuseCheck`, `TypedProgram`, `CorePipeline` and `TypedUnits`
suites pass. Native reset controls pass all 24 executions; dependent-unit
warm-cache transitions and x64/RV32/RV64 emission pass with `core2` keys. The
test registry includes the new reset regression. No test threshold was raised.
The broader five-item goal remains active; items 2-5 are not implemented here.

Local records: `/private/tmp/fpr-followups-step1-{units,reuse,consuming}.log`,
`/private/tmp/fpr-followups-step1-reset-{before,native}.log`,
`/private/tmp/fpr-followups-step1-build-final.log` and
`/private/tmp/fpr-followups-step1-paired.{py,json,log}`.
Final cache checks: `/private/tmp/fpr-followups-step1-units-final.log`,
`/private/tmp/fpr-followups-step1-reset-final.log` and
`/private/tmp/fpr-followups-step1-cache-native.log`.

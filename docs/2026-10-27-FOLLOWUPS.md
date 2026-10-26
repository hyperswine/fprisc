# Five compiler/runtime follow-ups

Date: 2026-10-27. User-requested implementation goal after the structural
checkpoint. Deliver useful first implementations, focused correctness evidence
and representative measurements for later analysis. A full benchmark campaign,
all-target hardware qualification and unrelated CI repairs are not gates.
Plans and analysis scaffolding alone do not complete an item.

| Item | First useful milestone | State |
|---|---|---|
| Reset-safe reuse and loop-aware inlining | Sound reset barriers, larger bounded budgets at recursive callers, focused native checks and paired hot-loop measurements | First milestone complete |
| Scalar vector fast paths | Guarded direct flat Int/F64/F32 reads and length, exact bounds/trap behavior and a C fallback | First milestone complete |
| Request/reply locality | A bounded handoff/locality policy with fairness/migration coverage and paired message measurements | First milestone complete |
| Loop optimizations | Shared native-IR loop analysis and a verified conservative invariant-motion pass; traps/effects remain ordered | First milestone complete; motion is opt-in |
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
The broader five-item goal remains active.

Local records: `/private/tmp/fpr-followups-step1-{units,reuse,consuming}.log`,
`/private/tmp/fpr-followups-step1-reset-{before,native}.log`,
`/private/tmp/fpr-followups-step1-build-final.log` and
`/private/tmp/fpr-followups-step1-paired.{py,json,log}`.
Final cache checks: `/private/tmp/fpr-followups-step1-units-final.log`,
`/private/tmp/fpr-followups-step1-reset-final.log` and
`/private/tmp/fpr-followups-step1-cache-native.log`.

## 2. Guarded scalar Vector reads

The typed lowerer now emits guarded CFGs for pair-free `$vec.at`, `$vec.get`
and `$vec.len` on managed 64-bit hosted/QOS targets. Int and flat F64/F32
descriptors use direct element loads; all other representations retain their
original C entry. RV32, builtin and manual/ARC profiles retain the C path.
The existing source ownership/pair-elision rules still decide which reads
become these private primitives. Ordinary pair-returning calls are unchanged.

Arguments evaluate once, in source order, before any validation. Each failed
guard calls the original entry with those values, preserving its diagnostics
and validation priority (including the different At/Get invalid-index versus
invalid-handle priorities). Bounds precede column access; empty length reads
never touch columns. Int cells are retagged; F64/F32 cells preserve raw bits.
Column bases are read afresh, so mutation/growth cannot leave a stale base.

`Compiler.VectorABI` owns the shared scalar/kernel layout constants.
`ScalarVectorRead` verifies generated CFGs, policy/ABI/shadowing boundaries,
operand trap order, and static assertions compiled against the actual C
descriptor. CompilerOptions, TypedIR and KernelIR also pass. The native
`check_vector_fast.py` regression covers Int mutation, 80 pushes across growth
boundaries, signed zero/infinities/NaN payloads for both float widths, boxed,
tuple and record fallbacks, empty length, bounds and malformed-FFI diagnostics.
It runs 84 executions over one/four harts, inlining on/off and fast/off/fast
transitions in the same cache. All four target emission boundaries pass;
x64/RISC-V hardware execution is not claimed. The regression is registered.

`FPR_NO_VEC_FAST=1` independently disables this lowering and participates in
unit/run cache identities. Codegen revision 127 invalidates old artifacts.
Guards assume source-valid descriptor pointers, as the C runtime does; this
does not add protection against arbitrary corrupt pointers from foreign code.

Seven alternating paired runs of `tests/bench/vecread.fpr` (50 million Int
reads, one hart, Darwin arm64) check the expected output on every execution:

| Compiler | Median wall time | Executable bytes |
|---|---:|---:|
| Saved main `89408c4` | 212.03 ms | 472,504 |
| Guarded reads | 187.01 ms | 472,504 |
| Same compiler, fast path disabled | 202.58 ms | 472,496 |

The saved-main comparison is 1.13x; the same-compiler control is 1.08x.
Single observed builds took 3.99/3.17/3.19 seconds respectively, with separate
cache directories; these are not compile-budget guarantees. Raw samples and
compiler hashes are in `bench/2026-10-27-vector-reads.json`. This is one useful
workload, not a general performance claim. More aggressive guard elimination
or loop-invariant descriptor loads remain future analysis.

Local evidence: `/private/tmp/fpr-vector-{units,native,paired}.log` and
`/private/tmp/fpr-vector-paired/report.json`.

## 3. Bounded local-wake admission

A local BLOCKED-to-READY wake from an actor records a one-shot identity hint.
The normal selector may prefer it twice consecutively, then must take an
ordinary weighted pick. Aged/priority actors always precede the preference;
already admitted FIFO work stays ahead. Hints do not restamp, move, pin or
enqueue an actor. A dead, blocked, stolen or otherwise absent hint misses
safely. Cross-hart shipping and the stealing ownership protocol are unchanged.
`FPR_LOCAL_HANDOFF=0` at runtime compilation is the independent control.

`check_scheduler_locality.py` compiles the actual scheduler in a deterministic
harness, checking bounded preference, FIFO, aging and priority precedence,
2,000 admissions with continuous wake pressure, stale/dead/blocked hints,
pinning/unsaved-context exclusions and a late wake after stealing. It also
executes contended request/reply traffic on one/four harts. The existing actor
claim/reap regressions pass. `check_arena_migration.py` passes one/four harts,
with migration observed in each multi-hart run. Hardware/QOS execution is
not claimed; the shared scheduler source carries the policy.

Seven alternating pairs on Darwin arm64, one hart, 20,000 round trips with
eight pinned yielding competitors (`tests/base/locality.fpr`): saved prior
actors.c median **20.46 ms**, candidate **13.28 ms**, control with handoffs
disabled **20.65 ms**. This is **1.54x** for the contended case; executable
size is unchanged against the prior runtime (489,464 bytes). All answers
are checked, including warmup runs on four harts. The comparison compiles
the prior scheduler against the same current header/runtime/compiler, via
separate compiler wrappers/cache keys, so it isolates the admission change.
Raw samples and the exact source are in
`bench/2026-10-27-scheduler-locality.json`.

Short uncontended controls (20,000 round trips, seven alternating pairs)
measure 7.42/7.59 ms before/after on one hart and 9.72/9.98 ms across two
pinned harts. These startup-inclusive samples are roughly 2-3% slower;
the contended win is not a claim that every message workload improves.
The report includes these samples too.

This is admission locality, not migration/co-location of request/reply pairs.
The preference changes un-aged weighted frequencies; the deterministic aged
rule and existing conditional admission bound remain intact. Follow-up work
can measure broader mixed loads and tail latency before increasing the budget.
Item 5 remains pending.

## 4. Shared CFG facts and conservative loop motion

`Codegen.ControlFlow` now owns reachability, predecessor/successor sets and
dominance, shared by the verifier and entry-value splitting. Its natural-loop
analysis merges multiple latches, identifies nesting and existing unique
unconditional preheaders, and excludes irreducible entries. There is no
second independent dominance implementation in the verifier or splitter.

`Codegen.LoopOptimize` moves at most 16 total register operations per natural
loop into an existing preheader. It resolves strictly dominating single-source
block parameters so inlined callback captures can become invariant operands.
Dead callback parameters and their incoming copies are removed after motion.
Loads, fields, tag/truth dereferences, hart/region clocks, calls, allocations,
stores, safepoints and trapping arithmetic/shifts stay ordered. No new
preheader or speculative pointer read is introduced. This covers existing
CFG loops (particularly kernels); allocator-level self-tail-call loops are
still formed later and are outside this pass's scope.

`LoopOptimize` verifies input/output at both widths and checks exact evaluator
answers, traps and events for 72 combinations including zero trips and zero
divisors. It checks nested loops, multiple latches, irreducible cycles,
preheader refusals, capture forwarding and non-speculatable operations.
Compiled CompilerOptions, TypedIR and KernelIR pass. The full native kernel
oracles pass with motion enabled: hosted one/four-hart values, fallback and
failure order, plus x64/qx64 under Rosetta and RV32/RV64 under QEMU, including
record widths up to 300 columns and hostile yields. Those are emulated/hosted
results, not physical QOS or board qualification.

**Motion remains opt-in with `FPR_TYPED_IR_LOOP_MOTION=1`.** Its typed option
and `-licm` cache identity reach ordinary units, kernels and the diagnostic
pipeline. The shared analysis is unconditional. Codegen revision 130
invalidates earlier experimental artifacts.

The paired capture-dependent F64 fold benchmark does less arithmetic after
motion, but native allocation spills the accumulator more often. Removing
dead capture copies did not recover the cost. Seven alternating final pairs
on Darwin arm64, one hart, give saved main **205.49 ms**, opt-in motion
**227.36 ms**, default/off **205.35 ms** (see exact raw medians in the report).
The checked answer is 243,749,756,250,000 over 50 million rows. This is a
measured regression of roughly 11%, so the pass is available for analysis
without changing default performance. A register-pressure/profitability model
and late self-loop integration remain follow-ups, rather than acceptance
claims. `bench/2026-10-27-loop-motion.json` preserves the source, hashes and
raw samples. No performance threshold was relaxed.

Local evidence: `/private/tmp/fpr-loop-final-{units,kernels,paired}.log`.

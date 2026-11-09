# Performance priorities, integrated with the pipeline refactoring

Date: 9 November 2026. Kind: priority register and proposal. It changes no
compiler, runtime or library behaviour. Baseline: main `130c36d`; measurements
at `bc11824` (one commit earlier, which adds no code-generation change).

This page lists what still keeps FP-RISC away from C and from the other
compiled languages, says which of it the existing documents already identify,
and places each item in the [pipeline refactoring roadmap](2026-11-07-PIPELINE-REFACTORING-ROADMAP.md)
(P0-P7). It does not replace that roadmap, the [fixed-costs proposal](2026-11-06-FIXED-COSTS-PROPOSAL.md),
the [unboxing proposal](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md) or the
[cost-sized regions proposal](2026-10-23-COST-SIZED-REGIONS.md); it links them
and records only what they do not already say.

The constraints are unchanged: the high-level FP style stays, values are
unboxed by default where the compiler can choose, WCET is always on and lives
in the types ([decision 2, 1 November](2026-11-01-RELIABILITY-CORRECTNESS-WCET-ROADMAP.md)),
and reliability comes before raw speed, but ordinary application code must not
be several times slower than its peers.

## Summary

- **Memory reclamation is the largest gap, and the documents do not cover the
  case that hurts.** Loop regions decline any loop whose state is a `List`,
  `String` or recursive type ([stage 2 rule](2026-10-24-REGIONS-STAGE2.md)),
  which is exactly the state of typical application loops. Their garbage lives
  until exit: 0.6-3.7 GB of RSS on the application workloads below, and 16-58%
  of wall time in the kernel. This is a reliability problem as well as a speed
  one. The documented Base direction (regions, no reference counts) and the
  "ARC with reuse" direction discussed on 9 November disagree; that needs a
  decision (section "Decisions needed").
- **Data structures are the second gap and are not in the documents at all.**
  There is no mutable hash map, `Map.update` walks the tree twice, and
  `List.sortWith` is a list merge sort. These fixes are library and runtime
  work that does not wait for the pipeline.
- **Boxing, fixed per-operation costs and code generation are already
  identified and planned** (unboxing proposal, fixed-costs proposal, P3/P5/P6).
  This page only orders them and adds application-level gates.
- **Application code is not yet measured in the tree.** Every existing gate is
  a micro-benchmark, and the micro suite understates the application gap by
  about 4.6x (1.9x against 8.8x the peer median, below).

## Measured evidence

Measured 9 November 2026 (AEDT) on the shared Linux x86-64 Intel Xeon VM, 8
vCPU, `bc11824`, programs built with plain `fpr build`. Whole-process time,
median of 5 interleaved runs after a warm-up; peak RSS from GNU `time`. Every
language's output was byte-identical to C. The programs and raw data were
written off-tree for this measurement; putting them in the tree is item 0
below. Peers: Rust 1.85.1, Go 1.27.3, OCaml 5.2.1 flambda `-O3`, Temurin JDK
21.0.13; C is gcc 14.2 `-O2` (unchecked, so informational only under the
[reference audit](2026-11-08-PIPELINE-REFERENCE-AUDIT.md)).

| Workload | FP-RISC s / MB | C s / MB | Peer median s | FP-RISC / peer median |
|---|---:|---:|---:|---:|
| csv: parse 1M lines, aggregate by key | 2.907 / 1264 | 0.074 / 31 | 0.200 | 14.5x |
| wordfreq: 2M words, count, top 10 | 6.079 / 2169 | 0.062 / 16 | 0.175 | 34.8x |
| format: 1M formatted lines | 1.106 / 909 | 0.184 / 36 | 0.385 | 2.9x |
| records: 1M structs, 3-key sort, group-by | 1.267 / 865 | 0.218 / 62 | 0.390 | 3.2x |
| treemap: 500k inserts + 500k lookups | 1.181 / 614 | 0.263 / 20 | 0.450 | 2.6x |
| sim: 20k particles x 2000 steps | 3.023 / 3668 | 0.058 / 2 | 0.079 | 38.5x |
| **geomean** | | | | **8.8x** (17.8x C) |

The micro suite on the same run (fib, byteloop, sha, tree_sum, option_loop,
list_filter, list_map) is 1.9x the peer median and 4.3x C, within about 8% of
the [6 November record](2026-11-06-PERFORMANCE-AT-E138E65.md); the P2 commits
did not move it.

Where the time goes (cost probe, user/sys split and decomposition programs at
`bc11824`):

| Workload | Allocations, bytes (none freed) | user / sys s | Dominant cost |
|---|---|---|---|
| csv | 34.0M, 1.32 GB | 2.35 / 0.60 | 34 allocations per line: `String.lines` 0.62 s, plus `split`/`toInt` to 1.81 s; `Map.update` with tuple values about 1.0 s |
| wordfreq | 41.3M, 2.27 GB | 5.40 / 1.05 | about 6 s in persistent `Map.update` (get, then path-copying insert of about 17 nodes); `String.words` 0.21 s |
| records | 27.7M, 0.90 GB | 0.98 / 0.34 | `List.sortWith`: every merge pass reallocates cells |
| sim | 80.0M, 3.84 GB | 1.45 / 1.93 | two cells per particle-step, never freed; kernel page zeroing is over half the wall time |

Reclamation, checked at `bc11824` with `FPR_RECEIVE_NOTES=1 fpr build --cost`:
sim's `run` loop is declined as a loop region ("live parameter 2 has
`List P`"), as are `genGo` and the TRMC list builders. A twice-larger csv input
took 5.9 s and 2.6 GB, so RSS grows with the input and a 10x input would need
roughly 13 GB (extrapolated, not run).

Collections prototypes (off-tree fprisc programs at `bc11824`, same box,
median of 5):

| wordfreq variant | Time s | RSS MB |
|---|---:|---:|
| today's `Map.update` (AVL) | 6.320 | 2169 |
| AVL with a single-pass `alter` | 4.604 | 2018 |
| persistent uncompressed 16-way hash trie | 2.056 | 1610 |
| linear open-addressing table on two `Vector`s | 1.030 | 366 |

treemap with the linear Int table: 1.364 to 0.395 s. `List.sortWith` on 1M
Ints: 0.725 s / 727 MB; an in-place heapsort on a linear `Vector Int` written in
FP-RISC: 0.590 s / 79 MB. Fused `List` pipelines beat the equivalent `Vector`
pipeline 2.1x (0.890 against 1.858 s), which is evidence against a list-as-array
default.

Ownership audit, rerun at `bc11824` (`tools/audit_linear_ownership.py`): four
invalid probes are still accepted by both frontends: `higher_order_twice`,
`closure_return`, `aliased_pap` and `dynamic_pap` (`keep_escape` is the
recorded explicit escape).

Earlier measurements this page relies on, not repeated: fixed-cost ceilings
from hand-edited assembly on arm64 (`fib 40` 469 to 253 ms, `byteloop` 70 to
18 ms; [fixed costs](2026-11-06-FIXED-COSTS-PROPOSAL.md)), and the audited
ratios against checked C (`fib` 1.90, byte scans 6.06/6.02, Option loop 10.5,
trees 2.68; [reference audit](2026-11-08-PIPELINE-REFERENCE-AUDIT.md)).

## Coverage: what the documents already identify

| Item | Already in docs? | Where | Gap |
|---|---|---|---|
| 1. No reclamation for loops over unbounded persistent state | **Partial** | [Live memory](2026-10-02-LIVE-MEMORY.md) (nothing frees outside a boundary); [cost-sized regions](2026-10-23-COST-SIZED-REGIONS.md) (model, "Plain functions", open problems); [stage 2](2026-10-24-REGIONS-STAGE2.md) (List/String/Tree state declines a loop, "the right answer"); [loops and calls](2026-10-25-REGIONS-LOOPS-CALLS.md) | Treated as correct-by-design. No document measures its application-level cost (GB of RSS, sys time) or names a mechanism for it. In-place reuse is listed as staying but is scoped to local fresh constructors ([reuse](2026-10-20-REUSE-AND-PIPELINE-ROADMAP.md), [consuming workers](2026-10-20-CONSUMING-WORKERS.md)). Base ARC (Proposal B of [memory/I32](2026-10-12-MEMORY-I32-REFINEMENTS.md)) was replaced by regions on 23 October. |
| 1a. RSS as a reliability bound for applications | **No** | [Memory/I32](2026-10-12-MEMORY-I32-REFINEMENTS.md) has soak tests for services, not for batch programs | No RSS gate on any batch or app workload |
| 2. Boxing: Option/Result/tuple returns, cells, generic code | **Yes** | [Unboxing proposal](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md) A1/A2/C1/C2 and 2 November decisions; [zero-overhead checkpoint](2026-11-03-ZERO-OVERHEAD-ROADMAP-CHECKPOINT.md) items 3-4; [e138e65](2026-11-06-PERFORMANCE-AT-E138E65.md) step 3; pipeline P3 | Ordered for micro rows only. `toInt` results, map values as tuples and per-piece strings in app code are not named. |
| 2a. String pieces (`split`/`lines`/`words` allocate a string each) | **No** | - | No slice/view proposal; interacts with region copy-out and message copy |
| 3a. No mutable hash map | **No** | - | Not mentioned anywhere in `docs/` |
| 3b. `Map.update` walks twice | **No** | - | - |
| 3c. Sort is a list merge sort | **Partial** | [Std plan](2026-09-16-STD-PLAN.md) ("a certified merge sort, `n log n` stated") | No array-backed or C sort, no `Vec.sortWith` |
| 3d. HAMT / `HashMap` | **No** | - | Needs an immutable small-array primitive and `Int` popcount |
| 3e. Ownership holes block in-place structures | **Partial** | [Linear ownership gaps](2026-10-17-LINEAR-OWNERSHIP-GAPS.md), `tools/audit_linear_ownership.py` | Four probes still accepted; not linked to a mutable map, and the audit is outside CI |
| 3f. `--list-as-vec` / array-backed `List` | **Yes (rejected as default)** | Unboxing proposal B4, B5, B6 (proof-gated flat lists) | Nothing new; recorded as a non-goal below |
| 4a. Fuel ticks | **Yes** | [Tick batch](2026-11-02-TICK-BATCH.md), [fixed costs](2026-11-06-FIXED-COSTS-PROPOSAL.md) 4 and 4b, P6 | Register fuel and chunked fuel both open |
| 4b. Tagged Int in loops | **Yes** | Fixed costs 2 ("keep a loop-carried Int untagged"); P5 "unboxed loop-carried values"; unboxing C2 | - |
| 4c. Bounds/overflow checks | **Yes** | Fixed costs 2-3; [string scan ranges](2026-10-31-STRING-SCAN-RANGES.md); [interval discharge](2026-10-28-INTERVAL-DISCHARGE.md); P5 range-driven discharge with P1 summaries | - |
| 5. Instruction selection, registers, inlining | **Yes** | Fixed costs 1; [register allocation](2026-10-19-REGISTER-ALLOCATION.md), [register pressure](2026-10-27-REGISTER-PRESSURE.md); [next steps 5](2026-10-31-PERFORMANCE-AND-PREDICTABILITY-NEXT.md) (inlining by benefit); P4/P5 | Not tied to app workloads (records/treemap call comparators through closures) |
| Inherent costs (fuel, safety checks, persistence, reclamation work) | **Partial** | [Next steps](2026-10-31-PERFORMANCE-AND-PREDICTABILITY-NEXT.md), "Structural constraints" and "Performance expectations" | No stated budget for what they may cost |
| Targets (near C on numeric/array, 1.5-3x on allocating FP code) | **Partial** | Next steps "Performance expectations" (hypotheses, "not release gates"); reference audit (micro targets vs checked C) | No application-level target |

## Priorities

Order by impact on application code: memory reclamation, data structures,
boxing in app code, fixed per-operation costs, code generation. The delivery
order differs, because the data-structure work does not wait for the pipeline
and the memory work does.

### 0. Put application workloads in the tree (now; extends P0)

Add the six application workloads above under `tests/bench/apps/`, with their
generator, the expected outputs and a runner that records time and RSS beside
`tools/bench.py`. Peer references (Rust, Go, OCaml, Java) are labelled
informational, as the reference audit labels unchecked C. The suite runs
nightly, not in PR CI, so the CI budget (under 30 minutes, decision 3 of
1 November) is unchanged; PR CI gets one small fixed-input run per workload as
an output and RSS regression check. Add sim and wordfreq to the
`tests/pipeline/corpus.json` categories so P3-P6 slices report drift on them.

### 1. Library and runtime work that does not wait for the pipeline

In this order; each with a rollback path and an unchanged-output check against
the current implementation.

1. **Single-pass `Map.alter`/`insertWith`**, with `update` defined on it.
   Measured 27% on wordfreq (6.32 to 4.60 s). `std/map` keeps its ascending
   order and existing contracts; `tests/reliability/std_contracts.py` records
   the new bounds.
2. **Close the four accepted ownership probes**, then move
   `tools/audit_linear_ownership.py` into the reliability job with exit 0
   required. In-place mutation behind a linear type makes any accepted
   duplicate observable, and the same holes already exist for `Vector`. This
   is frontend work beside P1's callable summaries
   ([callable census](2026-11-09-CALLABLE-CENSUS-AND-SUMMARIES.md)), not a P1
   dependency.
3. **`MutMap 1 k v`, a runtime-backed linear hash table** (after 2), modelled
   on `Vector`: reads hand the map back, `strHash`/`intHash` primitives in the
   runtime, `withCapacity`, growth charged to the insert that triggers it
   (Vector's WCET rule), an option to refuse growth past a declared capacity,
   bounded probe length, ordered collision fallback, and `freeze` to `Map`.
   The FP-RISC prototype measured 6.1x on wordfreq and 3.5x on treemap; a
   runtime-backed table is estimated at 0.4-0.6 s on wordfreq (estimate, not
   measured). `Map` stays the default in examples; `MutMap` is the type for hot
   loops, as `Vector` is.
4. **A C sort behind `List.sortWith` and a new `Vec.sortWith`**: convert, sort
   (stable), rebuild. The list form is invisible to programs except for its
   stated `alloc` bound. The FP-RISC heapsort lower bound measured 1.2x faster
   with 9x less memory than today's merge sort; the C version is unmeasured.
5. **String slices for `split`/`lines`/`words`: investigate, then decide.** The
   gain is csv's 34 allocations per line. The risk is a substring holding its
   whole buffer alive across region copy-out and message copy; the design must
   say what copy-out copies.

### 2. Memory reclamation for unbounded persistent state (decision now; implementation after P3's first slices)

Goal: application loops whose state is a list, map or tree run in memory
proportional to their live data, with no annotation, and the WCET/`live`
bounds stay sound.

The candidate mechanisms, none decided:

- **(a) Static in-place reuse of uniquely owned cells**, Perceus-style but
  proved at compile time, extending `Reuse.hs` and the consuming workers from
  local fresh constructors to loop state (`List.map step ps` reusing `ps`).
  No count traffic; fits value semantics and the no-borrowing rule. Needs P1
  escape/uniqueness facts and P3's ownership plan.
- **(b) Regions with copy-out for unbounded state**: lift stage 2's rule for
  loops whose state is a list or tree, copying live state at a slab boundary
  (the generational path from [follow-ups](2026-10-27-FOLLOWUPS.md) generalised
  beyond receive turns). Copy cost is proportional to live state per cycle;
  the measured `Sys.loop` variant of sim bounded memory to 13 MB but took 1.5x
  longer.
- **(c) Precise ARC with reuse in Base** (Proposal B of 12 October), which the
  regions proposal set aside for count traffic, code size and its need for
  borrowed parameters.

Phase placement: the decision and a measurement plan belong now. Mechanism
(a) is a P3 consumer of P1's uniqueness/lifetime domain ("Escape, aliasing,
uniqueness and lifetimes: scalar replacement, reuse, regions"); (b) is P6
region-room placement plus runtime copy-out; (c) is a runtime and ABI revision
that must follow P3 and requalify QOS. Each lands with its own `FPR_NO_*` flag,
the 19-entry corpus drift explanation and the QOS pairing gate.

Gates: RSS on csv and wordfreq grows no faster than the input (2x input gives
at most about 2x RSS, not 2x garbage); sim RSS flat over steps; the declared
`live` bound of a loop becomes provable where its state size is; no change to
outputs, trap order or the scheduling contract.

After this lands: in-place reuse of unique AVL, HAMT and list nodes, so
persistent `Map`/`List` code approaches `MutMap` without annotations. WCET
still charges the copying path unless the type is linear, because dynamic or
inferred uniqueness is not guaranteed by the type.

### 3. Boxing in application code (P2 completion, then P3 slices)

Already planned in the unboxing proposal and P3; this page adds order and
app-level gates only.

1. Finish P2 (typed lowering authority) as the [checkpoint](2026-11-09-PIPELINE-REFACTORING-CHECKPOINT.md)
   sequences it. Unboxing work does not start a second representation path
   before P3.
2. P3 slices, as the roadmap orders them: scalar workers; unary wrappers;
   products and return values (`Option`/`Result`/tuple returns in loops,
   e138e65 step 3); closures and captures; container payloads (tuple values in
   a `Map`). Deterministic per-inductive representation (2 November, decision
   3) keeps cache identity stable, and unboxed is the default wherever the plan
   applies.
3. C1 piece 2a (layout table, preheader removal) as its own `abirev` bump, then
   C2 on `base` behind `FPR_NO_TYPE_SPEC`, after the checkpoint's item 4
   reconciliation.

App gates: csv allocations per line fall from 34 measured, with the target set
from the first slice's measurement; option_loop against checked C (10.5 today;
the tuple loop, already unboxed, is 1.19).

### 4. Fixed per-operation costs (P5 and P6)

As the fixed-costs proposal and the roadmap already order them:

1. P5 literal-check folding and dominated checked-operation reuse.
2. P1's first range/result-size consumer with P5 range-driven bounds and
   overflow discharge (byteloop, string_scan, sha's byte loops), then guarded
   invariant motion and untagged loop-carried `Int`.
3. P6 composed work between scheduling boundaries, then **register fuel** as a
   separate ABI change coordinated with QOS.
4. **Chunked fuel stays blocked** until section 4b's boundary contract is
   proved; it is not scheduled here.

Gates: the reference audit's targets against checked C (byte scans from 6.06
toward the fixed-costs ceiling, about 1.3x scalar C, measured on arm64 by hand
edit); tick-for-tick or contract-equivalent scheduling traces; no `segmax`
growth; spills recorded.

### 5. Code generation (backend; does not wait)

Fixed costs step 1 (branch on compares, immediates, cold paths after the body,
paired restores, return before building a frame) proceeds in the backends now.
Inlining by benefit and comparator specialization through closures (records and
treemap pass `Order.*` closures) move with P4; static callable optimization
follows the [defunctionalization design](2026-11-09-STATIC-FUNCTIONS-AND-DEFUNCTIONALIZATION.md).

Gate: `fib` worker instruction count and the checked-C ratio (1.90 today).

### 6. Later

- `std/hashmap` as a HAMT, once an immutable small-array primitive and `Int`
  popcount (SWAR fallback for simple-risc without Zbb) exist; collision buckets
  ordered for a bounded worst case; documented as deterministic hash order.
- Decide whether `Map` itself should hash. Leaning no: 23 of the 33 files that
  import `std/map` use ordered operations, including `std/json` and `std/wire`.

### Delivery order

| Order | Work | Phase | Depends on |
|---|---|---|---|
| 1 | In-tree app suite and RSS recording | P0 extension | - |
| 2 | `Map.alter`, C sort (`List.sortWith`, `Vec.sortWith`) | std/runtime | - |
| 3 | Close four ownership probes; audit in CI | frontend | - |
| 4 | `MutMap` with hash primitives and `freeze` | std/runtime | 3 |
| 5 | Memory reclamation decision and measurement plan | decision | 1 |
| 6 | P2 completion | P2 | in progress |
| 7 | Backend selection and frames | backend | - |
| 8 | P3 slices with Option/Result/tuple returns, C1 2a, C2 on base | P3 | 6 |
| 9 | Reclamation implementation | P1 + P3 (a), P6 (b) or runtime (c) | 5, 8 |
| 10 | P5 folding, range discharge with P1 summaries, untagged loop Ints | P1, P5 | 6 |
| 11 | P6 composed work, then register fuel with QOS | P6 | - |
| 12 | String slices, if the investigation favours them | std/runtime | 9 |
| 13 | HAMT `HashMap`; in-place reuse of unique persistent nodes | std, P3 | primitives, 9 |

## Acceptance gates

- **Application targets** (proposed, not yet met): every app workload at most
  3x the peer median, and the geomean at most 2x, by the end of the delivery
  order above; RSS proportional to live data rather than to total allocation.
  Today: 2.6-38.5x and 8.8x.
- **Micro targets** stay those of the reference audit, against checked C.
- **WCET**: every change keeps declared `work`/`alloc`/`live` bounds PROVEN or
  reports them UNPROVED by name; no build flag changes a data structure's
  asymptotic cost; growth is charged where it happens; the scheduling contract
  of the [semantic policy](2026-11-07-PIPELINE-SEMANTIC-POLICY.md) holds.
- **Pipeline gates**: drift explained line by line at each phase exit, QOS
  pairing on P3 slices, compile budget green (`tests/check_compile_budget.py`).
- **CI**: PR CI stays under 30 minutes; the app suite and peer comparisons are
  nightly.

## Costs that remain by design

These can be made small but not zero:

- **Always-on fuel and WCET checks.** A safepoint per loop iteration or call;
  a few percent, and up to about 10-20% on the tightest loops, unless a proved
  bound lets placement drop it (estimate).
- **Safety checks C does not make.** Overflow, bounds, division and stack
  checks stay wherever they cannot be proved away, as in Rust.
- **Persistent data by default.** Code that genuinely shares old versions pays
  for keeping them. Linear types (`Vector`, `MutMap`) and proved uniqueness
  recover in-place cost where ownership is clear.
- **Reclamation work.** Region copy-out, reuse checks or counts, whichever the
  memory decision chooses, cost something per cycle or per object.

Realistic direction, a hypothesis rather than a measurement: about C on
numeric and array code over linear or unique data, and 1.5-3x C on
allocation-heavy functional code, where OCaml and GHC sit today.

## Non-goals

- **`--list-as-vec` or any flag that changes a data structure's representation
  globally.** It changes the complexity of shared tails and `x :: xs`, and so
  the WCET bounds of the same source; fused `List` code is already faster than
  `Vector` (measured above). Unboxing B4 already rejects this as a default; B6
  (proof-gated flat lists) remains the compiler-chosen alternative.
- **`List 1`.** `Vector` is the linear contiguous list; it needs `sortWith`,
  conversions and syntax, not a second list type.
- **`Map` becoming hash-based by default**, for now (section 6).
- **Use-site multiplicity** (`Map 1` meaning "this particular map is linear").
  Linearity stays nominal per type; `MutMap` is a separate linear type.
- **A tracing collector for Base**, and an LLVM or C backend (fixed costs,
  "Not proposed").

## Decisions needed

1. **Memory model for unbounded persistent state**: (a) static in-place reuse,
   (b) regions with copy-out for list/tree state, (c) precise ARC with reuse in
   Base, or a combination. The 23 October regions proposal set (c) aside; the
   9 November discussion assumed it. One of the two needs to be recorded as
   superseded.
2. **Chunked fuel**: still blocked on its proof (fixed costs 4b); this page
   does not schedule it.
3. **Register fuel on AArch64** (fixed costs, open question 1): one
   callee-saved register for the counter, shared with QOS apps.
4. **`MutMap` naming and capacity policy**: whether WCET code must declare a
   capacity, or whether charged growth suffices.
5. **App-level targets**: whether the 3x per-workload and 2x geomean targets
   above are the right line for "not way slower".

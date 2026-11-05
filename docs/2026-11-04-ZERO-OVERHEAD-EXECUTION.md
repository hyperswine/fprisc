# Zero-overhead roadmap execution

Continuation: [roadmap completion](2026-11-04-ZERO-OVERHEAD-COMPLETION.md)
closes the materializing-pipeline gap recorded below and tracks the remaining
C2, aggregate, latency and static-arena work. This report retains the earlier
codegen-162 milestone's measurements and qualification scope.

The agreed goal is to complete these five priorities in order. This record
tracks implementation and evidence; an item is complete only when its checks
pass, not when a gate is widened or a rewrite appears in remarks.

1. **Helper-aware List fusion — implemented and locally validated.** Expose bounded checked helpers
   before callback specialization, retaining evaluation order, entry ticks,
   import visibility and structural verification of the List catalog. Gate
   helper-wrapped scalar pipelines at zero intermediate allocations and run
   effects, traps, sharing and generated differential checks.
2. **Scalar tuple accumulators in List.fold — implemented and locally validated.** Carry scalar fields
   through specialized folds, preserving checked arithmetic and argument
   order. Match the explicit loop's allocation count in all three pipeline
   spellings; keep escaping/unsupported values on their ordinary path.
3. **Green Base qualification — all 180 registered configurations passed.** Diagnose the MVU/event-port failures on
   current source, isolate allocation tests from unrelated passes, and fix
   output-channel expectations with evidence. Run the entire registered suite.
4. **Builtin/ARC typed TRMC — implemented; focused QEMU checks pass.** Establish explicit ownership transfer
   for fresh builders and final/shared tails before enabling the profile.
   Cover retain/release, captures, failure paths and bounded memory.
5. **Remaining allocation costs — implemented and locally qualified.** Share inline refill tails, then
   finish the object-size/ownership proof and layout change needed for smaller
   cells. Cover all object classes, slab ownership, alignment, sharing, actor
   transfer, recycling and ABI coordination. Qualify QOS and target execution
   separately from host tests and assembly emission.

Starting source: `7b24f9c` (includes the default-build gates, inline bump
allocation and restored runtime type-id checks for received values). Earlier
benchmark records establish targets; they are not new measurements of this
work. No existing unrelated changes were present when implementation began.

## 1. Helper-aware fusion

One bounded checked-inline sweep shares List fusion's existing immutable
catalog. It exposes small wrappers (24-node limit) only in bodies containing
at least two helper/List-operation references. The standard combinators stay
intact, and structural catalog checks still grant fusion authority. Names in
the preliminary candidate filter are only a profitability hint. Public calls,
import visibility, callback captures and ordinary inlining opt-outs retain
their contracts. Helper chains beyond this bounded exposure may still decline.

The fusion walk canonicalizes irrefutable argument aliases while retaining
entry ticks as Unit bindings. Producer floating works from inner expressions
outward, so a nested helper result can become visible to its consumer. Lifted
prefixes require non-trapping evidence. Use counts now add repeated uses
instead of relying on left-biased Map union, including closure captures;
shared effectful producers are tested to execute once.

The [paired source-form benchmark](../bench/2026-11-04-list-helpers.json)
records the compiler hash, all sources, output checks, cold/warm compile
costs, code sizes and 11 runtime samples per spelling. Native arm64 macOS,
one hart, normal regions, process startup included:

| Family | Helper allocations at 1,000 elements | Helper time at 1M | Direct time | Explicit loop time |
| --- | ---: | ---: | ---: | ---: |
| sum-map-filter | 0 (previously recorded: 2,000) | 5.24 ms | 5.23 ms | 5.69 ms |
| count-filter | 0 (previously recorded: 1,500) | 5.02 ms | 5.00 ms | 5.43 ms |

These are current source-form comparisons, not a paired old/new compiler
speedup claim. Imported captured helpers also allocate no intermediate lists:
zero requests normally, one composed closure with specialization disabled.
This is not universal source-form equivalence: the final abstraction suite's
materializing-helper case still uses 1,501 requests versus the explicit loop's
1,001 at the probe size. Eliminating that remaining intermediate construction
is a separate follow-up; the zero-intermediate gates here cover scalar consumers.

At the helper milestone: 38 Haskell suites; strict List-fusion tests; helper effect, trap,
sharing, capture, import and integer-limit tests; 2,400 generated comparisons
with no mismatches (41 documented overflow-order relaxations). The final
profitability/scan changes retain the allocation gates. Compiler budgets pass:
hello 1.55 GB (+5.8% over the repository baseline), std-live 32.74 GB (+9.4%),
pos1 70.57 GB (+8.9%); peak-live budgets also pass. This is local host evidence,
not new CI, cross-target execution, board or scheduling-latency qualification.

## 2. Scalar fold accumulators

Field workers may reconstruct their aggregate at a return boundary. They
still refuse whole-value observations, captures and unknown calls inside the
loop. Guarded shape evidence propagates through at most three layers of small,
nonrecursive forwarding entries, retaining the ordinary entry and its fallback.
The existing 128-worker, 64-argument and 1,024-node clone bounds remain. Fresh
seed fields are evaluated in order at the original binding, including when a
region adapter surrounds the eventual worker call. Shared seeds remain boxed.
The `FPR_NO_TUPLE_SCALARS` opt-out disables these extensions.

The [updated paired benchmark](../bench/2026-11-04-fold-scalars.json) gives all
three sum/count folds **5 allocations at 1,000 elements**, down from the prior
505, matching the explicit loop. At 1M elements the direct/let/helper medians
are **5.46/5.51/5.50 ms**, versus **5.65 ms** for the explicit loop (11 samples,
native arm64 macOS, one hart, startup included). List fusion disabled separately
gives **2,005 -> 1,005 requests**: the 1,000 source cells remain, while per-element
accumulator pairs disappear. This does not depend on eliminating the source.

Focused checks cover empty folds, shared seeds, conditional forwarding, ordered
field effects, division/overflow order, managed list fields, observed whole
values, integer endpoints, shadowed forwarding targets, region-adapted seeds
and the rollback. Existing tuple/record worker checks pass. Generated differential
coverage includes tuple folds: the final 96-program, 960-case run passed all
2,400 comparisons, with 44 documented overflow-order relaxations and no
unexpected mismatches ([transcript](../bench/2026-11-04-fusion-fold-differential.txt)). Final compiler budgets pass at hello/std-live/pos1:
1.58/32.88/70.90 GB allocated (+7.6/+9.9/+9.4% against the existing baselines).
Default-layout cache naming is implicit in codegen revision 162; only the
legacy rollback adds a suffix, avoiding needless path/string allocation.
The final Base qualification below includes these checks and the registered target checks.

## 3. Previously failing Base jobs

All six pass in a focused two-worker run (151 seconds). The two actor/MVU
failures are resolved by the starting source's `7b24f9c` type-id correction;
no new runtime change was needed for them here. Reuse allocation probes now
disable pair returns, which independently erase the object the reuse ratchet
counts; their ordinary behavior tests still use the default pair-return
optimization. The vector-read allocation comparison disables pair returns
symmetrically and checks default-build values separately. Panic text is
required on stderr with empty stdout. No allocation thresholds were loosened.

The long MVU lifetime job runs alone within Base: concurrent compilation and
emulation caused its paced 20,000-frame fixture to exceed the 120-second wall
limit. The unchanged fixture passed in isolation in 46/48 seconds on one/four
harts. Its timeout, exact result and under-4-MiB retention bound are unchanged.
The RV startup oracle now checks module schema 2, the layout pointer and the
width-specific managed prefix, alongside its existing PAP/call checks.
The foreign-image padding oracle covers both layouts and both zero-/one-field
constructors: compact nullary cells have no padding, so reading a word beyond
them was an invalid old assertion. It now verifies physical extent, preserves
the payload, and checks poisoned padding only within the actual cell; at least
one shape must exercise padding in each layout.

## 4. Builtin and automatic ARC TRMC

The checked fresh-builder proof now applies to 64-bit builtin and builtin ARC.
The allocation-free `--raw` runtime and RV32 remain excluded. Manual ownership
uses the existing proven direct store. ARC routes the erased store through a
closed internal primitive with an owned-call contract: the new tail reference
transfers into the cell, its previous edge is released, and the temporary
cursor reference is released. Root/cursor aliases are intentional; the proof
establishes freshness and non-escape rather than relying on a reference count
of one. The adapter checks the heap's two-field layout and managed tail slot.
Representation inference relates cursor and tail types without declaring raw
payloads to be managed. ARC cache revision is 8. The coordinated final runtime revision is codegen 162.

`check_trmc_arc.py` executes default/rollback pairs under RV64 QEMU for shared
seeds and final tails, a captured heap string, raw Word payloads, printed
argument effects, division/overflow order, and 1,000 materialize/drop cycles in
16 KiB. Every successful ARC program also requires zero live allocations at
exit. A 6,000-cell returned graph exercises iterative destruction on the fixed
stack. Manual builtin output also matches rollback. Linker-wrapped allocation
requests are **400 -> 200** for a 200-element builder with both the FP-RISC and
C builtin allocators. The native C ownership oracle checks edge replacement,
self-replacement with an independently owned reference, shared-tail survival,
and final zero live allocations under ASan/UBSan.

ARC remains first-order; this does not admit function values or closures.
A nested `List (List Int)` fixture encounters the existing representation
unification restriction with TRMC both enabled and disabled. The managed
payload acceptance case uses a heap String, and shared List tails are covered
separately. These are emulator and host-sanitizer results, not board results.

## 5. Allocation and layout

Refill code is now shared only when identical raw sizes and placed destination
registers make it smaller: four sites on A64/RV64, two on x64. A64/RV64 park the
nested return PC in the not-yet-produced destination; the existing allocator
wrapper preserves it. On x64 the shared call supplies the stack alignment
word previously reserved explicitly. No extra peak stack space is required.
Fuel bounds charge the out-of-line body at every site, so sharing does not
hide executed instructions. A 24-constructor function has two shared refill
tails on each target. It executes correctly on native A64 and Rosetta x64 with
normal windows, all-cold cost-probe allocation, rollback, and one/four harts.
An independent RV64 QEMU oracle checks all 4,800 produced cells and requests.
Compiler budget remains within the existing limits (hello 1.58 GB, std-live
32.89 GB, pos1 70.93 GB; no baselines or margins relaxed).

The [compact-cell implementation](2026-11-04-COMPACT-CELLS.md) removes the
managed size word on 64-bit Base/QOS, while retaining slab ownership, raw
buffer capacity and explicit ABI negotiation. Cons cells occupy 32 rather
than 48 bytes. Constructor tables from loaded modules are copied into a
persistent registry. Wide tuple arity comes from its reserved type-id encoding;
the first default-layout Base run caught its absence from source constructor
tables, and dedicated extent tests now cover it.

Native A64/x64 and RV64 QEMU allocator oracles pass. Nineteen focused compact
integration jobs and QOS portable/RV64 QEMU large-storage checks on 1/2 harts
pass. The previous combined main-tree run passed all 176 Base jobs in 1,584
seconds with four workers ([record](../bench/2026-11-04-base-through-refills.json));
that run predates compact cells.

Final codegen-162 qualification covers **all 180 registered Base configurations**
([coverage and per-job timings](../bench/2026-11-04-base-final.json)). This is
coverage across two runs, not a claim of one uninterrupted green run: 58 jobs
passed before the obsolete foreign-image padding assertion stopped the first
run; after correcting that fixture, the remaining selection passed all 123
jobs (one overlaps the earlier set). The compiler/runtime stayed unchanged,
and its binary hash matches the final compact-cell benchmark. No synthetic
CI receipts were used. The two runs took 964 and 624 seconds on four workers.
Compiler allocation budgets and the isolated MVU lifetime job passed in the
first set; every interrupted, failed or not-yet-run configuration was covered
by the completion set.

Paired compact/legacy measurements (8 repetitions, 21 shuffled host samples)
reduce materialized-list allocation bytes by about one third. The final
codegen-162 build/traverse and map/traverse medians improve 13.6% and 23.4%,
with wins in 17/21 and 20/21 paired samples. Host timing noise is visible in
the saved samples. Three-field tree nodes remain 48 bytes and win only 12/21
samples, so no consistent tree gain is established. These are improvements
to retained representation cost, distinct from the abstraction removal in
helper fusion and scalar folds.

Hosted F64 values use raw bits, not boxes; sending one to an untyped receiver
that applies generic `str` crashes in the pre-change compiler too and is the
already-documented raw-float dynamic-boundary limitation. The boxed-object
oracle uses I64. No physical Pi or FPGA deployment is included in this goal's
current evidence.

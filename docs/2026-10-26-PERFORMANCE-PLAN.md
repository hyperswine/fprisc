# Native performance plan

Date: 2026-10-26. Kind: plan, proposals not yet implemented. Builds on
[the review](2026-10-25-PERFORMANCE-REVIEW.md), [the step-0 baseline](2026-10-26-PERFORMANCE-BASELINE.md)
and [the regression investigation](2026-10-26-PERFORMANCE-REGRESSIONS.md).
Each step lands alone, with its benchmark delta against
`bench/2026-10-26-step0-baseline.json` (`tools/bench.py --c`), the evaluator
differential checks unchanged, the full Base suite, and the compile-time
budget (`tests/check_compile_budget.py`), since several steps make the
compiler do more work.

Where things stand (Apple M4): fib 2.6x from C, byteloop 23x, sha 29x;
pingpong 2.1x slower than on 2026-10-01; vecread 1.3x slower.

## 1. Receive turns as lazily cycled regions (done)

Decided by the user and implemented the same day: [receive turns cycle per slab](2026-10-26-RECEIVE-TURNS-PER-SLAB.md).

**Problem.** Each receive turn runs a runtime trampoline: two generic
applications, a new `(continue, closure)` pair and closure, a deep copy of the
next state, then release and reset. 37% of pingpong. Every actor loop in
std/mvu, std/task and services pays it per message.

**Proposal.** Compile a receive loop like a loop region: the turn is a direct
self tail call with its state in registers, an inline room check at the turn
boundary, and a cycle (copy state out, release message roots, reset) only when
the turn's arena has filled a slab, or when the actor parks with more than a
threshold held.

**Decision.** This releases messages at slab boundaries rather than at every
turn. Memory stays bounded (one slab of scratch and messages per actor loop),
but it changes stage 1's rule "a message dies with its turn". The alternative,
keeping per-turn release but replacing the trampoline with a direct loop, keeps
the rule and removes the applications and pair allocation, leaving the state
copy (dc_size/dc_dup).

**Expected.** pingpong toward its turns-off 211 ms (from 334), xpingpong
toward 357, and less work per message in every MVU app.
**Checks.** The stage-1/stage-2 region tests and the deadmail/receive-turn
regressions, with message-retention bounds restated per slab if the first
option is chosen.

## 2. Keep same-hart partners together

**Problem.** With ten harts, idle harts steal the ponger, so a same-hart
request/reply pair becomes cross-hart and spins: pingpong 279 ms on one hart,
340-380 ms on ten.

**Proposal.** When an actor blocks on a reply from an actor it just sent to,
prefer running the receiver on the sender's hart (do not offer it for stealing
for a short window, or wake it locally), the usual "hand-off" scheduling.
Stealing stays for actors that are runnable while their hart is busy.

**Expected.** pingpong 340-380 -> about 280 ms before step 1, combined with it
lower. xpingpong unaffected (it is placed across harts on purpose).
**Checks.** Scheduler fairness and migration tests in Base; four-hart answers.

## 3. Inline vector fast paths (review section 1, item 3)

**Problem.** A scalar `Vec.get/at/len` in user code is a C call into `vec.c`
(`h_peek_at` -> `row_at` -> `get_cell` -> `vl_slot`), with every live value
pushed to callee-saved registers around it.

**Proposal.** Lower `$vec.at/get/len` for flat element kinds to the IR's
existing `OIndex`/`OLoad` behind inline representation, kind and bounds
guards, with the C entry as the slow path. Records and tree vectors keep the
call.

**Expected.** vecread well below its 158 ms 2026-10-01 time; any Int/F64
vector loop.
**Checks.** Vector suites, the evaluator differential, one/four harts.

## 4. Loop optimizations (review section 3)

**Problem.** `Codegen.Simplify` folds conversions, threads Bool joins, shares
pure operations within one block and fuses float trees. Nothing moves
loop-invariant work, nothing is shared across blocks, and no range knowledge
removes checks: byteloop keeps an overflow check on `acc + b` and `i + 1` and a
bounds check on every `charAt` per byte; sha's rounds keep theirs.

**Proposal, in order.**

1. Loop structure in the IR: self tail calls are already loops (M3); add a
   loop-nest analysis (headers, back edges, preheaders) shared by the passes
   below.
2. Loop-invariant code motion for pure operations, and for checks whose
   operands are invariant, into the preheader. A check that may trap moves
   only if the loop body's earlier traps and effects cannot be reordered with
   it (the trap order rule `Simplify` already keeps).
3. Cross-block sharing of pure operations along dominators.
4. An interval (difference-bound) analysis over Int values: from loop guards
   (`i < n`, `i >= n` exits), `strlen`/`Vec.len` results and arithmetic, prove
   `0 <= i < len` and no-overflow facts, then drop the overflow checks and
   bounds checks they discharge. It is the same domain as the
   [refinement proposal](2026-10-12-MEMORY-I32-REFINEMENTS.md) section 3:
   design it so the source-level precondition checker can use it later.

**Expected.** byteloop and sha first; anything iterating strings or vectors.
**Checks.** Each removed check needs a proof in the analysis, not a pattern:
the evaluator differential, trap-order fixtures (overflow at the last
iteration, an out-of-range index after a guard), and the native emission
oracles on x64/RV32/RV64.

## 5. Inlining and specialization reach (review section 2, updated)

**Where it is now.** Since `5ac6b4d` the checked Base inliner works across
units from one shared catalog, and linked callback specialization clones
imported higher-order functions per callback (`134a992`). The review's "within
a unit only" no longer holds. What remains: a fixed budget (`inlineLinked 3
24`: three rounds, 24 nodes), recursive groups never inlined (every loop), and
public functions keep tagged signatures (workers are private).

**Proposal.**

1. Measure first: list the calls left in the hot loops of byteloop, sha
   (`std/digest`), helpers and strbuild after inlining (`FPR_DUMP_CORE`), and
   which are small non-recursive helpers over budget.
2. Budget by benefit, not one size: a larger budget for call sites inside
   loops and for callees whose arguments are constants or known callbacks,
   with the compile-time gate watching the cost.
3. Loop-aware specialization: a recursive std loop called with a known
   callback or constant argument is cloned at the call site (it is not
   inlined; the clone becomes a local loop the passes in step 4 can see).
4. Worker signatures (unboxed Int/F64 parameters) for public functions whose
   callers are all known in the linked program.

**Expected.** helpers, sha, anything built on std/list, std/string, std/map.
**Risk.** Code size and compile time: the budget gate and binary sizes are
recorded with each change.

## 6. Clobber-free tick and allocation fast paths (review section 1, items 1-2)

Bump allocation inline from the hart block's slab pointer and limit, with
`fpr_alloc` only on refill; the fuel tick's and allocator's slow paths save
the live scratch registers themselves, so the fast path declares no clobbers.
Expected: strbuild, nbody, helpers, every allocating loop; more on x86-64
(five callee-saved registers). Interacts with loop and call regions (the room
check and slab refill are where regions open), so it lands after step 1.

## 7. Interval splitting in the allocator (review section 4)

Split live ranges at block boundaries with move resolution, so a spill lasts
only across the call that forced it. Measured after steps 3-6, which reduce
the pressure that makes it matter.

## 8. Fuel-tick amortization (review section 5)

A loop with a measured bound (`Cost.hs` already derives it) ticks once per K
iterations or charges its bound at entry, keeping the bounded-time-between-
safepoints contract explicit.

## Compile time alongside

The same work makes the compiler busier. From [the budget page](2026-10-26-COMPILE-TIME-BUDGET.md):
emitting units in parallel (the compiler is single-core today) is the largest
available compile-time win, and the remaining verification of unchanged
elided stubs is about 8%. Steps 4 and 5 should land with their compile-time
deltas from `tools/compile_profile.py`.

## Order

1 or its alternative (after the decision), 2, 3, 4, 5, 6, 7, 8. Steps 2, 3 and
4.1-4.2 are independent of each other and of the decision in step 1.

# Checks in byte loops: what moved, what did not

Date: 12 November 2026. Kind: implementation record and findings. It follows
[allocation sites, strings and products](2026-11-12-ALLOCATION-SITES-STRINGS-AND-PRODUCTS.md),
whose section 5 found csv and wordfreq spending their time in the prelude's byte loops. It is a
first slice of the [fixed-cost proposal](2026-11-06-FIXED-COSTS-PROPOSAL.md)'s steps 1 and 3.

## Summary

| Measure | Before | After |
|---|---|---|
| csv instructions | 15.6 G | 13.1 G |
| wordfreq instructions | 16.5 G | 13.4 G |
| `myCmp` microbenchmark (20,001 compares of 1,011 bytes) | 2.638 G | 2.123 G |
| `strCmpGo` text | 247 instructions | 195 instructions |

All app outputs are unchanged. The changes are AArch64-only, apart from the String guard, which is shared IR. `codegenRev`
is now 216 (215 went to a concurrent send change on main). It had not been bumped for this branch's earlier codegen changes either, and a stale unit cache hid this
round's effect until it was.

## The loop, per byte, before

`strCmpGo` in its default build, for one equal byte:

- the fuel tick;
- two length guards, each untagging both operands, comparing, setting a flag and branching on it;
- for each string, `charAt`'s guarded fast path (`Codegen.StringRead`): an Int-bit test,
  a type-id test, a variant test, a length load, two bounds compares (each against a constant moved into
  a register first) and the byte load. That is about 25 instructions, twice;
- `i + 1`, untagged, added and retagged.

The stack check was already outside the loop: the self-loop's back edge enters after it.

## What changed

- **One header word for the String guard.** `StringRead` now guards with `OVariantTest` (type id
  and variant compared as one word, answering False for a tagged Int) instead of `OIsInt` followed by
  `OTagTest`. That is the same answer from one load and one compare.
- **Compare and branch (AArch64).** A block whose last instruction is an `OCmp` or `OVariantTest` used only
  by the block's branch compares and branches on the flags. There is no `cset` into a register and no
  `cbz` on it. A constant made in the same block for that compare alone becomes an immediate (`cmp x, #0`).
  This is the proposal's step 1 ("branch on the comparison directly; use immediate operands"), and every
  function benefits.
- **String scans keep up.** `Codegen.StringScan`, the opt-in loop versioning for String scans
  (`FPR_TYPED_IR_STRING_SCAN`), recognizes the one-word guard as well as the old pair.

## What did not move, and why

The invariant guards stay in the loop even with `FPR_TYPED_IR_EARLY_LOOPS=1 FPR_TYPED_IR_LOOP_MOTION=1`:

- **Motion finds them.** In the String loop it finds eight invariant operations: the two untagged lengths
  and each string's tests and address.
- **The pressure gate admits only the untags.** Values live across the slow paths' C calls need
  callee-saved registers. Eight are free on AArch64, and the loop already uses them.
- **Forcing them out loses.** With the gate disabled, and header tests admitted as speculatable, everything
  hoists and the microbenchmark improves (2.64 -> 2.15 G before the changes above), but the hoisted predicates
  spill to the frame. `LoopOptimize` keeps its rule that header tests do not speculate: its unit test pins it,
  and admitting them gained nothing under the gate.

Three ways forward, in order of expected value:

1. **Mixed scalar workers.** `strCmpGo`'s Ints (`i`, `la`, `lb`) travel tagged because a scalar
   worker requires every parameter to be a raw Int or Bool, and two of them are Strings. A worker
   that passes the Strings through as values and the Ints raw would remove the untag and retag work
   each byte (about 9 instructions) and free registers.
2. **Unswitch on invariant guards.** Test the strings once in the preheader. If both pass, run
   a copy of the loop whose guards are known true; otherwise run the original. No predicate then needs a
   register in the loop.
3. **Cold calls.** A slow-path C call could save its live values around itself instead of
   forcing every loop value into a callee-saved register. The loop would then use the caller-saved bank.

## Checks

Every base job passes on this change, apart from the four known-red ones. Updated expectations:

- **`check_typed_case`.** On a64mac the header test may now be fused into its branch, so there is no
  out-of-line `varno` label. The check accepts either form: the Int bit, then one header load at +0.
- **`tests/compile_budget.json`.** Allocation is now 2-3% lower on every program. `hello`'s peak residency is
  48 MB, the same as at `69d893a0`. The 28 MB recorded earlier today was an outlier, so the budget is rerecorded.

## Second round: the three next steps (12 November, later)

### Two measurement mistakes, corrected

Both mistakes affected the "no effect" results above, so they are recorded here:

- **Builds piped into `head`.** `make fpr 2>&1 | grep " error" | head` lets `head` exit early. GHC's
  partial-function warnings contain "an error", so `head` filled up and `make` died of SIGPIPE before relinking `./fpr`.
  Measurements and checks then ran a stale compiler. Builds now write a log file.
- **zsh does not split words.** In `env $m ...`, a `$m` holding two flags set one variable whose value was the rest of the string.
  Every combined-flag measurement was wrong, including "early loops plus motion change nothing". The loop now uses `${=m}`.

### Step 2, versioning on invariant guards: done

`Codegen.StringScan` handled one string scanned by one header test. It now versions any counted
loop whose String reads are each bounded by an exit test `i >= n`, with n invariant, that dominates all of that
string's reads. Each string may have several such tests, and the exits may be any blocks: the whole body is copied once,
up to 48 blocks and 320 instructions. The dispatch checks, without trapping:

- `i >= 0`;
- each string's one-word header;
- for each string, that some bounding `n` is no larger than its length.

Any miss runs the original CFG. In the copy each read is a bare indexed byte load.

`tests/StringScan.hs` adds a two-string compare. The versioned copy has no read checks, and it agrees with
the original in the evaluator on 1,600 combinations of valid and invalid strings, indices and limits. All earlier cases
still pass, including the refusals (inclusive bound, stride two, descending, changing bound, mixed back edges)
and the trap orders.

### Step 1, untagged Ints: done, more generally than planned

Instead of mixed scalar workers, a loop pass, `LoopOptimize.carryRaw`, gives a header parameter that every back edge passes as a fresh
`OTag x` a raw companion:

- the preheader passes the untag of the arrival;
- each back edge passes its `x`;
- every `untag p` reads the companion.

By induction the companion equals `untag p` on every iteration, for any arrival (untag is total), so the result is exact.
When nothing else uses the tagged parameter, it is dropped along with the back edges' tags. This applies to every IR loop, not only workers.

### Defaults

Early loops and String-scan versioning are now on by default. Each is turned off by setting its flag
to `0` (`FPR_TYPED_IR_EARLY_LOOPS`, `FPR_TYPED_IR_STRING_SCAN`). Loop motion stays opt-in
(`FPR_TYPED_IR_LOOP_MOTION=1`). On the six apps it is worth at most 1% (wordfreq) and nothing elsewhere,
and it is the most expensive of the three to compile. When it is on, a versioned function is moved
again after versioning, because its fast copy has no slow-path calls and its invariants then fit.

| `myCmp` microbenchmark (instructions, including ~0.65 G of setup) | |
|---|---|
| before this round | 2.122 G |
| early loops | 2.059 G |
| early loops + versioning (the default now) | 1.493 G |
| + loop motion (opt-in) | 1.404 G |

In the default build the fast loop is about 20 instructions a byte, down from 51: the two limits' untags stay in it. With motion (which hoists them) it is 16:

- two limit compares;
- two byte loads, each with an address add;
- the byte compare;
- the increment;
- the fuel tick;
- the back-edge copy.

What remains against C (about 5-6) is an add-immediate, an indexed byte load with the offset folded into a
hoisted base, the back-edge copy, and the fuel tick, which the runtime contract requires.

Apps (default build): csv 13.1 -> 12.33 G instructions, wordfreq 13.4 -> 11.66 G. Map keys mostly differ
in their first bytes, so per-call costs dominate there, not the per-byte loop.

### Qualifying the defaults

Turning early loops on changed what several checks pinned. None of these is a behaviour regression:

- **The self-loop checks (A64, X64, RV64) and the ARC tail-loop check.** These expected the backend's
  `m3loop` label unless early loops were explicitly on. They now expect it only when early loops are off.
  The ARC check accepts either loop form, as long as the function never calls itself.
- **`check_tick_batch`.** It counted static tick sites. An early IR loop has one at entry and one per back
  edge (the filter loop's keep and skip make two), but still runs one tick per iteration. The check now
  asks for no more than that, and for fewer than the unbatched build.
- **`check_bump_refills`.** It tests refill-tail sharing in the backend's own loop form, so it pins early
  loops off. Under an early IR loop one refill call falls outside the shared tails. That costs code size only;
  spills are 18 either way.
- **`CompilerOptions`.** It checks that each flag changes the cache tag (now `=0` for the two defaults), and that the
  default tag stays empty: the suffixes are now `-noearlyloops` and `-nostrscan`.

`codegenRev` is 217. The passes skip functions with nothing to do: versioning looks for String byte reads,
and the raw-Int and motion passes look for a cycle (a linear walk) before computing dominators. The darwin
compile budget passes without being re-recorded: `std-live` is +4.4% against the baseline, and `main`
itself is now +2.5% from the concurrent actor-runtime commit.

### Step 3, saving registers only around slow calls: not needed for these loops

With versioning, the fast copy has no calls, so all its values fit in registers. The pressure problem
remains for loops that cannot be versioned, where a slow path calls C and every live value must sit in a
callee-saved register. That is a register-allocator change (saving live values around a cold call). It is
left until a loop shows the need: none of the six apps does now.

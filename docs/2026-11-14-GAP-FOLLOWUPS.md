# Gap follow-ups: inline call regions, known comparators in lookups

Date: 14 November 2026. Kind: implementation record. It follows
[gap items 4-6](2026-11-14-GAP-ITEMS-4-6.md), whose "Not done" list and closing
suggestions were taken up next:

- **Call-region bookkeeping.** An inline path for `$callPend`/`$callLeave`.
- **`Map.get` and known comparators.** A version for a known comparator, guarded at run time.
- **`Option`/`Result` in registers across units.**
- **Substring views.**

## Summary

Four changes, measured on the app workloads. A fifth experiment was reverted.

1. **Call regions pushed and popped inline (AArch64).** `$callPend` pushes its pending entry in generated code, and `$callLeave`
   pops an entry whose region never opened, including the tail-call form. The runtime is called only otherwise.
2. **`Order.string` inlined into owned-map walkers; `strCompare` a word at a time.** The comparator inline from the
   last record now follows small helpers first, so `Order.string = fromInt (strCmp a b)` qualifies. The primitive compares
   8 bytes at a time with no libc call.
3. **Map lookups by a known comparator.** When every empty map a unit names carries one comparator, `Map.get`,
   `getOr` and `member` check the map's comparator once per call (`$fnIs`). When it matches, they walk a private copy
   with the comparator inlined.
4. **Two zeroing costs.** The allocator's rounding pad is cleared in words instead of by `memset`, and the copy-out's
   sharing table is no longer cleared between its two passes.

`codegenRev` is 225 and `fpr_hart_t` has a new cell 61 (`pend_stack`).

Apple M4. Instructions are from `/usr/bin/time -l`. Times are the best of 3 under background load, so treat them as rough. "Before" is `main` at
`6d813c11`.

| App | instructions before | after | time before | after |
|---|---|---|---|---|
| csv | 6.45 G | 6.07 G | 0.28 s | 0.27 s |
| wordfreq | 6.74 G | 5.83 G | 0.43 s | 0.38 s |
| treemap | 2.80 G | 2.30 G | 0.32 s | 0.29 s |
| records | 2.90 G | 2.88 G | 0.30 s | 0.31 s |
| format | 2.69 G | 2.70 G | 0.13 s | 0.13 s |
| sim | 4.65 G | 4.65 G | 0.16 s | 0.16 s |

All outputs match `expected/`, as do the std/hashmap and MutMap variants. No RSS changed.

## 1. Inline call regions

- **The cost before.** A profile of csv (the `sample` tool on 8 copies of the input) put `g_call_pend`, `g_call_leave` and
  `fpr_acb_pends` at about 11% of the main thread's samples. Each pair was two C calls. Each call found the
  running actor's pending stack through `fpr_acb_pends` and the current pool through the override slot.
- **The cell.** `fpr_hart_t` gains `pend_stack`, hart cell 61, right after the bump window. It holds the running actor's
  pending stack, as `pends_of` answers it, or 0.
  - **Who writes it.** Only `g_call_pend` and `g_call_leave` set it. The three places in `actors.c` that change
    `h->current` clear it, beside their `fpr_bump_close`, as does `hart_init`.
  - **Why it can't go stale.** It is never another actor's stack.
- **The fast path.** While the cell and the bump window are both open, generated code pushes
  `{0, window's slab owner, its allocated gauge, no scope}`: the bump window's slab owner is the current pool by
  the window's own invariant. It pops an entry whose `scope` is still 0. A full stack, a closed window, an opened
  region or an out-of-order token all take the old call, which panics as before.
- **The tail form.** A `$callLeave` in tail position is tested before the epilogue. The fast case returns the result;
  any other unwinds and jumps to the runtime as before. Without this, every function ending in its last call's leave
  (`toInt`, `split`) still called the runtime.
- **Where it applies.** It is emitted where the bump allocation is (hosted Base on AArch64, `x28` hart). The builtin
  heap and the shared plane never set the cell, so their code always takes the call.

csv 6.45 -> 6.11 G, wordfreq 6.74 -> 6.64 G. Pend/leave no longer appears in csv's profile.

## 2. Order.string inlined; strCompare by words

- **Before.** The previous inline needed the comparator itself to be an if-tree of constructor leaves. `Order.string`
  calls `fromInt (strCmp a b)`, so it was called at every node.
- **Expansion.** Reuse `expandCmp` now inlines up to two levels of saturated calls to small (40 nodes or fewer),
  non-recursive globals in the comparator's body. Each inlined body gets fresh binder names.
- **Leaves.** The leaf walk (`ctorLeaves`/`mapLeaves`) passes through lets.
- **Bodies.** `mapBodiesOf` hands Reuse those helpers' bodies: two levels of references from the comparators.
- **Result.** The walker computes `strCompare` and branches on its sign, with no call to `string` and no `Ordering`.
- **`g_strCompare`.** It compares 8 bytes at a time: unaligned loads, then a byte swap to order the first word that
  differs. That works on every little-endian target and needs no libc. The trailing bytes are compared one at a time.

csv 6.11 -> 6.03 G, wordfreq 6.64 -> 5.79 G (0.42 -> 0.37 s).

## 3. Lookups by a known comparator

Owned walkers already knew their comparator, but lookups did not. `Map.get` on a tree of 1,000,000 keys still made a
generic call per node.

- **When it applies.** The condition is the one `directComparator` uses: every empty map the unit names (`strings@`,
  `ints@`, `empty@` of std/map or std/hashmap) carries exactly one known global comparator g.
- **What is generated.** For std/map's `get`, `getOr` and `member`, Reuse writes two private functions:
  - a copy of the lookup, `$worker.maplookup.get@...`;
  - a copy of its walker (`getGo` etc.) with the comparator parameter removed, its calls made direct, and g inlined
    as in change 2.
- **The guard.** The lookup copy calls the walker copy only when `$fnIs cmp g` holds, and the original walker
  otherwise. `$fnIs` is a new runtime primitive (`runtime.c g_fn_is`). It answers whether two function values are
  closures over the same code with nothing captured. It costs one C call per lookup, not one per node.
- **Inlined lookups.** A saturated call to a std/map walker that inlining has already exposed (treemap's
  `Map.get` was inlined into its loop) gets the same guard in place.
- **Why the guard is needed.** A map built by another unit can carry any comparator. `Map.fromList (Order.reverse Order.int)`
  takes the general walk and finds its keys. `tests/std/maplookup` checks this for:
  - a reversed comparator;
  - one built with `Order.by`;
  - `Order.int` maps built in std/map itself.

treemap 2.80 -> 2.31 G (0.32 -> 0.30 s).

## 4. Zeroing

- **The allocation pad.** `alloc_zero_pad` sent every pad other than exactly one word through `memset`, and every String
  has such a pad. The pad is now cleared inline: single bytes up to the next word, then whole words. The payload is
  never touched, a contract `check_alloc_fast` checks. My first version cleared from the start of the word holding
  the pad's first byte; that check caught it.
- **The sharing table.** The copy-out's table (`dc_share_t`) was cleared again between the sizing pass and the copy
  pass: a `memset` of the whole table at every shared cycle. Keys now carry the pass in their low bits: 1 for sizing,
  2 for copy.
  - **Why the second clear can go.** The copy meets only cells the sizing counted, at the end of the same probe
    chain, so it takes over their slots and the second clear is gone.
  - **The guard.** A full table panics rather than probing for ever. It cannot fill, because the sizing pass stops at
    3/4.

Together these are within noise in instructions (csv 6.03 -> 6.07 G with the byte-exact pad clear). They remove a libc
call per String allocation and a table-sized `memset` per shared cycle, which instruction counts understate.

## Tried and reverted

**`toInt`'s digit loop.** I tried reading `intMin` once and dividing only within one step of the limit. The answers were
unchanged on a boundary grid, but csv did not move (6.030 -> 6.025 G), so `std/string` is as it was.

## Not done

- **`Option`/`Result` in registers across units.**
  - **Why.** Variant returns stay private. Checked code clones imported bodies only in the typed callback specializer
    (`Core/Typed/Callback.hs`), which verifies every clone it makes. The untyped Mono pass, which a first attempt
    extended, does not see the checked program.
  - **What it would take.** Cloning a small imported function with a variant result, with no callback involved, means
    teaching the typed specializer that case. That is a change to a verified pass and was not attempted here.
  - **What it would save.** For csv, one Result cell per `toInt`: about 2 M allocations of 6.0 G instructions.
- **Substring views.** These are unchanged from the last record: a new String representation, or a local slice
  analysis for the `split`-then-consume pattern.
  - **Their share of csv.** In today's csv profile, splitting and its substrings (`splitCharGo`, `split`, `g_substr`,
    their allocation) are about 15% of the samples.
  - **What's ahead of them.** The map walk and `strCompare` together are about 40%.
- **csv's walker.** The update function is inlined into it, which makes the walker about 3,000 instructions. Its samples are spread
  across that code with no single hot spot.

## Checks

- **Native suites.** `cabal test all` passes.
- **Apps.** All app outputs match, including the hash-map and MutMap variants.
- **x86-64.** `tests/std/maplookup` and treemap built for `macos-x86_64` match under Rosetta.
- **std golden tests.** 39 of 45 match. The six that differ (apps, durable, http, kvwire, posix, supervisor) differ on
  `main` too. `tests/std/maplookup` is new and matches.
- **Legacy checks.** The checks from `1b4aca16^` were overlaid and run per job: 217 of 234 pass. The 17 failures are
  the expected ones from the previous record: the 14 that failed before it, plus `sol_core_build`, `typed_case` and
  `linked_stack`. `regionnest` and `pendreset`, which exercise call regions, pass.

# Closure applies, copy-out table sizing, variant clones

Date: 15 November 2026. Kind: implementation record. It takes three of the structural items proposed after
[the gap follow-ups](2026-11-14-GAP-FOLLOWUPS.md), against the
[x64 profile](2026-11-14-PERFORMANCE-PROFILE.md)'s measurements:

- **Item 3.** Applies of closures that hold captured arguments.
- **Item 6.** Zeroing of copy-out targets.
- **Item 2.** Copying small imported functions into the calling unit.

## Summary

Four changes. `codegenRev` is 235.

1. **A64: closures with captured arguments applied inline.** An exact-arity apply whose function value holds 0, 1 or 2
   captured arguments now calls its code inline: captured arguments go in the first registers, then the pushed ones.
   Before, only capture-free values took the inline path. Three or more captured arguments, a partial apply, or one with too many arguments still go
   through `fpr_applyN`.
2. **Copy-out's sharing table sized by the walk.** The table was sized from the arena, everything allocated since the
   last reset. Every distinct cell is at least 16 bytes, and the first tree walk counts each one at least once. When that walk finishes
   under the cap, its count bounds the table, which is usually far smaller. The clear before the table's first use is a `memset`
   that touched pages the size of the whole arena.
3. **The runtime applies two- and three-argument closures at once.**
   - **Before.** MutMap's `insertWith`/`alter` combine (`mm_apply2`), `MutMap.fold`, `Vec.fold` and the `Sys.loopWith` stepping applied one argument at a
     time. That built and freed a partial application per call.
   - **Now.** They use `fpr_apply2`/`fpr_apply3`, which call the code directly when the closure takes exactly that many more arguments.
   - **The other cases.** They free only a partial application `fpr_apply` built itself. The old `mm_apply2` also freed a closure that `f`
     returned, which could still be held elsewhere.
4. **Variant clones.** The typed callback specializer copies a small (160 nodes or fewer), non-recursive imported function into the
   calling unit even without a callback, when its result is a sum type that is not recursive and has a constructor with
   fields. That covers `Option`, `Result` and similar types, and the private copy can then be inlined or return its variant in registers.
   - **Where it applies.** Only the program's own functions get these clones.
   - **Why the limits.** In a first attempt, cloning inside std/map's `insGo` broke the owned-map rewriting, which recognises std/map's
     functions by name. Cloning `List`-returning functions moved wordfreq's regions (236 -> 281 MB). Cloning
     `Ordering`-returning comparators added code and saved nothing, because those answers are static.

Apple M4, instructions from `/usr/bin/time -l`, against `main` at `c3e7cdea`. Times are best of 5, interleaved, on a loaded
machine.

| App | instructions main | after | RSS main -> after | page reclaims main -> after |
|---|---|---|---|---|
| csv | 5.04 G | 4.97 G | 148 -> 144 MB | 9,699 -> 9,446 |
| wordfreq | 4.99 G | 4.98 G | 240 -> 236 MB | 15,552 -> 15,295 |
| treemap | 2.27 G | 2.22 G | 76 -> 60 MB | 5,037 -> 4,012 |
| wordfreq_mutmap | 2.93 G | 2.33 G | 231 MB | flat |
| treemap_hashmap | 2.65 G | 2.60 G | 161 -> 141 MB | 10,476 -> 9,204 |
| records | 2.18 G | 2.13 G | 125 MB | flat |
| format | 2.88 G | 2.88 G | 394 MB | flat |
| sim | 4.66 G | 4.65 G | 4 MB | flat |

wordfreq_mutmap: 0.17 -> 0.14 s. All outputs match `expected/`, including the hash-map and MutMap variants.

## Where each gain came from

- **The sharing table** gives the RSS and fault drops, for treemap and treemap_hashmap especially.
- **`fpr_apply2`/`fpr_apply3`** give wordfreq_mutmap's 21%. Its combine closure is applied from C inside
  `MutMap.insertWith`, not from generated code, so change 1 does not reach it.
- **The inline apply** is a small gain across the apps that apply closures from generated code.
- **The variant clones** fire as intended. For example, csv's loop calls `toIntGo` itself and reads the number with no
  `Result` cell. But the cell they remove was a cheap inline allocation, so the instruction gain is within noise.
  They are kept for what they enable (inlining small imported functions) and because they cost nothing measurable.

## Checks

- **Unit tests.** `make unit-tests` passes.
- **Sol suite.** `sol tests/run.sol`: 17 checks, 0 unexpected outcomes.
  - `result-sizes:allocation-counters` is a listed known failure. Here it counts fewer allocations than its expectation
    (1 request where it wants 3).
  - The four `trust` entries are listed known failures.
- **Applies.** A targeted program applied closures with 0 to 3 captured arguments taken from a list, so through the generic apply, including partial
  application and a MutMap fold. Its output equals `main`'s, on arm64 and on x86-64 under Rosetta.
- **x86-64.** csv and wordfreq_mutmap built for `macos-x86_64` match their expected outputs under Rosetta.

## Not done

- **Raw values in hot loops** (item 1 of the proposal: unboxed scalar fields and register-preserving slow paths). This is
  sim's gap, and it is a representation change awaiting a decision.
- **Region placement that knows what allocates** (item 4) and **destination passing for `x :: f(...)`** (item 5).

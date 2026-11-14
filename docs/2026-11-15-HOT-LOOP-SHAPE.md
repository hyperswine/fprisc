# sim's hot loop: one decision tree, cold slow paths, no slow-path register pressure

Date: 15 November 2026. Kind: implementation record. It takes item 1 of the structural proposal (raw values in hot loops),
following [closure applies, copy-out sizing, variant clones](2026-11-15-CLOSURES-COPY-OUT-CLONES.md).

## What the loop cost

sim's work is one loop, `$worker.spineE.cursor…run.0`. It moves 20,000 particles 2,000 times, 40 M particle-steps.
On `main` (`8301010e`) it retired 4.65 G instructions, about 116 per step. Read from the A64 assembly, the no-bounce path was
about 118 instructions:

| what | instructions |
|---|---|
| value-moving blocks (`mov x9, …; b next`) and jumps between joins | ~25 |
| `bounce`'s tests repeated, because its `(x, vx)` tuple was split into one decision tree per field | ~18 |
| the layout test before reusing the particle record in place | 11 |
| tagging record fields on load and store | 12 |
| `1000000` built with `movz`/`movk`, four times | 8 |
| overflow checks' result moves and the jump over each inline slow path | 8 |
| frame spills (the slow-path C calls used up the callee-saved registers) | 5 |
| the loads, adds, compares, stores and fuel tick themselves | ~30 |

So unboxed fields, the change the proposal named, were worth about a tenth of the loop. Most of it was control flow and register use, which the backend can fix without changing any representation.

## Changes

`codegenRev` is 236.

1. **A tuple-valued if-tree joins once (`LocalPacks`).** `localProducts` (Core/Opt/Pipeline.hs) avoided allocating
   the tuple by copying the tree once per field, so `bounce` tested `p < 0` and `p > 1000000` once per field.
   - **Now.** With private products available, a new last pass turns the leaves of a two- to eight-field tree into
     `$product.packN`. `Codegen.Lower` already lowers that as one join block with a parameter per field.
   - **Unchanged.** The early pass keeps the copies for one-field trees, and for every tree when private products are off.
   - **Why the pass runs last.** Earlier passes never saw packs, and Reuse treats any unknown call as a possible pool reset.
2. **Forwarding blocks bypassed** (Codegen/Simplify.hs `forwardEmptyBlocks`). A block with no instructions that only
   jumps on (`b7(x, y): br b8(x, y)`) is skipped: its predecessors jump straight to its target with the arguments
   substituted.
   - **When a block stays.** If any other block reads one of its parameters directly, because the block dominates that reader. My first
     version missed this, and `tests/std/store` caught it.
   - **Where it runs.** Second in the pass list and again last.
3. **One header load for a tag test (A64).** An `OTagTest` whose typeid and variant are both in [0, 2^31) compares the
   8-byte header in one load, as `OVariantTest` already did. Two sign-extended loads and two compares become one of each.
4. **Cold slow paths (A64).** Checked arithmetic rendered `b.ne slow; …; b done; slow: …; done:`. The slow segment now
   moves to the end of the function and jumps back, so the fast path loses one jump per check. This is a rendered-text step
   (`coldSlowPaths`), after the tick analysis, which it leaves an upper bound.
5. **Arithmetic slow paths never return (A64).** The slow path runs only after the fast path has seen the overflow or the
   zero divisor. The C primitive it calls then always traps: `int_overflow` and `fpr_trap` are `noreturn`.
   - **Selection.** It is now selected as a noreturn transfer (`trapPrim`), as the kernel traps already were, so nothing is live
     across it.
   - **Effect.** The loop's values no longer have to live in callee-saved registers. Its frame went from 112 bytes with eight saved
     registers to 48 bytes with three, and its spills from three to none.
   - **Messages.** The panic text and exit status are unchanged for `+`, `-`, `*`, `/`, division by zero and the immediate
     forms, on arm64 and x86-64.

## Results

Apple M4, instructions from `/usr/bin/time -l`, against `main` `8301010e`, outputs checked against `expected/`:

| App | instructions main | after | time main -> after |
|---|---|---|---|
| sim | 4.65 G | 3.03 G | 0.15 -> 0.09 s |
| csv | 4.96 G | 4.91 G | flat |
| wordfreq | 4.97 G | 4.91 G | flat |
| treemap | 2.22 G | 2.16 G | flat |
| records | 2.12 G | 2.10 G | flat |
| format | 2.86 G | 2.82 G | flat |
| wordfreq_mutmap | 2.31 G | 2.26 G | flat |
| treemap_hashmap | 2.56 G | 2.50 G | flat |

Per change, on sim: `LocalPacks` 4.65 -> 3.68 G; the header compare 3.56 G; cold slow paths 3.44 G; forwarding
3.24 G; noreturn slow paths 3.03 G. sim's step is now about 76 instructions, against C's 18 (x64).

## Not done

- **Unboxed scalar fields.** About 10 of the remaining 76 instructions are field tags. On hosted targets, raw fields need
  per-field raw/managed metadata in every runtime walker: copy-out, equality, printing, messages, persistence.
  The [RawWord experiment](2026-11-03-PAIR-RAWWORD-EXPERIMENT.md) also found that a type has one representation
  everywhere, so polymorphic containers need clones. Left for a decision.
- **The reuse layout test.** Reuse works on untyped Core and cannot prove the element is always a `P`. It now costs one
  load and a compare instead of two.
- **Constants.** `1000000` and `2000000` are still built in the loop. Loop motion (`FPR_TYPED_IR_LOOP_MOTION=1`) does
  not hoist them here and gives csv about 1%, so it stays opt-in.
- **x64.** Changes 3-5 are A64 only. Changes 1-2 are target-independent and help x64 and RISC-V as well.

## Checks

- **Unit tests.** `make unit-tests` passes. CorePipeline's pass list now includes `LocalPacks`. A TypedIR check expected the threaded
  join's empty block, which forwarding now removes; it now expects the condition to branch straight to the arm.
- **Sol suite.** `sol tests/run.sol`: 17 checks, 0 unexpected outcomes; all 46 std golden cases pass. `result-sizes:allocation-counters` is a listed known failure.
- **Overflow messages.** Overflow and division-by-zero programs print the same message and exit the same way as on `main`, on arm64 and
  x86-64 (Rosetta).
- **x86-64.** sim, records, csv and format built for `macos-x86_64` match `expected/` under Rosetta.
- **RISC-V.** sim compiles for bare-metal RV64. RV32 refuses sim's `1103515245` literal on `main` too.

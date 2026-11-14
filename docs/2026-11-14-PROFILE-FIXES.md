# Profile fixes, first round (14 November)

Kind: implementation record. Follows [the x64 performance profile](2026-11-14-PERFORMANCE-PROFILE.md) and takes its
suggested fixes 1 to 4. Written on an arm64 Mac: **nothing here was timed on x86-64 hardware or on Linux.** The
x86-64 figures are static instruction counts read from the generated assembly, and wall times under Rosetta, which
is a translator and not a guide to a real x86 core. The profile's box should re-measure.

## What the profile got right, and two corrections

* The findings hold against the source: the release call, the cons-recursive `words`/`lines`, the x64 selection waste.
* **`String.words`/`lines` (fix 1) is not x64-specific and no conversion "misses" them.** The typed TRMC pass
  (`Core/Typed/Trmc.hs`) builds front to back only for one shape: an accumulator parameter, every exit `rev acc`.
  It has no rule for a piece consed onto the recursive call. aee9ce39 rewrote `split`, `lines` and `words` into
  that second shape with a comment claiming the conversion, so each piece cost a native frame on every target.
* **Most of fix 4 is the x64 backend trailing the A64 one.** A64 already branched on the flags of a compare, fell
  through to the next block and took small constants as immediates. `charFrom` was 29 instructions a byte on x64
  and 15 on A64 from the same IR.

## Changes

1. **`std/string.fpr`: `split` (both forms), `lines`, `words` gather in an accumulator and exit through `rev`.**
   They are loops again (a loop region each; `rev` runs once at the end).
2. **`machine/unix/host.c`: `hal_heap_release` uses `MADV_FREE` wherever the host defines it**, with `MADV_DONTNEED`
   for a kernel that refuses the advice (EINVAL before Linux 4.5). Lazily freed pages count in the resident size
   until the kernel reclaims them, so a Linux RSS reading can be higher for the same real pressure.
3. **x64 selection (`Codegen/Target/X64.hs`, selection rev 33):**
   * a compare, record test or layout test read only by its block's branch is fused into the branch;
   * the block laid out next is fallen into; a branch side with no block-parameter moves is branched to directly;
   * constants within 32 bits are immediates of compare, add and subtract, and are not made when nothing else reads them;
   * `lea` for add-immediate and for tagging (`2x+1`), base-plus-index byte loads;
   * the 63-bit fit check is a shift and a branch on overflow (was sign-extend, compare, branch), and the fitting
     path branches over the slow path instead of jumping around it;
   * literals use the shortest move; a fuel tick no longer compares after its subtract.
4. **Shared simplifier (`Codegen/Simplify.hs`, codegenRev 233):** a boolean join is threaded when the join tests its
   parameter with a record test for True or False (a `case` on the Bool), not only with `truth`, and an inner join
   that only forwards its parameter (`a or (b and c)`) hands its edges to the outer one. `isSpace` inlined into a
   loop no longer builds `fpr_true`/`fpr_false` and tests the object. All targets.

## Results

Static, x64, instructions per byte in the scan loops (read from the assembly):

| loop | before | after |
|---|---:|---:|
| `charFrom` (csv, `lines`, one-byte `split`) | 29 | 14 |
| `wordEnd`, a non-space byte | about 36 | 15 |

Measured on the M4, 5 interleaved rounds, medians, outputs checked against `expected/`:

| program | arm64 native, before → after | x86-64 under Rosetta, before → after |
|---|---|---|
| csv | 0.247 s / 159 MB → 0.250 s / 149 MB | 0.609 s / 176 MB → 0.624 s / 151 MB |
| wordfreq | 0.385 s / 284 MB → 0.378 s / 240 MB | 0.804 s / 347 MB → 0.737 s / 242 MB |
| wordfreq_mutmap | 0.179 s / 283 MB → 0.163 s / 231 MB | 0.387 s / 346 MB → 0.331 s / 233 MB |
| treemap | 0.318 s → 0.309 s | 0.488 s → 0.476 s |
| treemap_mutmap | 0.180 s → 0.180 s | 0.296 s → 0.301 s |
| sim | 0.167 s → 0.167 s | 0.268 s → 0.250 s |
| format | 0.163 s → 0.161 s | 0.327 s → 0.325 s |
| records | 0.221 s → 0.221 s | 0.453 s → 0.431 s |

csv did not get faster under Rosetta although its scan loop halved; that is unexplained here and is the first thing
to check with callgrind on the x86 box.

Checks: `make unit-tests` 44 suites pass. `sol tests/run.sol`: all pass except `result-sizes`, which fails the same
way on the unmodified tree with the installed sol (a Sol safety error in the check script itself), and the four
listed `trust` known failures.

## Not done

* **Fix 2 is unmeasured** (needs Linux).
* **Loop-head alignment**: no way to see its effect here.
* **x64, still in the hot loops:** the fuel tick reads the hart from TLS each time (A64 keeps fuel in a register);
  a comparison read by two branches is materialized and, in sim, spilled; loop-invariant untags and the dead
  re-tag of the index stay (IR level, A64 has them too); `jmp` to a block that only jumps.
* **`split`/`lines`/`words` without the loop region and the `rev` pass.** The region planner counts `substr` and
  the call to `wordEnd` as scratch, so these loops get a region and TRMC leaves a region loop alone. Teaching the
  planner that a callee never allocates, and that an allocation handed to the next state is not scratch, would let
  TRMC build them front to back with no region.
* Fix 5 (copy-out in in-place loops, direct calls for known closures, a table behind `std/hashmap`).

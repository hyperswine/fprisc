# Pipeline P0: audit of the C and GHC references

Date: 8 November 2026. Kind: audit record, the last P0 deliverable of the
[pipeline refactoring roadmap](2026-11-07-PIPELINE-REFACTORING-ROADMAP.md).
Compiler: `d308c1b` (codegen 204). Host: arm64 macOS (M4), Apple clang 21.0.0,
GHC 9.8.2. Evidence: [bench/pipeline-reference-audit.json](../bench/pipeline-reference-audit.json),
reproduced by `tests/pipeline/reference_audit.py` (`make pipeline-reference-audit`).

P0 asks that the C/GHC reference work and its optimization be audited before
any ratio is treated as an acceptance target, distinguishing scalar from
vectorized and checked from unchecked references. This record does that for
every reference the performance records use: `tests/bench/c/*.c`
(`tools/bench.py --c`) and `tests/bench/unbox/ref.c` + `ref.hs`
(`tests/bench/unbox/measure.py`).

## Method

For each reference the script:

- **Same answer.** It runs the FP-RISC program and the reference and requires
  the same printed value. All 13 C references, in all three builds, and all 8
  GHC references print exactly what FP-RISC prints.
- **Vectorized.** It builds the C reference the way the harnesses do (`-O2`) and
  again with `-fno-vectorize -fno-slp-vectorize`. A default build clearly faster
  than the scalar one (under 0.8x) is marked SIMD.
- **Checked.** It builds the C reference with `-ftrapv`, so signed overflow
  traps. FP-RISC `Int` is a checked 63-bit integer (`Int overflow ... I64 is the
  type that wraps`). `unsafe` in the benchmarks only marks an opaque
  worst-case time and does not turn the checks off.
- **Optimized out.** A reference whose work time is near zero measured nothing.
- **Fused.** It reads GHC's heap allocation. Under 1 byte per element means GHC
  fused the list away.

Times are medians of 5 interleaved runs minus the median of an empty program of
the same kind (process startup). They are on one host only; the 6 November
record used Linux x86-64, gcc and GHC 9.10, so its ratios are not comparable
row for row with these.

## Results (work ms, startup removed)

| Case | Reference | FP-RISC | C `-O2` | C scalar | C checked | FP-RISC / C `-O2` | FP-RISC / C checked | Notes |
|---|---|---:|---:|---:|---:|---:|---:|---|
| fib | `c/fib.c` | 44.1 | 18.3 | 17.9 | 23.2 | 2.41 | 1.90 | |
| byteloop | `c/byteloop.c` | 67.1 | 2.4 | 10.8 | 11.1 | 27.8 | 6.06 | C is SIMD |
| sha | `c/sha.c` | 56.2 | 2.8 | 2.4 | 2.6 | 20.4 | 22.0 | different arithmetic |
| list_sum | `cons_sum` | 15.4 | 14.4 | 16.0 | 14.4 | 1.07 | 1.07 | |
| list_sum | `arr_sum` | 15.4 | 3.8 | 11.1 | 8.1 | 4.04 | 1.90 | C is SIMD |
| list_map | `cons_map` | 16.1 | 60.2 | 58.4 | 68.2 | 0.27 | 0.24 | |
| list_filter | `cons_filter` | 111.5 | 39.3 | 40.9 | 40.0 | 2.84 | 2.79 | |
| list_fold | `cons_fold` | 37.0 | 8.8 | 9.2 | 14.2 | 4.18 | 2.60 | |
| list_length_rev | `cons_rev` | 79.4 | 27.8 | 28.6 | 29.2 | 2.86 | 2.72 | |
| option_loop | `option` | 47.9 | 3.9 | 4.9 | 4.6 | 12.2 | 10.5 | |
| tuple_loop | `tuple` | 68.7 | 57.6 | 57.8 | 57.9 | 1.19 | 1.19 | |
| tree_sum | `tree` | 123.1 | 30.8 | 30.3 | 46.0 | 4.00 | 2.68 | |
| string_scan | `scan` | 38.9 | 3.4 | 5.8 | 6.5 | 11.6 | 6.02 | C is SIMD |

| Case | GHC mode | GHC ms | FP-RISC / GHC | GHC heap bytes per element | Verdict |
|---|---|---:|---:|---:|---|
| list_sum | `sum` | 0.0 | — | 0.0 | optimized out |
| list_map | `map` | 0.5 | — | 0.0 | optimized out |
| list_filter | `filter` | 0.2 | — | 0.0 | optimized out |
| list_fold | `fold` | 24.0 | 1.54 | 3.2 | boxed list, usable |
| list_length_rev | `rev` | 60.4 | 1.32 | 4.4 | boxed list, usable |
| option_loop | `option` | 9.1 | 5.29 | 0.0 | fused, Maybe removed |
| tuple_loop | `tuple` | 99.2 | 0.69 | 48.0 | boxed pairs (fixed, see below) |
| tree_sum | `tree` | 108.0 | 1.14 | 96.0 | boxed tree, usable |

## Findings

1. **Three C references are SIMD: `byteloop`, `arr_sum` and `scan`.** Their
   `-O2` builds are 2-4.5x faster than the same code with the vectorizers off.
   FP-RISC emits scalar loops and the roadmap does not plan vectorization, so
   the `-O2` ratios (27.8x, 4.0x, 11.6x) mostly measure SIMD. The `-ftrapv`
   builds run near scalar speed (11.1 vs 10.8 ms, 6.5 vs 5.8 ms; `arr_sum`
   keeps some vectorization at 8.1 vs 11.1 ms), so the checked column is the
   comparison for these rows: 6.1x, 1.9x and 6.0x. The 6 November "11x C" for
   byteloop used gcc `-O2` on x86-64, which vectorizes this loop from GCC 12
   on; it was probably a SIMD comparison too (not re-measured there).
2. **Every C reference is unchecked.** Overflow trapping costs C 1.27x on fib,
   1.6x on `cons_fold` and 1.5x on `tree` (the extra checks lengthen the
   critical path). It costs little on the others. FP-RISC
   always pays this, so the checked column is the like-for-like target. None of
   the C references bound-checks string or array indexing, while FP-RISC's
   `charAt` does; the byte-scan rows still flatter C by that.
3. **`sha` compares different arithmetic.** `c/sha.c` uses `uint32_t` with a
   one-instruction rotate. `std/digest` emulates 32-bit words on checked 63-bit
   `Int` with masks (`m32`) and four-operation rotates (`rotr`). The 20x gap is
   mostly library representation, not the pipeline. It belongs to a 32-bit word
   type or a digest rewrite, not a P-phase target.
4. **GHC `sum`, `map` and `filter` measured nothing.** GHC fuses the list and
   then reduces each round to (near) closed form: zero heap per element and
   under 0.5 ms of work for 20M elements. They show what fusion can reach, not
   a runtime to compare against. The "about 100x GHC" filter figure in the
   6 November record is therefore not a ratio to target. `cons_filter`
   (2.8x, checked) and the materializing-pipeline record are the comparisons.
5. **The GHC tuple reference was a space leak.** The lazy `step` built a
   20M-thunk chain (3,085 ms on 6 November). `ref.hs` now forces the pair
   components; it runs in 99 ms with boxed pairs (48 B per iteration), and
   FP-RISC's scalar-replaced loop is 0.69x of it.
6. **No C reference was optimized out, and none computes a different answer.**
   `option` and `tuple` are scalar loops in C (no vectorization, no closed
   form). `cons_*` and `tree` use a bump allocator that never frees, which is
   the cheapest possible boxed baseline, not a typical runtime.

## Acceptance targets after this audit

A ratio may be used as an acceptance target only against the reference named
here. Ratios against anything else are informational.

| Workload | Target reference | Today (FP-RISC / ref) |
|---|---|---:|
| calls (fib) | C checked | 1.90 |
| byte scans (byteloop, string_scan) | C checked (scalar) | 6.06, 6.02 |
| fused list sum/map | C `cons_*` checked; `arr_sum` checked as the unboxed ceiling | 1.07 / 0.24; 1.90 |
| filter, fold, reverse | C `cons_*` checked; GHC `fold`/`rev` | 2.79, 2.60, 2.72; 1.54, 1.32 |
| Option loop | C checked; GHC `option` (fused) | 10.5; 5.29 |
| tuple loop | C checked | 1.19 |
| trees | C checked; GHC `tree` | 2.68; 1.14 |

Not targets: any `-O2` ratio on a SIMD row, `sha` against `c/sha.c`, GHC
`sum`/`map`/`filter`, and the pre-fix GHC tuple figure.

## Targets beyond this host

`bench/pipeline-baseline-rv64.json` now records the corpus's RV64 compile facts
(`tools/pipeline-baseline.py --record --target=rv64`): all 19 entries lower
every function natively, with per-function frame, spill and segment facts and
assembly size for each. They are compile facts only. RV64 behaviour, timing and
allocation counts are not executed by the recorder (this host has
`qemu-system-riscv64` for bare-metal oracles but no Linux userspace emulator),
and the file says so. The Pi 4B (QOS A64) and the Tang Nano 20K stay
unverified in the baseline: the Pi is the live QOS deployment host and the
board needs vendor synthesis. Both have their own physical qualification
records; neither is counted as a pass here.

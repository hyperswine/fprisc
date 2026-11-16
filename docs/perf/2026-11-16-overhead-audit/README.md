# Compiler and runtime overhead audit, 16 November 2026 (WIP notes)

Kind: measurement notes and scratch, on the branch `ari/overhead-audit-2026-11-16`. Not a design decision.
Compiler, runtime and std: `origin/main` at **18fce327** ("Open 0.15.0-dev"). Measured on the **Linux x86-64** box
(Debian trixie, 8 vCPU VM, no hardware PMU). Every 14-15 November record was measured on an Apple M4 or under Rosetta;
none of them was timed on Linux x86-64, so these are the first x86-64 numbers for that work.

Method:

- Wall time: `tools/timeit.py.txt`, interleaved FP-RISC / C runs, median of 5 (apps) or 3 (CLBG), stdout md5 compared
  (all 16 programs match C). RSS comes from `wait4`, and the child's figure includes the forked Python's footprint
  (about 17-42 MB), so only the large FP-RISC values mean anything.
- Instructions: `valgrind --tool=callgrind --dump-instr=yes` gives exact counts. `tools/classify.py.txt` joins each
  executed instruction with `objdump` and puts it in a rough class (fuel, tag/untag, overflow check, frame, ...).
  The classes come from a regex heuristic, so treat them as approximate shares.
- C is `cc -O2` (gcc 14). The apps inputs (`sales.csv` 15.8 MB, `corpus.txt` 19.3 MB) are the 14 November profile's.
- Callgrind sizes for CLBG are reduced where the default would take minutes under valgrind: nbody 500k steps,
  spectralnorm 1000, mandelbrot 1000, binarytrees 16. The rest use their defaults.

## 1. Where we stand (ratios against C)

| program | wall fpr / C | instructions fpr / C | 14 Nov x64 instr ratio (3485b92f) |
|---|---:|---:|---:|
| sim | 0.177 / 0.039 s = 4.5x | 3.573 G / 0.722 G = 4.95x | 9.3x |
| csv | 0.456 / 0.036 s = 12.7x | 4.452 / 0.278 = 16.0x | 21.3x |
| wordfreq (std/map) | 0.927 / 0.097 s = 9.6x | 4.888 / 0.475 = 10.3x | 13.5x |
| wordfreq_mutmap | 0.418 / 0.093 s = 4.5x, RSS 231 MB | 2.462 / 0.475 = 5.2x | - |
| treemap (std/map) | 0.856 / 0.126 s = 6.8x | 2.087 / 0.286 = 7.3x | 11.0x |
| treemap_mutmap | 0.350 / 0.120 s = 2.9x | 2.324 / 0.286 = 8.1x | - |
| records | 0.786 / 0.230 s = 3.4x | 2.328 / 1.146 = 2.0x | - |
| format | 0.652 / 0.226 s = 2.9x, RSS 394 MB | 2.814 / 2.565 = 1.1x | - |
| binarytrees | 0.828 / 1.113 s = 0.7x | 0.60x | - |
| fannkuchredux | 0.889 / 0.199 s = 4.5x | 10.4x | - |
| nbody | 1.165 / 0.221 s = 5.3x | 6.7x | - |
| spectralnorm | 1.102 / 0.195 s = 5.7x | 6.8x | - |
| mandelbrot | 2.567 / 0.991 s = 2.6x | 3.2x | - |
| fasta | 0.604 / 0.328 s = 1.8x | 5.6x | - |
| knucleotide | 1.202 / 0.252 s = 4.8x, RSS 216 MB | 8.1x | - |
| revcomp | 0.305 / 0.064 s = 4.8x, RSS 129 MB | 6.6x | - |

Geometric means: CLBG wall **3.2x** C on x86-64 (the 0.14.0 record gives 2.4x on the M4), CLBG instructions 4.8x,
apps wall 5.1x, apps instructions 5.2x. Since 14 November the app instruction counts fell 26-47% on x86-64.

## 2. Hot loops at HEAD (x86-64, from callgrind plus the disassembly; listings in raw/hotloops)

- **sim** (`$worker.spineE.loop.$loop.in.run`, 98.5% of instructions): **88 instructions per particle-step**, against
  about 18 for the whole C program (0.722 G / 40 M). The loop already reuses the cell in place and allocates nothing.
  What remains:
  - 12 for the cons test, which materialises a Bool with `sete`/`movzbq` and then tests it again;
  - 9 for a dynamic layout check before the in-place write (tag bit, type id, variant), on a cell whose layout is
    statically known;
  - about 16 for untag and retag (`sar`, `lea 1(x,x)`) and four `shl`+`jno` overflow checks;
  - 7 frame spills and reloads, 3 for the fuel tick, and several redundant `mov` chains.
- **wordfreq/csv byte scan** (`wordsGo`, 18% of wordfreq; `charFrom`, 14% of csv): **33 instructions per byte**.
  Removable work in every byte:
  - a loop-invariant "is this a String" check (6), plus re-untagging the length (2);
  - a second bounds check after the loop test has already done it (4);
  - the fuel tick (3), and an index carried both tagged and untagged.
- **treemap lookup** (`maplookup.getGo`): about 24 instructions per tree level. It re-untags the key on every level,
  loads all four node fields eagerly, and ticks fuel.
- **treemap insert** (`mapown.walk.insGo`, 72%): about 160 instructions per level, a non-tail recursion. Of the 301
  hot instructions, 46 are frame loads and stores.
- **mandelbrot** (`inSet`, 92%): 45 instructions per iteration, of which only 9 are float operations. 21 are
  `movq` between general and xmm registers, or `movabs` of a constant. **x64 has no float register class**: the
  "floats in float registers" change of 07cd2bca was A64 only (docs/2026-11-15-VECTOR-VIEWS-BUFFERED-OUTPUT.md §5).
- **nbody** (`advance`, 99%): about 328 instructions per body pair, against about 60 in C. Of those, 53 are gpr<->xmm
  moves, 64 are frame operations and 21 are inline bounds checks.
- **fannkuchredux**: 16% of instructions are in the C allocator, `alloc_in_size` (11.5%) and `free_block` (4.4%).
- **knucleotide**: 37% is in the C MutMap (`g_mutmapInsertWith` and `mm_find`), applying the closure through C.
- **Kernel page zeroing** (`clear_page_erms`, perf cpu-clock share): csv 20%, wordfreq 15%, wordfreq_mutmap **43%**.
  This is the cost of the footprint: memory touched once and never reused.
- **`g_strCompare` (C)**: 34% of wordfreq's time (18% of its instructions) and 9% of csv's.
- Copy-out walks (`kp_reaches`): 3.5% of treemap, 2.9% of wordfreq and 5.6% of wordfreq_mutmap instructions.
- **Fuel ticks**: still a TLS load plus a memory read-modify-write on x64 (`mov %fs:..,%r10; subq $n,(%r10); jg`).
  A64 (x27) and RISC-V (s11) keep the counter in a register since #67.

## 3. Actors (x86-64)

- `pingpong`, 1 M round trips on one hart: 0.977 s median, about **980 ns per round trip**.
- `xpingpong`, the same across two harts: 1.013 s.
- Both use about 2.1 s of user CPU for 1 s of wall time. The idle side spins: `block_unless` is 26% and `p_any` 10%
  of samples. `chan_for` (12%) and `fpr_send_as` (11%) lead the real work.

(Runtime blocking table and plan: see the parent summary; to be added to this file in the next chunk.)

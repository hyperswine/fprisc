# Sizing walks in owned loops, layout lookups, string compare and copy

Date: 15 November 2026. Kind: implementation record. It takes the first follow-up of the
[x64 profile](2026-11-14-PERFORMANCE-PROFILE.md) (lighter copy-out in in-place loops) and its runtime string bucket
(`g_strCompare`, `g_substr`), after [closure applies, copy-out sizing, variant clones](2026-11-15-CLOSURES-COPY-OUT-CLONES.md).
All changes are in the C runtime (`runtime/runtime.c`, `runtime/mod.c`, `runtime/vec.c`). No compiler change, so `codegenRev` stays 236.

## Summary

Apple M4. Instructions are from `/usr/bin/time -l`, the smallest of 3 runs. Baseline is `main` at `93a9faba`.

| App | instructions before | after | change | peak RSS before -> after |
|---|---:|---:|---:|---|
| treemap | 2.161 G | 1.957 G | −9.4% | 60 -> 44 MB |
| treemap_hashmap | 2.527 G | 2.281 G | −9.7% | 141 MB |
| csv | 4.936 G | 4.622 G | −6.4% | 144 MB |
| csv_hashmap | 4.249 G | 4.054 G | −4.6% | 145 MB |
| wordfreq_mutmap | 2.280 G | 2.176 G | −4.6% | 231 MB |
| wordfreq_hashmap | 3.436 G | 3.283 G | −4.5% | 238 -> 234 MB |
| wordfreq | 4.935 G | 4.720 G | −4.4% | 236 -> 232 MB |
| treemap_mutmap | 1.808 G | 1.821 G | +0.7% | 159 MB |
| records, format, sim | | | within 1% | unchanged |

Wall times are in [the last section](#wall-times). All outputs match `expected/`.

## 1. A quick sizing walk also stops under the written root

**What it cost.** A loop that writes its map in place (an owned-map twin) asks at its back edge whether copying its state out
would free enough. The answer comes from a sizing walk, and a state that mostly survives declines the copy.

- After the first decline, the walk is *quick*: it stops as soon as more than the limit (1/16 of the arena) is known to survive.
- The stop was only checked for cells counted under the region's visit rule. Under the written root that rule is off (the
  structure has one holder, so it is copied whole), and nothing else bounded that part of the walk.
- So an owned map was walked to its last cell at every retry, then walked a second time with a sharing table, to reach a
  decline that its first sixteenth already showed.

Measured in treemap's insert loop: five walks, all declined, the last over a 16 MB map. They took 20 ms of 288 ms, and the
sharing table was most of the 16 MB of extra peak RSS.

**The change.** `dc_size_in` counts the cells under the written root against the same limit while the walk is quick
(`dc_size_quick`). Once a quick walk finishes under the limit, the flag is cleared so the walks that follow count every cell.
The decision is the one the full walk reached: more than the limit survives, decline. Only the first walk of a run is still full.

| App | sizing walks at the back edge, before | after |
|---|---:|---:|
| treemap | 20 ms, 1.16 M cells | 1 ms, 66 k cells |
| treemap_hashmap | 21–42 ms, 2.15 M cells | 3 ms, 122 k cells |
| wordfreq | 3 ms | under 1 ms |

## 2. Recent answers ahead of the layout table's hash probe

With compact cells, a cell's size comes from its constructor's field count, which `fpr_layout_fields` reads from a hash
index. Every copy and every sizing walk asks once per cell (`fpr_layout_fields`, `layout_find` and `layout_total` were 2.6% of
treemap's and wordfreq's instructions in the profile), and a structure has a handful of constructors.

`fpr_layout_fields` now keeps 64 recent answers, one word each: the key in the high 48 bits and the field count in the low 16.
An entry is a fact of the grow-only table and is read and written whole, so harts need no lock, and a lost write only costs a
probe. Keys or counts too large to pack skip the cache.

## 3. String compare: the last word read whole, the first byte first

`g_strCompare` compared whole words, then finished byte by byte. Map keys are usually shorter than a word, so most compares
were only the byte loop.

- **The last word.** A String's bytes start on a word boundary of its cell, so the word holding its last byte lies in the
  same eight aligned bytes and never crosses a page. The compare reads that word whole and masks off what follows the last
  byte. A cell that is not word-aligned takes the byte loop, as before.
- **The first byte.** A first version without this was slower on wordfreq (0.354 -> 0.374 s) although it retired fewer
  branches. The branch a map walk takes on the answer is a guess either way, and the word path delivers the answer a few
  cycles later than a one-byte compare did. Unrelated keys usually differ in their first byte, so that byte is tested first.
  With it, wordfreq is 0.344 s.

`MutMap`'s key equality (`mm_key_eq`, `runtime/vec.c`) uses the same whole-word compare.

## 4. Short strings copied as words

`fpr_mkstr` copied byte by byte, which the compiler turns into a `memcpy` call. Most Strings made there are a field or a word
cut from a line by `substr`. Up to 32 bytes are now copied as words, the last overlapping the one before, and nothing is read
past the source's end. Longer strings still go to `memcpy`.

csv's 4.877 -> 4.622 G instructions between steps 2 and 4 is from sections 3 and 4 together.

## Tried and not kept

- **Prefetching in the exit walk.** When a loop region closes, `kp_reaches` walks the result until half of what the region
  allocated is accounted for, to decide whether its slabs can be adopted. On treemap that walk is 13 ms (334 k cells of a
  tree that lies in allocation order, so mostly cache misses). Prefetching a cell's later children changed nothing measurable
  on the M4.

## Not done

- **The exit walk itself** (treemap 13 ms, treemap_hashmap 19 ms, wordfreq 9 ms, csv 5 ms). It is bounded by half the
  region's allocation, and shortening it means a different adoption rule (adopt at a smaller surviving share, or trust the
  loop's own declines). That trades retained garbage for time and is a decision, not a fix.
- **Call regions** (`g_call_pend`/`g_call_leave`, about 3% of csv in the profile) and the string hash (`mm_bytes_hash`):
  changing the hash changes `strHash`'s values, which programs can see.
- **Inline string compare in generated code.** The call and the `Ordering` conversion around `strCompare` are compiler work.
- **Linux x86-64.** Nothing here was measured on the profile's box. The string paths were checked for equal output on
  x86-64 under Rosetta.

## Checks

- **Unit tests.** `make unit-tests` passes.
- **Sol suite.** `sol tests/run.sol --jobs 3`: 18 checks, 1 unexpected outcome, `result-sizes`. It fails the same way on the
  baseline: the installed sol (0.13.1) rejects the check's own script (`costProbe` needs an `unsafe` signature) before any
  FP-RISC code runs. The four `trust` entries are listed known failures.
- **Strings.** A targeted program compared and cut prefixes of 0 to 41 bytes, including equal strings, a difference in the
  byte after a shared prefix, a prefix of the other, and bytes 0x01 against 0xff. Output is correct and identical on arm64 and
  on x86-64 under Rosetta.
- **x86-64.** csv, wordfreq, treemap, wordfreq_mutmap and treemap_hashmap built for `macos-x86_64` match their expected
  outputs under Rosetta.

## Wall times

Median of 7 interleaved runs, baseline `93a9faba` against this change, on a quiet machine. Differences of 1–2% are within
the run-to-run spread.

| App | before | after | change |
|---|---:|---:|---:|
| treemap_hashmap | 0.233 s | 0.215 s | −8% |
| wordfreq_mutmap | 0.138 s | 0.131 s | −5% |
| csv | 0.243 s | 0.234 s | −4% |
| wordfreq_hashmap | 0.195 s | 0.188 s | −4% |
| wordfreq | 0.371 s | 0.360 s | −3% |
| treemap | 0.291 s | 0.283 s | −3% |
| csv_hashmap | 0.184 s | 0.179 s | −3% |
| records, format, sim, treemap_mutmap | | | within 1% |

treemap's wall gain is smaller than its instruction gain: the walks it lost were cheap per instruction, and the 13 ms exit
walk that remains is cache misses.

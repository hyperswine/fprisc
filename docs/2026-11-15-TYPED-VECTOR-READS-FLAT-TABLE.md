# Element types at vector reads, and knucleotide on the flat table

Date: 15 November 2026. Kind: implementation record. It takes two of the items
[vector views and buffered output](2026-11-15-VECTOR-VIEWS-BUFFERED-OUTPUT.md) left open: the test for Int or float at
every vector access, and knucleotide's trie. Baseline is `main` at `07cd2bca`. `codegenRev` is 238.

## Summary

Apple M4, instructions from `/usr/bin/time -l` with `FPR_HARTS=1`. Wall times are in [the last section](#wall-times).
All eight outputs match `expected/`, on arm64 and on x86-64 under Rosetta.

| Program | instructions before | after | change |
|---|---:|---:|---:|
| knucleotide | 21.39 G | 9.14 G | −57% |
| fannkuchredux | 17.27 G | 15.04 G | −13% |
| nbody | 33.00 G | 28.89 G | −12% |
| spectralnorm | 14.43 G | 13.79 G | −4% |
| revcomp | 3.15 G | 3.04 G | −3% |
| mandelbrot, fasta, binarytrees | | | unchanged |

knucleotide's change is the program (section 1). The others are the compiler (sections 2 to 4).

## 1. The flat table already existed

The suggestion was an open-addressing table over a flat vector in place of `std/hashmap`'s trie. Two were measured on
knucleotide's 35 M updates, against the trie's 0.96 s and C's 0.09 s:

| Table | wall | instructions |
|---|---:|---:|
| `std/hashmap` (trie, Int keys, owned loop) | 0.96 s | 21.4 G |
| `std/mutmap` (`MutMap`, the runtime's open-addressing table, `vec.c`) | 0.50 s | 9.1 G |
| a table written in FP-RISC over two `Vector Int` (keys, counts), linear probing | 0.46 s | 10.1 G |

The FP-RISC table is no better than `MutMap`, so no new module was added and knucleotide uses `std/mutmap`
(`Map.insertWith (fn old new -> old + new) next 1 m`). The key is masked with `band` in place of a remainder.

Why the FP-RISC table is not faster yet: the probe is a loop, a loop is its own function, and the two vectors come back
from it as new values, so each update forms two views again and pays a call. It will gain from anything that makes a
call cheaper; `MutMap` will not.

What is left in knucleotide is about equal parts the table's probe (`mm_find`: three columns, so three cache lines a
hit) and the loop around it.

`std/hashmap` keeps its trie. Putting a flat table behind its persistent interface would mean converting between the
two at the boundaries of every owned loop; that was not attempted.

## 2. A read says what its element is

The checker knows a `Vector Int` from a `Vector F64`; the lowering did not, so every access tested the column kind and
carried both alternatives.

- **The name carries the type.** A pair-free read is `$vec.get` or `$vec.at`. Where the handle's checked type is
  `Vector Int`, `Vector F64` or `Vector F32`, the typed erasure and the typed lowering now emit `$vec.get.int`,
  `$vec.get.float` (and `.at`): `Core.VectorRead.peekNameAs`, from `elementOf` of the handle's type. Every name of one
  read is the same runtime entry (`vec.c`), so nothing else changes meaning.
- **A view per kind.** `OVectorView` has two more parts, `ViewIntLength` and `ViewFloatLength`: the element count if the
  column is of that kind, 0 otherwise. A typed read tests `0 <= i < length` against its kind's length and loads; a
  vector of the other kind (a nominal type is not trusted: a received message is typed by its use) has length 0 there
  and goes to the C entry. So the type removes the test without being relied on for safety.
- **Int elements stay raw.** A read of an Int element answers a raw Int (`TInt`), with no tag on the way out and no
  untag at its use. A store of a value the lowering already holds raw stores it with no Int test.
- **Stores follow the reads.** `Vec.set` carries no type in Core. The lowering remembers a handle's kind from a typed
  read of it (in the environment, under the handle's value, like the view) and a later store through that handle uses
  the same kind. A function that only stores keeps the mixed view.

## 3. The C entries are laid out last

Each inline access has a block that calls the C entry (a miss, or a trap). It was laid out in the middle of the access,
so the common path jumped over it. `Codegen.Lower` now marks such blocks (`stCold`) and puts them after every other
block of the function, and the common path falls through. The inline trie node reads do the same.

## 4. Bit operations and hashes do not make a loop a region

`band`, `bor`, `bxor`, `BITSHIFTL`, `BITSHIFTR`, `intHash` and `strHash` were unknown to the analysis that gives a loop
a region, so a probe loop that masks its index was a region loop: two runtime calls every time it was entered. They
compute a word and allocate nothing (`bits.c`, `vec.c`). This took the FP-RISC table of section 1 from 15.2 G to
10.1 G instructions; it applies to any loop that uses them.

## Not done

- **Typed stores.** A fill loop that never reads (`Bytes.put` in a loop) still tests the kind at each store. `Vec.set`
  needs its own typed name for that, and it is a source-level primitive that more passes know by name than the reads.
- **One bounds test.** An access still makes two signed comparisons (`0 <= i`, `i < length`). One unsigned comparison
  needs a new comparison in the IR and in all three targets.
- **Overflow checks on index arithmetic** (`a + 1` after `a = 7 * i`): three instructions each, eighteen times in
  nbody's `pair`.
- **`F64.sqrt` inline**, and the float register class on x64.
- **Linux x86-64.** Nothing here was measured on the profile's box.

## Checks

- **Unit tests.** `make unit-tests` passes (79 suites). `tests/LowerTyped.hs` and `tests/TypedVectorRead.hs` name the
  typed read (`$vec.at.int`) where their vector is a `Vector Int`.
- **Sol suite.** `sol tests/run.sol --jobs 3`: 18 checks, 2 unexpected. `result-sizes` fails as on the baseline (the installed
  sol rejects the check's own script). `compile-budget` fails on pos1's peak residency alone (+26.5% against a 25%
  margin; allocation is +4.3%). That reading is not repeatable and is not from this change: five compiles of pos1 one
  at a time read 617, 574, 574, 574, 574 MB with the compiler at `edfa57cd` and 603, 553, 553, 553, 553 MB with this
  one, against a recorded baseline of 500 MB, and the check compiles its three programs at once, which reads higher
  (601 and 633 MB in three runs of the check alone, one pass and two failures). The darwin baseline is not re-recorded
  here.
- **Golden cases.** `tests/std/vecinline` (Int, float, tuple and String vectors, in and out of loops, the widest Ints)
  and `tests/std/bytes` pass on arm64 and on x86-64 under Rosetta. The out-of-range traps give the runtime's messages.
- **App suite.** All eleven `tests/bench/apps` outputs match.

## Wall times

Median of 5 interleaved runs through a pipe on the M4. C is `cc -O2` of `tests/bench/clbg/c`. Outputs were checked by md5
on every run.

| Program | before | after | C | before / C | after / C |
|---|---:|---:|---:|---:|---:|
| binarytrees | 0.363 s | 0.363 s | 1.054 s | 0.3 | 0.3 |
| fannkuchredux | 0.625 s | 0.546 s | 0.131 s | 4.8 | 4.2 |
| nbody | 0.995 s | 0.781 s | 0.159 s | 6.3 | 4.9 |
| spectralnorm | 0.586 s | 0.583 s | 0.098 s | 6.0 | 5.9 |
| mandelbrot | 1.290 s | 1.289 s | 0.492 s | 2.6 | 2.6 |
| fasta | 0.394 s | 0.393 s | 0.209 s | 1.9 | 1.9 |
| knucleotide | 1.041 s | 0.530 s | 0.093 s | 11.2 | 5.7 |
| revcomp | 0.133 s | 0.131 s | 0.034 s | 3.9 | 3.9 |

Geometric mean of FP-RISC over C: 3.3x before, 2.9x after.

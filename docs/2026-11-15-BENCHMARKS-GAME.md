# Benchmarks Game suite (15 November)

`tests/bench/clbg/` adds eight programs from the Computer Language Benchmarks
Game (binarytrees, fannkuchredux, nbody, spectralnorm, mandelbrot, fasta,
knucleotide, revcomp) in FP-RISC and eight other languages: C, Rust, Go,
Java, OCaml, Haskell, JavaScript (Node) and Python. `pidigits` and
`regex-redux` are left out because FP-RISC has no big integers and no regular
expressions.

The programs are the suite's, not the Benchmarks Game site's: every one is
single-threaded, uses the standard library only, and follows the algorithm in
[SPEC.md](../tests/bench/clbg/SPEC.md) step by step, so all 72 programs print
byte-identical output (checked by md5 on every run). The site's fastest
entries are multi-core and hand-vectorised; these are what an experienced
programmer writes in an afternoon, which is the comparison that matters for
FP-RISC (one hart, no SIMD in user code).

Run with `sol build.sol` then `sol run.sol` from `tests/bench/clbg` (details
in SPEC.md). Each measurement is the median of three runs after an untimed
warm-up run.

## Results on the M4 (fprisc ea8509cf)

Median wall seconds at the default sizes (`results/2026-11-15-0341-macm4.md`):

| program | fpr | c | rust | go | java | ocaml | haskell | js | python | fpr/C | fpr/peers |
|---|---|---|---|---|---|---|---|---|---|---|---|
| binarytrees | 0.357 | 1.019 | 1.117 | 0.555 | 0.285 | 0.262 | 0.345 | 0.580 | 4.718 | 0.3 | 0.6 |
| fannkuchredux | 0.839 | 0.125 | 0.134 | 0.125 | 0.173 | 0.155 | 0.315 | 0.193 | 2.302 | 6.7 | 4.9 |
| nbody | 3.950 | 0.154 | 0.101 | 0.152 | 0.217 | 0.168 | 1.697 | 0.271 | 12.808 | 25.7 | 18.2 |
| spectralnorm | 0.602 | 0.096 | 0.093 | 0.134 | 0.156 | 0.313 | 0.614 | 0.237 | 10.883 | 6.3 | 2.5 |
| mandelbrot | 1.786 | 0.492 | 0.495 | 0.453 | 0.900 | 0.485 | 0.876 | 0.702 | 17.942 | 3.6 | 2.5 |
| fasta | 1.179 | 0.213 | 0.219 | 0.235 | 0.269 | 0.317 | 0.357 | 0.273 | 1.722 | 5.5 | 4.3 |
| knucleotide | 1.496 | 0.098 | 0.249 | 0.569 | 0.845 | 0.743 | 5.162 | 1.619 | 2.184 | 15.3 | 1.8 |
| revcomp | 0.852 | 0.040 | 0.036 | 0.029 | 0.118 | 0.069 | 0.073 | 0.088 | 0.091 | 21.4 | 11.6 |

Geometric mean of FP-RISC's time over each language: C 6.30x, Rust 5.86x,
Go 5.43x, OCaml 4.28x, Java 3.84x, JavaScript 3.15x, Haskell 1.85x,
Python 0.34x (FP-RISC about 3x faster).

Peak RSS (MB) where FP-RISC stands out: binarytrees 89 (C 18, OCaml 39,
Java 544), mandelbrot 129 (others 5-80), knucleotide 386 (C 23, Java 357),
revcomp 130 (C 16, Python 164). Elsewhere FP-RISC is at 5 MB like C.

## What the numbers say

- **binarytrees is FP-RISC's best result: 2.9x faster than C** (which does
  malloc/free per node, as the rules require) and level with OCaml, Java and
  Haskell. Every node really is allocated: a kept depth-22 tree takes 271 MB.
  The bump allocator and region frees do what a generational GC does here.
- **Vector access is the largest single cost.** `Vec.get` and `Vec.set` are
  out-of-line runtime calls (`fpr_g_$vec.get_call2`, `fpr_g_Vec.set_call3`),
  each threading the linear handle back. nbody's `pair` makes 14 gets and
  5 sets per call and some of its F64 `+`/`*` go through generic primitive
  calls: 14,100 instructions per step against C's 471 (30x), the worst ratio
  in the table. fannkuchredux (Int vectors) has the same calls and runs 20x
  C's instructions. Inlining get/set for Int and F64 element vectors, with the
  bounds check in line, is the obvious next compiler step for numeric code.
- **Strings built a character at a time.** revcomp and fasta build each
  60-character line as a list of codes then `fromCodes`; mandelbrot builds a
  one-byte string per pixel byte and joins them, which is where its 129 MB
  goes. These are idiomatic for today's std but have no buffer type to write
  into; a byte-buffer builder in std would remove both the time and the memory.
- **knucleotide** uses `std/hashmap` keyed by `substr` strings: 31 G
  instructions against C's 1.2 G with a packed-integer table. It is still
  faster than Haskell (IntMap), JavaScript and Python, and close to the peer
  median (1.8x).
- **mandelbrot and spectralnorm** (scalar F64 loops with no vectors in the
  hot path) are 2.5x the peer median: the floating point loop itself compiles
  reasonably (mandelbrot 4.5x C's instructions).

## Caveats

- The default sizes are small (C takes 0.04-1.0 s), chosen so Python finishes
  in minutes. Process startup is part of every time; it dominates Java's and
  Node's small runs.
- Times include a Perl wrapper that records microsecond wall time; RSS and
  instruction counts from `/usr/bin/time -l` include the wrapper's few MB and
  few million instructions.
- OCaml is built without flambda (this ocamlopt has none). Haskell
  binarytrees needs `-fno-full-laziness -fno-cse`, or GHC shares the trees and
  stops building them. C turns off floating point contraction so its digits
  match the other languages.
- One machine, one run of the suite.

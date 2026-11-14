# Vector views, a byte buffer, buffered output, floats kept in float registers

Date: 15 November 2026. Kind: implementation record. It takes the four gaps the
[Benchmarks Game suite](2026-11-15-BENCHMARKS-GAME.md) showed: vector access, strings built a character at a time,
map keys that allocate, and scalar float loops. Baseline is `main` at `edfa57cd`. `codegenRev` is 237 and
`a64SelectionRev` is 33.

## Summary

Apple M4. Instructions are from `/usr/bin/time -l` with `FPR_HARTS=1` (an idle hart's wait loop otherwise adds to the
count). Wall times are in [the last section](#wall-times). All eight outputs match `expected/`, on arm64 and on x86-64
under Rosetta.

| Program | instructions before | after | change | peak RSS before -> after |
|---|---:|---:|---:|---|
| revcomp | 11.82 G | 3.13 G | −74% | 129 MB |
| fasta | 15.42 G | 4.56 G | −70% | 3 MB |
| nbody | 70.64 G | 33.02 G | −53% | 3 MB |
| knucleotide | 31.40 G | 21.48 G | −32% | 385 -> 225 MB |
| mandelbrot | 24.80 G | 17.54 G | −29% | 129 -> 7 MB |
| spectralnorm | 19.70 G | 14.49 G | −26% | 3 MB |
| fannkuchredux | 23.38 G | 17.29 G | −26% | 3 MB |
| binarytrees | 9.28 G | 9.23 G | flat | 88 MB |

The app suite (`tests/bench/apps`) is unchanged within 1% except the hash trie apps, which gain from the inline node
reads: treemap_hashmap 2.339 -> 2.265 G, wordfreq_hashmap 3.318 -> 3.199 G, csv_hashmap 4.092 -> 3.969 G.

Four of the eight programs changed as well as the compiler: revcomp, fasta and mandelbrot write into a byte buffer
(section 3), and knucleotide packs its keys into Ints (section 6).

## 1. A vector is checked once, then read and written by a bounds test

**What it cost.** A read `(x, v1) = Vec.get i v` was already inline, but each one repeated the whole shape test: is this
a vector, is it flat, one column, which kind, then three loads to reach the column. That is about 25 instructions a
read. `Vec.set` was a call. nbody's `pair` makes 14 reads and 6 stores of one vector.

**The view.** A handle's *view* is three words: the length a flat Int or float column answers for (0 for every other
shape), the column's base, and whether the column holds Ints. With it a read is

    0 <= i, i < length, load base[i]

and the length test is also the shape test, because every other shape has length 0 and goes to the C entry, which
keeps every other case and every trap message. An in-place store is the same test and a store.

**Why one view serves a whole function.** A vector handle is linear. A read answers the handle it was given, and so does
an in-place store (`vec.c` `h_set` returns its argument; a store changes neither the length nor the column). Anything
that can move or resize the column (`Vec.push`, a call) answers a new value. So the view is a function of the handle
*value*, and the IR says so: `OVectorView part handle` is a pure, total operation (`Codegen.IR`).

- **In a function.** `Codegen.Lower` keeps a handle's view in the environment under the handle's value, so every later
  access in scope uses it (`lowerVector`).
- **In a loop.** A loop that passes its vector round unchanged has the view formed before the loop. `hoist-vector-views`
  (`LoopOptimize.moveViews`) is always on, whatever the policy says of general loop motion, and ignores register
  pressure: a view left in a loop costs twenty instructions an iteration.
- **For the targets.** The simplifier's last pass, `expand-vector-views` (`VectorRead.expandViews`), replaces each view
  by its tests and loads, so no target selects one. A64, x64 and RV refuse an unexpanded view.

`Vec.set` and `Vec.put` now lower as a store whose result is the handle itself, which is what lets a loop of stores
(`swapUp`, `shiftLeft` in fannkuchredux) keep one view.

## 2. A scalar loop is not a region

A loop gets a region only when its iteration allocates, and a call the analysis does not know is assumed to allocate.
Float arithmetic, comparison, conversion and literals were unknown to it, so `inSet` (mandelbrot's inner loop, pure F64)
ran inside a region: a room test every iteration and two runtime calls every time the loop was entered, 16 M times.

`ReceiveTurns` now knows that where a float is its bits in the word (64-bit targets, `Regions.Options.rawFloats`) the
F64 and F32 operators, `sqrt`, `ofInt`, `toInt` and float literals allocate nothing, and that a store into a flat
vector writes one word. On a 32-bit word a float is a boxed leaf and the old rule stays.

## 3. A byte buffer: `Vec.pack` and `std/bytes`

A String is immutable, so a line built a character at a time was a list of codes and then `String.fromCodes`, a cell
per character. There was nothing to write bytes into.

- **`Vec.pack from n v`** (`vec.c` `h_pack`) answers the `n` Ints at `from` as the bytes of one String, with the handle.
  An element outside 0..255 traps and names it. Nothing is truncated.
- **`std/bytes`** is a buffer over it: `new`, `put`, `get`, `pack`, `free`. A buffer is a `Vector Int`, one byte an
  element; `put` is the inline store of section 1, and the buffer comes back from every operation, so one buffer
  serves every line.

revcomp and fasta fill a 60-byte buffer per line, and mandelbrot one buffer per row. mandelbrot's 129 MB was the
one-byte Strings it joined.

## 4. Standard output is buffered when it is not a terminal

**What it cost.** `print` flushed at every newline, so a program that prints many lines made one `write` a line. In a
sample of fasta about 70% of the time was in `write`. The byte buffer alone gained little; this was the larger part.

**The rule** (`machine/posix/hal.c`). Into a terminal, output is flushed at every newline, as before. Into a pipe or a
file it is buffered (64 KiB) and written:

- when the buffer fills;
- before anything that must follow it in order: a diagnostic or panic, `Sys.stderr`, a raw `Os.write` or `Os.read`,
  `Sys.readLine`, a child process, exit;
- when a hart goes idle (`machine/unix/park.c`);
- otherwise by a flusher thread, within 50 ms of the first byte buffered, so a program that prints and then blocks in a
  call or computes for a minute has still printed.

`FPR_STDOUT_LINES=1` keeps a flush at every newline. ESP-IDF, whose console is a UART, always flushes by line.

**What changes for a program.** Output into a pipe can arrive up to 50 ms later than it was printed, and a process
killed by a signal loses what it printed in that last interval. The order of standard output against standard error
and raw writes is unchanged.

## 5. Floats carried round a loop stay in the float registers (A64)

The result of a float operation already lived in a float register, but a block parameter did not, so every value a
loop carries was moved to an integer register at the back edge and back at its first use: four moves each way in
`inSet`, on the path the next iteration waits for.

`floatPool` (`Codegen/Target/A64.hs`) now puts in the float class a value that only moves define (a block parameter has
one move per edge) when one of those moves brings a float and a float operation reads it. The edge that brings a word
(the loop's entry) pays one move in. A joined word that float operations read twice or more and nothing else reads (a
float read from a vector) is moved in once, at the join. Fixed and tied registers and a function's own parameters keep
the word ABI.

Two things the x64 backend already had were ported to A64 at the same time: a branch to the block laid out next is not
emitted, and a comparison is branched on directly when the edges carry block parameters too (the moves come after the
branch).

## 6. knucleotide: Int keys, and inline trie node reads

- **The program.** A k-mer is packed two bits a base into an Int, as the C program does, and the key of the k-mer ending
  at a position is the previous key shifted. This removes a `substr`, a string hash and a string compare per position.
  The update is unconditional: with `if pos + 1 >= k then Map.update … m else m` the loop no longer owned its map, and
  every update copied its path (61 G instructions and 1.5 GB, against 23 G and 225 MB).
- **The compiler.** `nodeGet` and `nodeSet`, the trie node read and store by field number, are lowered inline
  (`Lower.lowerNode`): the runtime's one guard (the field number below 64), then the word. This is 21.5 G against
  22.9 G on knucleotide, and the gain on the hash trie apps above.

## 7. A pass that changes nothing is not verified again

The simplifier verified a function after every pass. Two more passes meant two more verifications of every function,
and the compile budget went from within its 10% margin to 11% over. `simplifyFnWith` now skips the verification when a
pass answers the function it was given (an equality test, no allocation); the first pass's result is always verified,
so every function is verified at least once and an error still names its pass.

| Budget program | allocation against the darwin baseline, with the two passes | now |
|---|---:|---:|
| hello | +9.9% | +3.6% |
| std-live | +10.8% | +3.0% |
| pos1 | +11.1% | +5.1% |

Before this change set all three were inside the 10% margin (the check passed at `ea8509cf`); how far inside was not
measured. The baseline in `tests/compile_budget.json` is not re-recorded here.

## Not done

- **x64.** The view, the region rule, the byte buffer and buffered output are target-independent. Floats in float
  registers are A64 only: the x64 backend has no float register class (every float operation goes through `xmm14` and
  `xmm15`), so that part needs the class first.
- **nbody is still 6x C.** What is left in `pair` is spread out: the Int/float test in every access (the element
  type is known to the checker but not to the lowering), two signed tests where one unsigned test would do, overflow
  checks on `7 * i` and on every index, and `F64.sqrt` as a call, which forces the values live across it out of the
  volatile registers.
- **The trie's cost per level.** knucleotide spends about 600 instructions an update, most of it in the walk: a
  recursive call, three type tests before the node case, and a pair returned at each level. C's open-addressing table
  is one probe.
- **Map lookups by a slice of a String** (hash and compare a range without making the substring) would help programs
  that must keep String keys. knucleotide did not need it.
- **Linux x86-64.** Nothing here was measured on the profile's box.

## Checks

- **Unit tests.** `make unit-tests` passes (79 suites). `tests/RegionInterfaces.hs` and `tests/TypedProgram.hs` pass the
  new `rawFloats` option as False.
- **Sol suite.** `sol tests/run.sol --jobs 3`: 18 checks. `result-sizes` fails as on the baseline (the installed sol rejects the
  check's own script). `std-golden` was rerun on its own after the two cases below were added: 48 cases, 0 failed.
  `compile-budget` passes (hello +3.1%, std-live +2.0%, pos1 +4.3% allocation; pos1's peak reads +21.1%, inside the
  25% margin). The `trust` entries are listed known failures.
- **New golden cases.** `tests/std/vecinline` reads and stores every vector shape in and out of loops (flat Int and
  float, tuples, Strings, a vector that grows, the widest Ints); `tests/std/bytes` covers `std/bytes`. Both give the
  same output on x86-64 under Rosetta.
- **Traps.** An index out of range in a read, a store, and a store in a loop gives the runtime's own message
  (`Vec.get: index out of range (5, length 5)`); a value over 255 in `Vec.pack` names the value.
- **Output order.** A program that prints, writes to standard error, writes raw to descriptor 1, sleeps, reads a line
  and then panics gives the same byte order into a pipe and into a file as into a terminal, and its lines arrive before
  the sleep and before the read. A program that prints and then computes for a second delivers the line at once.
- **x86-64.** All eight programs built for `macos-x86_64` match their expected outputs under Rosetta.
- **Safety allow-list.** `std/bytes.fpr` is not on it, like `std/vector.fpr`; it is recorded in
  `tests/sol-checks-known-failures.tsv` with the same reason (a review decision).

## Wall times

Median of 5 interleaved runs through a pipe, on the M4 with other applications open (a desktop, not a quiet box). C is
`cc -O2` of `tests/bench/clbg/c`. Outputs were checked by md5 on every run.

| Program | before | after | C | before / C | after / C |
|---|---:|---:|---:|---:|---:|
| binarytrees | 0.375 s | 0.370 s | 1.082 s | 0.3 | 0.3 |
| fannkuchredux | 0.854 s | 0.640 s | 0.138 s | 6.2 | 4.6 |
| nbody | 4.101 s | 1.024 s | 0.165 s | 24.9 | 6.2 |
| spectralnorm | 0.621 s | 0.614 s | 0.105 s | 5.9 | 5.8 |
| mandelbrot | 1.947 s | 1.415 s | 0.544 s | 3.6 | 2.6 |
| fasta | 0.874 s | 0.419 s | 0.228 s | 3.8 | 1.8 |
| knucleotide | 1.793 s | 1.134 s | 0.093 s | 19.3 | 12.2 |
| revcomp | 0.478 s | 0.138 s | 0.036 s | 13.3 | 3.8 |

Geometric mean of FP-RISC over C: 5.7x before, 3.3x after.

spectralnorm's wall time did not move although its instructions fell by a quarter: what left the loop was the view,
which the processor ran in parallel with the division the loop waits for.

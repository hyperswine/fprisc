# Calls inside loops, and what an access costs

Date: 15 November 2026. Kind: implementation record. It takes the two items
[typed vector reads and the flat table](2026-11-15-TYPED-VECTOR-READS-FLAT-TABLE.md) ended on: a small loop is its own
function and pays for it at every call, and an element access still costs about twelve instructions. Baseline is `main`
at `244bfd5b`. `codegenRev` is 239.

## Summary

Apple M4, instructions from `/usr/bin/time -l` with `FPR_HARTS=1`. All eight outputs match `expected/`, on arm64 and on
x86-64 under Rosetta.

| Program | instructions before | after | change |
|---|---:|---:|---:|
| nbody | 28.89 G | 15.37 G | −47% |
| fannkuchredux | 15.04 G | 9.11 G | −39% |
| spectralnorm | 13.79 G | 12.02 G | −13% |
| fasta | 4.56 G | 4.15 G | −9% |
| mandelbrot | 17.46 G | 17.18 G | −2% |
| binarytrees, knucleotide, revcomp | | | within 3% |

nbody's inner loops, `pair` and the two `moves` are now one function with the vector's view formed once, no checked
arithmetic and no lower bounds test left in it.

## 1. A function that never allocates is not unknown code

The analysis that gives a loop a region took every call to another function as an allocation. So `pairsFrom`, whose
iteration only calls `pair`, was a region loop (two runtime calls each time it is entered), and `advance` put a call
region around `pairs` and `moves`.

`ReceiveTurns` now finds the functions of the program that never allocate (`quiet`): assume every function with
parameters is one, drop those with an allocation of their own under that assumption, then everything that names a
dropped one. A function that applies a value it was given (a closure, a parameter) is dropped too: what that value does
is not known. A call to a quiet function, saturated, allocates nothing; a loop whose iteration only makes such calls is
not a boundary, and a call to one gets no call region.

## 2. A store says what its element is

`Vec.set` and `Vec.put` into a `Vector Int`, `Vector F64` or `Vector F32` are named `$vec.set.int`, `$vec.set.float`
(and `.put`) by the typed erasure and the typed lowering, as the reads were (`Core.VectorRead.storeNameAs`). Each name
is the same runtime entry (`vec.c`). Two things follow:

- a loop that only stores (a fill through `Bytes.put`) tests one column kind, like a read;
- the region analysis no longer has to trace the handle back to a parameter to know the store writes one word. That
  trace failed after inlining (`moveAxis` in `moves`), which is what kept `moves` a region loop.

## 3. A call inside a loop becomes the callee's blocks

New module `Codegen.InlineCalls`, run on the lowered program before simplification (hosted Base and QOS app profiles,
64-bit). The checked inliner works on expressions, takes templates of at most 64 nodes in a loop and never a recursive
function. On the IR a callee is a control-flow graph and a loop is a cycle in it, so a helper and an inner loop are the
same splice:

- the calling block ends in a jump to a copy of the callee's entry;
- every `ret` (or product return) of the copy jumps to the rest of the calling block, whose parameters are the call's
  results;
- a tail call in the copy becomes a call followed by that jump.

Taken: a direct call to a function of the same unit, from a block on a cycle of its function, when the callee is not
part of the caller's own recursion, is named by the program in that one place only (so it moves rather than
multiplies) and is at most 400 instructions; a caller stops growing at 450. Functions are expanded callees first, so a
nest of loops collapses into the outermost one. The callee keeps its definition.

Kept: the order of every effect and trap, and every safepoint of the callee, its entry tick included. Dropped: the
callee's stack check (the copy lives in the caller's frame, checked at the caller's entry).

What it buys beyond the activation (frame, saved registers, stack check, fuel tick; on macOS the stack check alone is a
thread-local lookup) is everything the passes after it can now see across the old call: the handle is one value, the
loop bounds reach the callee's arithmetic.

## 4. A parameter with one value is that value

New simplifier pass `forward-single-valued-parameters`: a block parameter that every edge passes the same value, or the
parameter itself around a loop, is replaced by that value. An inlined callee hands its vector back through the join
after its exits, and every exit hands back the handle it was given; nested loops pass the handle round unchanged. After
this pass those are all one value, so the view (`OVectorView`) is moved out of every loop that carries the handle and
formed once.

## 5. Bounds from ranges, and smaller things

- **Comparisons proved from ranges.** `Codegen.Interval` discharged a guard only from a difference walk. It now also
  compares the two sides' ranges, which is where a product or a sum has a bound: `7 * i + 3 >= 0` under `0 <= i`. The
  lower half of an access's bounds test goes wherever the index is built from a counted loop's variable, which leaves
  one comparison an access.
- **`F64.sqrt` and `F32.sqrt` inline** (`fsqrt`, `sqrtsd`, `fsqrt.d`): `FSqrt`, a float operation on one operand given
  twice, so every path a float operation already takes carries it. Never a tree node.
- **`F64.ofInt` inline** (`scvtf`, `cvtsi2sdq`, `fcvt.d.l`): `OFloatOfInt`. It was a runtime call per element in
  spectralnorm.
- **A checked operation repeated in a block is shared**: the same operands give the same answer, or the first one
  trapped.

## 6. What it cost the compiler, and the dominators

The first version took any callee of up to 400 instructions into any loop. The compiler then allocated thirty times as
much on `hello` (the prelude's loops all grew), and two checks timed out. Three things came of that:

- **Dominators.** A profile put over half of all allocation in `Codegen.ControlFlow.analyze`: every block's set was
  recomputed from the previous round's sets, a round per block of the longest path, and whole maps were compared to
  find the end. It now sweeps in reverse postorder, reads the sets already updated in the same sweep, and tracks a
  changed flag: two sweeps for a reducible graph. Same answers; `hello` with the same inlining went from +144% to +20%.
- **One call site only.** Small shared callees (24 instructions, then 12) into loops still cost 6% to 14% on `hello`
  and bought a few percent on three benchmarks at 24 and nothing at 12. The rule became the single call site.
- **A pass that did not end.** `forward-single-valued-parameters` repeated for ever when its only candidates were a
  cycle of parameters (blocks nothing reaches). It stops when a round forwards nothing.

The price of the second: fannkuchredux, fasta and mandelbrot were 3% to 7% better with small shared callees inlined.

## Not done

- **One unsigned comparison** where the lower bound is not provable. It needs unsigned conditions through the IR's
  comparison and all three targets; the range proof above removes the lower test in counted loops, which is most of
  them.
- **Indexed addressing on A64.** An access is still `lsl`, `add`, `ldur` where one `ldr` with a scaled index would do.
- **The multiply's overflow check** (eleven instructions on A64; `smulh` would make it six), **a Bool test** (seven
  instructions for `if t` on a Bool parameter), and **loop-invariant untags** (loop motion is off by default).
- **Tuple results.** A loop whose callee answers a tuple is still a region loop (`mulRows` in spectralnorm): the
  analysis runs before the tuple becomes a product return and counts it as an allocation.
- **Cold blocks of an inlined callee** stay where the callee had them, in the middle of the caller.
- **Linux x86-64.** Not measured.

## Checks

- **Unit tests.** `make unit-tests` passes.
- **Sol suite.** `sol tests/run.sol --jobs 3`: 18 checks, 1 unexpected: `result-sizes`, which fails as on the baseline
  (the installed sol rejects the check's own script). `compile-budget` passes: allocation is +0.7% (hello), −1.4%
  (std-live) and +4.0% (pos1) against the darwin baseline, lower than before this change (section 6).
- **Golden cases.** 49 of 49. New: `tests/std/loopcalls` (a helper, an inner loop and a tuple-returning inner loop,
  each called from one place in a loop; a fill that only stores; `F64.sqrt` and `F64.ofInt`). An index outside the
  vector inside a merged helper gives the runtime's own trap (`Vec.get: index out of range (12, length 12)`), checked
  by hand.
- **Benchmarks Game.** All eight outputs match on arm64 and on x86-64 under Rosetta.
- **App suite.** All eleven `tests/bench/apps` outputs match; none uses more instructions or memory than before.

## Wall times

Median of 7 interleaved runs through a pipe on the M4 (another program was using the machine, so every figure is a
little above the last record's). C is `cc -O2` of `tests/bench/clbg/c`. Outputs were checked by md5 on every run.

| Program | before | after | C | before / C | after / C |
|---|---:|---:|---:|---:|---:|
| binarytrees | 0.362 s | 0.364 s | 1.143 s | 0.3 | 0.3 |
| fannkuchredux | 0.562 s | 0.382 s | 0.141 s | 4.0 | 2.7 |
| nbody | 0.853 s | 0.428 s | 0.161 s | 5.3 | 2.7 |
| spectralnorm | 0.606 s | 0.598 s | 0.101 s | 6.0 | 5.9 |
| mandelbrot | 1.347 s | 1.342 s | 0.520 s | 2.6 | 2.6 |
| fasta | 0.406 s | 0.378 s | 0.220 s | 1.8 | 1.7 |
| knucleotide | 0.535 s | 0.540 s | 0.092 s | 5.8 | 5.9 |
| revcomp | 0.132 s | 0.129 s | 0.036 s | 3.7 | 3.6 |

Geometric mean of FP-RISC over C: 2.8x before, 2.4x after.

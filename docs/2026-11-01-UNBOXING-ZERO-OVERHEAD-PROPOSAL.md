# Unboxing and zero-overhead builtin types: a proposal

Date: 1 November 2026. Kind: design proposal with measurements. It changes no
compiler behaviour. Base: main `251c6d0`.
It builds on [the zero-overhead follow-ups](2026-10-31-ZERO-OVERHEAD-FOLLOWUPS.md),
which call uniform representation "the zero-overhead endgame" (its item 2) and
leave list fusion as an open question (its item 5), and on
[the near-term plan](2026-10-31-PERFORMANCE-AND-PREDICTABILITY-NEXT.md), whose
ordering and structural constraints (checked arithmetic, cooperative yield,
ownership, generic boundaries) still apply. This page answers the analysis
those two pages asked for, then proposes the order in which to answer it in
code.

## Summary and recommendation

**What the measurements say** (x86-64 box, 15 interleaved runs, medians;
reproduce with `tests/bench/unbox/measure.py`, raw data in
`bench/2026-11-01-unboxing.json`):

- A `List Int` cell costs **48 bytes** of allocation (8 B header + 2 tagged
  words, rounded to 32, plus the allocator's 16 B preheader), against 16 B for a
  C cons cell and 8 B for an array slot. `range 1 N |> sum` runs at
  **11.8 ns/element**, 8.2x the same computation written as a loop in FP-RISC
  (1.4 ns) and 4.8x a C cons list with a bump allocator.
- `map` allocates **three** cells per element (the input range, the
  accumulator, the `reverse`); `filter` two. Neither fuses, and reuse changes
  nothing measurable on any benchmark (`FPR_NO_REUSE=1` is within noise).
- Small data that never escapes is still heap-allocated: an inlined
  `Option`-returning helper allocates a `Some` per call (10 M allocations in
  `option_loop`, 21x C); a loop-carried pair allocates a tuple per iteration
  (20 M allocations, 2.6x C).
- Traversal alone is close to reasonable (fold over an existing list: 4.8 ns
  vs 1.8 ns C, 3.6 ns GHC -O2), but the specialized fold loop still executes
  **52 instructions per element**: two fuel ticks, a three-branch `Nil` test,
  tag/untag around every operation and two overflow checks.
- What is already zero-cost or close: callback specialization and inlining
  (worth 1.3-1.8x on every list benchmark), loop regions that recycle list
  memory per slab, scalar loops (`loop_sum` is within 1.5x of a C array loop
  that includes its own malloc and fill).

**Recommendation.** Do not start with a new default representation. Get most of
the gap with transformations that keep the current uniform word ABI, in this
order, each behind an `FPR_NO_*` rollback flag and an allocation-count gate:

1. **Known-constructor elimination**: case-of-case and case-of-known-constructor
   after inlining, plus scalar replacement of loop-carried tuples/records
   (extending field workers). Removes the `Option`/tuple allocations outright.
2. **List fusion for the std combinators** (`range`, `map`, `filter`, `fold`,
   `sum`, `length`, ...) using the existing vector-fusion and `FusionSafety`
   effect-order evidence, plus tail-recursion-modulo-cons so unfused `map` and
   `filter` stop paying for `reverse`. Ceiling: `loop_sum`, i.e. up to 8x on
   pipelines and zero allocation.
3. **Cheaper residual cells and tests**: the inline bump-allocation fast path
   already planned, a header-free small-object layout in region pools (48 -> 32
   or 24 B per cons), immediate nullary constructors and type-directed case tests
   (no type-id check where the type is statically known), one fuel tick per loop
   iteration.
4. **Type-directed monomorphization** at link granularity (MLton/Roc style)
   with a code-size budget and fallback to the uniform representation. This is
   the step that makes unboxed `List Int` cells, `Option Int` in two registers
   and flat tuples possible; only it touches representation contracts, so it
   lands last and carries its own ABI revision.

A WCET/bounded mode reuses what steps 1-2 produce: once pipelines fuse, most
`Base` list code needs no allocation, and what remains has `size` bounds that
the std library already states (`std/list.fpr:24,43,58,72`) and `Cost.hs`
already turns into allocation equations. Step 3's header-free cell is also what
makes those equations a true arena size (today `Cost.hs:10-13` deliberately
excludes the preheader and rounding, which double a cons cell).

Keep the source language as it is: no new mandatory annotations, no change to
list semantics (O(1) cons, persistent sharing). Representation kinds stay an
internal compiler notion until monomorphization has shipped and has been
measured.

## Evidence

### Representation today (cited at the branch point)

| Value | Representation | Where |
| --- | --- | --- |
| `Int` | one tagged word `(n << 1) \| 1`; untagged only inside typed-IR regions (`TInt`) | `runtime/fpr.h:3-5,54-55`; `compiler/Codegen/IR.hs:50-57` |
| `Bool`, `Unit`, `Nil`, `None` | pointers to static immortal objects; a test loads the variant word at +4 | `runtime/fpr.h:21-24,36`; x86-64 output uses `.Lnul_2_0` for `Nil` and `movslq 4(%rax)` after `==` |
| Constructors, tuples, `Some`, cons | heap node `[u32 type id \| u32 variant \| word fields]` behind a 16 B allocator preheader `(total, slab)` | `runtime/fpr.h:36`; `runtime/runtime.c:636-649` |
| Closures | PAP object `[hdr \| fn \| arity \| nargs \| args...]`; known functions are static PAPs | `runtime/fpr.h:37-38` |
| `String` | `[hdr \| len \| bytes]` | `runtime/fpr.h:39` |
| `Vector` | flat SoA columns in the base pool, fused/SIMD kernels | `core/prelude.fpr:717-724`; `runtime/vec.c` |
| `F64` | IEEE bits in a word on 64-bit; boxed `T_BITS` on RV32 | `runtime/fpr.h:42-47`; `IR.hs:67-68` |
| Polymorphic functions | compiled once over tagged words; specialization only over known callbacks | `compiler/Mono.hs:1-3`; `compiler/Core/Typed/Specialize.hs:2-4` |

There are no thunks: the language is strict, so the boxing problem is only
about representation, not laziness. The pieces that could carry a different
representation already exist but are not connected in Base:
`Representation.hs:2-4` infers representations whole-program for the
standalone ARC ABI only and "deliberately rejects representation-polymorphic
code until cloning is implemented"; `Workers.hs:1-2,107-111` gives private
unboxed worker conventions but admits one fixed-width constructor parameter
per function and keeps a general entry whenever a fresh constructor is
returned; `Struct.hs:17-22` monomorphizes struct-signature arguments by name,
not by type. `Reuse.hs:1-3` reuses only fresh, non-escaping roots and treats
public calls as borrowing, which is why it never fires on list pipelines: the
list `map` consumes comes from a public `range`. Hosted Base memory is region
based (loop regions "cycle per slab", visible in `--remarks`), so reuse would
save cache footprint and allocator calls, not reclamation work; ARC
(`Arc.hs`) applies to the builtin `--arc` ABI.

### The per-element instruction tax

The specialized `foldGo` loop for `fold (fn a x -> a + x * 3)` (x86-64,
`fpr compile --system=posix tests/bench/unbox/list_fold.fpr`) executes 52
instructions on its fast path per element, against roughly five for the C
loop. Where they go:

| Cost | Instructions | Removable by |
| --- | --- | --- |
| Two fuel ticks (loop head and body) | 8 | one tick per iteration (plan section 4 batching later) |
| `case xs of Nil`: immediate bit, type id == 2, variant == 0, bool materialize/test | 17 | immediate `Nil` + type-directed test: 2 |
| Field loads | 2 | - |
| Untag accumulator and element, retag result, constant materialization | 7 | unboxed cells (monomorphization) |
| `x * 3` overflow (`jo` plus 63-bit fit check) | 9 | interval facts; tagged-domain algebra |
| `a + _` 63-bit fit check | 6 | as above |
| Jumps | 3 | block layout |

The tag and overflow work is the checked-arithmetic contract and stays; the
case test, double tick and materializations are pure overhead with no
semantic content.

### Workloads

All times are whole-process medians of 15 interleaved runs; fpr startup is
1.3 ms (`empty`), C 0.8 ms. "Allocs" are `FPR_COST_PROBE` counts for the
whole run. C is `gcc -O2` (`tests/bench/unbox/ref.c`) with a bump allocator
and no frees, i.e. the cheapest possible boxed list; `arr` is a malloc'd
array. GHC is 9.10 `-O2` (`ref.hs`), run in a separate session on the same box.

| Benchmark (20 x 1 M unless noted) | fpr | allocs / bytes | spec+inline off | C cons | C ideal | GHC -O2 |
| --- | --- | --- | --- | --- | --- | --- |
| `list_sum` range+sum | 235 ms | 20.0 M / 960 MB | 353 ms | 49 ms | 19 ms (arr) / 29 ms (fpr loop) | fused away (2 ms, 0 B) |
| `list_map` range+map+sum | 779 ms | 60.0 M / 2.88 GB | 1008 ms | 117 ms | - | fused away |
| `list_filter` range+filter+sum | 439 ms | 40.0 M / 1.92 GB | 704 ms | 85 ms | - | fused away |
| `list_fold` traverse one list | 97 ms | 1.0 M / 48 MB | 178 ms | 37 ms | - | 72 ms |
| `list_length_rev` length (reverse xs) | 358 ms | 21.0 M / 1.01 GB | 389 ms | 70 ms | - | 129 ms |
| `option_loop` 20 M, `Option` helper | 167 ms | 10.0 M / 320 MB | 212 ms | - | 8 ms | 17 ms |
| `tuple_loop` 20 M, pair step | 164 ms | 20.0 M / 961 MB | 210 ms | - | 62 ms | not comparable (lazy pair) |
| `tree_sum` 10 x depth-20 tree | 423 ms | 10.5 M / 503 MB | 434 ms | 89 ms | - | 166 ms |
| `string_scan` 20 x 1 MiB `charAt` | 69 ms | 0.1 M / 7 MB | 71 ms | - | 7 ms | - |
| Sol: map/filter/fold over 1 M | 2786 ms | VM | - | - | 1492 ms (Sol scalar loop) | - |

Notes on reading the table:

- `FPR_NO_REUSE=1` moves no row by more than 6%, in both directions: noise.
- GHC's 2 ms rows are foldr/build fusion plus floating the pipeline out of the
  repeat loop: they show that fusion deletes the list (52 KB total heap), not a
  like-for-like time. The lazy-tuple GHC row is a space leak in my reference,
  not a GHC property.
- `string_scan` is 3.3 ns/byte against 0.34 ns in C even with guarded scan
  versioning; that gap is the string-scan work's business, not boxing, and is
  listed for completeness.
- Sol spends 1.5 us per iteration even in a scalar loop; lists add about
  1.3 us per element over three passes. Boxing is not Sol's first-order cost;
  the VM is. Nothing below targets Sol first.
- Code size: the List programs link about 80 KB more `.text` than `empty`
  (444 KB), and spec+inline adds about 31 KB (6%). That is the baseline any
  monomorphization budget is measured against.

No instruction counters (perf, valgrind) are available on the box; the
instruction figures above are static fast-path counts from the emitted
assembly, not dynamic counts.

## Options

| Option | What it buys (measured / estimated) | Cost and risk | Compatibility |
| --- | --- | --- | --- |
| **A1** Case-of-known-constructor and case-of-case in typed Core | `option_loop`: 10 M -> 0 allocs (est. 10-20x, toward C 8 ms) | Small; must keep evaluation order and trap order (`FusionPolicy` already rules on this) | Internal; no ABI |
| **A2** Scalar replacement of loop-carried tuples/records (widen `Workers` field workers) | `tuple_loop`: 20 M -> 0 allocs (est. 2-2.5x) | Small/medium; the native register budget (`Workers.hs:107-108`) | Private conventions only |
| **B1** List fusion of std combinators (producer/consumer, reusing vector fusion) | `list_sum/map/filter`: ceiling `loop_sum`, 8x / 27x / 15x, 0 allocs | Medium; effect order, checked arithmetic order, `size` contracts, quadratic analysis risk (`FusionSafety.facts` was 21% of the `let` profile) | Semantics-preserving |
| **B2** Tail recursion modulo cons for `map`/`filter`/`append` | `map` 3 -> 2 cells/element unfused, est. 1.3-1.5x | Small; needs a destination-write primitive the region model admits | Internal |
| **B3** Perceus/Lean-style reuse of unique input lists | Memory traffic only under regions; no reclamation win | Needs ownership across public calls (today borrowing) | Internal |
| **B4** Chunked/unrolled or array-backed `List` | Better locality; O(1) cons and sharing get harder | Large; changes complexity of persistent ops; every runtime walker changes | Library-visible; **not recommended as default** |
| **B5** "Known-length list is a Vector" (literals, `range` into `Vector` consumers) | Vector kernels where they already exist | Small, opt-in via std | Library |
| **C1** Header-free small cells in region pools, immediate nullary constructors, type-directed case tests | cons 48 -> 32 B (24 B with an 8 B header); 17 -> ~2 case instrs | Medium; `fpr.h` contract, deep copy, `==`, ARC and message copy walkers | Runtime ABI revision |
| **C2** Type-directed monomorphization, budgeted, uniform fallback | Unboxed `List Int` cells (16 B), `Option Int`/tuples in registers | Large; code size, compile time, cache identity, separate units | New ABI revision; fallback keeps old |
| **C3** Representation kinds (OxCaml layouts, GHC levity) exposed in source | User-controlled unboxed types | Large language surface | Opt-in |
| **C4** Uniqueness/linear types for guaranteed in-place | Already partly present (`Ownership/*`, linear carriers for `Vector`) | Surface complexity | Opt-in |
| **C5** Sized types / refinements for bounds | Std already states `size` and `measure`; feeds WCET | Moderate prover work | Additive |
| **D** WCET mode with static arenas | Static allocation for bounded programs on simple-risc | Needs C1 for exact sizes, B1 to make it rarely needed | New profile/mode |

Uniform representation versus monomorphization (option C2 against the status
quo) is the core trade. A dictionary-free uniform representation is what
fprisc has and what OCaml and Lean 4 do for polymorphic code; it keeps
separate compilation and small code, and pays boxing at every polymorphic
boundary. Whole-program monomorphization (MLton, Roc, Rust) removes that cost
completely at the price of code size and of compiling generic code per
instantiation. fprisc already builds whole programs from cache-identified
units, already clones over callbacks, and already has a cost-checked budget
mechanism for inlining, so the cheap middle path is a budgeted type
specializer whose clones fall back to the uniform entry when the budget is
hit, exactly as callback specialization falls back today.

### WCET and bounded resources

What exists: `Safety.hs` draws the safe/unsafe line at implicit recursion; the
std list loops declare `measure`s and output `size`s; `Cost.hs` produces work
and allocation equations per function; target manifests reject over-budget or
unproved functions; `Codegen.Bounds` measures native instructions between
safepoints. What a WCET mode additionally needs for list-heavy code:

1. Allocation equations that include the real cell size (preheader and
   rounding, or C1's header-free layout) so `alloc f` is an arena size.
2. Peak live memory, not only total allocation: with regions, peak is the
   region's high-water mark per cycle; a fused pipeline's peak is zero.
3. A static arena per bounded callback, sized from (1)-(2) at compile time,
   replacing `fpr_alloc` refill with a bounds-checked bump that cannot fail
   for admitted programs. On simple-risc this means no allocator in the image
   for admitted units, which matches the builtin profile's "no allocator"
   contract (`docs/2026-09-19-PROFILES.md:31`).
4. Stack bounds: the std loops are tail calls, so stack is per-frame; the
   recursive non-tail cases (`tree_sum`) need depth bounds from the measure.
5. Monomorphization makes cell sizes exact per type, which tightens (1); fusion
   removes most of the allocation the bound has to cover.

The WCET mode should therefore follow, not precede, B1 and C1.

### Profiles

| Profile | Recommended default |
| --- | --- |
| `builtin` | No list allocation; with `--arc`, A1/A2 apply; monomorphization (C2) is natural here first because programs are small and whole |
| `base` | A1, A2, B1, B2, C1 on by default once gated; C2 behind a flag until its budget is tuned |
| `extbase` | As base, larger specialization budget |
| `sol` | Unchanged; VM overheads dominate. Revisit only for the native/JIT path |

### ABI, FFI, qos and compile time

A1, A2, B1 and B2 change no boundary. C1 changes the object contract that
`runtime/fpr.h` states and generated code hard-codes, so it needs a runtime
revision in cache identity and an audit of every walker (deep copy, `==`,
message transfer, ARC drop, printers). C2 needs exported and reloadable
entries to keep the uniform signature (the near-term plan's "genuinely unknown
and reloadable boundaries need their original contracts"); FFI and qos kernel
entry points keep the tagged-word ABI. Compile-time risk is real: three of the
top quadratic hot spots (`FusionSafety.facts`, `Workers`, `Reuse.nodes`) are
exactly the passes this proposal extends, so each step must arrive with a
linear-scaling check on the [quadratic-traversal families](2026-10-30-QUADRATIC-TRAVERSALS.md)
and a code-size budget per profile.

### Correctness strategy

- Differential testing: every new pass runs with and without its `FPR_NO_*`
  flag over `tests/`, `std` tests and these benchmarks; outputs, traps and trap
  order must be byte-identical.
- Allocation gates: the `FPR_COST_PROBE` counts in the table become expected
  values; a change states which rows it moves and by how much.
- Property tests over random list pipelines (generated `map`/`filter`/`fold`
  chains with overflowing and trapping callbacks) against the unfused build.
- Size/compile-time gates as above; `--remarks` must explain every declined
  fusion or specialization, as inlining and callback specialization do now.

## Plan

Each phase is independently mergeable, defaults on only after its gate passes,
and keeps an `FPR_NO_<NAME>` rollback flag following
`compiler/Compiler/Options.hs:83` (`enabled n = not (yes ("FPR_NO_"++n))`).

| Phase | Work | Gate | Expected gain |
| --- | --- | --- | --- |
| 0 | This PR: benchmarks, probe counts, analysis | - | - |
| 1 | A1 known-constructor (`FPR_NO_CASE_KNOWN`), A2 tuple scalars (`FPR_NO_TUPLE_SCALARS`), one tick per loop iteration | `option_loop` and `tuple_loop` allocs = 0; differential clean | est. 2-20x on those rows |
| 2 | Inline bump-allocation fast path (plan step 6), type-directed case tests | allocator calls gone from cons loops | est. 1.2-1.5x on allocating rows |
| 3 | B1 list fusion (`FPR_NO_LIST_FUSE`), B2 TRMC (`FPR_NO_TRMC`) | `list_sum/map/filter` allocs = 0 when fused; quadratic families unchanged | up to 8x (ceiling measured by `loop_sum`) |
| 4 | C1 header-free region cells and immediate nullary constructors (runtime revision) | bytes/cell 48 -> 32 or 24; walkers audited | est. 1.2-1.5x on residual allocating code; exact arena sizes |
| 5 | C2 budgeted type monomorphization, `builtin` first then `base` (`FPR_NO_TYPE_SPEC`) | text growth under budget (start at +10%), compile time linear | unboxed cells and register tuples; est. approach C cons |
| 6 | WCET mode: static arenas from `Cost` equations for admitted bounded callbacks; simple-risc first | admission refuses unproved budgets; board timing | predictability, not throughput |

Do first: phase 1. It is small, measurable on this PR's benchmarks, changes no
contract and removes the most surprising costs (an inlined `Option` helper
should never allocate).

## Open questions for Jack

1. Is a runtime-object revision (phase 4) acceptable this quarter, given that
   it touches every walker and message copy?
2. Code-size budget for type monomorphization per profile, especially on Tang
   Nano 20K BRAM: a fixed percentage, an absolute cap, or manifest-declared?
3. Should list fusion be allowed to change *which* allocation happens (none)
   when a callback traps midway? (Output and trap order are preserved either
   way; only the allocation count changes.)
4. Should `List` stay the default sequence in std APIs, or should more of std
   return `Vector` where the length is known (B5)?
5. Is a source-level unboxed/representation annotation ever wanted, or should
   representation stay entirely compiler-chosen?
6. For WCET admission, is a header-free arena cell acceptable even when it means
   such objects cannot be individually freed (region-only)?

## Risks

- Fusion and specialization extend the passes already found quadratic; without
  scaling gates compile time regresses before runtime improves.
- Monomorphization interacts with cache identity, separate units and hot
  reload; the fallback to the uniform entry must always exist.
- Representation changes are easy to get subtly wrong in walkers; differential
  testing must include message passing between actors.
- Estimates above are hypotheses until each phase measures them; only the
  fpr, C and GHC timings and allocation counts in the evidence table are
  measured.

## How other compilers handle this

Checked against sources this session:
[Perceus (Koka)](https://www.microsoft.com/en-us/research/wp-content/uploads/2021/06/perceus-pldi21.pdf):
precise RC with reuse of unique constructor memory ("functional but in-place").
[Lean 4 IR](https://lean-lang.org/doc/api/Lean/Compiler/IR/Basic.html) and
[Counting Immutable Beans](https://arxiv.org/pdf/1908.05647): scalars unboxed in
monomorphic code and boxed at polymorphic boundaries; reset/reuse.
[OxCaml unboxed types](https://oxcaml.org/documentation/unboxed-types/intro/):
layouts as part of kinds (`value`, `float64`, `bits64`, unboxed products).
[MLton](http://www.mlton.org/Monomorphise) monomorphises whole programs
(reported max code growth around 30%) and [flattens](http://mlton.org/Flatten)
tuples into arguments and constructors.
[Roc](https://www.roc-lang.org/docs/main/langref/types/) monomorphizes,
stores records/tuples/non-recursive tags inline, uses Perceus-style
opportunistic mutation and defunctionalizes closures.

From recollection, not checked this session: GHC uses a uniform boxed
representation for polymorphism with levity/representation polymorphism,
worker/wrapper strictness unboxing, `SPECIALISE` and foldr/build fusion (the
fused rows above are consistent with this); Rust monomorphizes every generic
instantiation; Futhark has no lists, only arrays, with aggressive fusion; stock
OCaml boxes everything but immediates and float arrays/records, with flambda
inlining but no general unboxing.

## Reproduce

```
tests/bench/unbox/measure.py 15 > out.json   # ~10 min; needs gcc, optional ghc
```

Programs: `tests/bench/unbox/*.fpr`, `*.sol`, references `ref.c`, `ref.hs`.

## Addendum (1 November, later session): three additions from further analysis

These extend the proposal without changing its phases; they answer gaps the
[follow-ups inventory](2026-10-31-ZERO-OVERHEAD-FOLLOWUPS.md) and the B1
review surfaced. B1's first slice has since landed
([its record](2026-11-01-LIST-FUSION.md)).

**A. Deterministic per-inductive representation is C2's cache-identity
answer.** C2's listed risk is cache fragmentation: if a type's
representation depends on the surrounding program, every unit mentioning it
needs a program-specific identity. The structural escape: make each type's
representation a pure function of its *definition* (Lean 4 style - nullary
constructors become immortal statics; a single scalar constructor becomes an
immediate; a small all-unboxable arity becomes an unboxed struct; recursive
or mixed types stay boxed nodes), with one global promotion rule (managed
when shared or crossing a dynamic boundary). The choice then never depends
on the program, so the `kindTag` vocabulary already present in
`Representation/Types.hs` enters unit cache identities without
cross-program fragmentation - and clone identities stay deterministic as
`f(origin, instantiation)`. This is what keeps MLton's whole-program
compile-time trap out of C2.

**B. B6, proof-gated flat lists.** Rejecting B4 as a default is correct.
But the wish-list idea it answers has a conditional form the compiler's own
discipline supports: where the ownership analysis proves a List is built
once and consumed linearly - no tail sharing, no second consumer - the same
pattern-match API may lower onto chunked or flat storage with observably
identical behavior, because no program that could observe the difference
exists. Where the proof fails, refuse and keep honest cons cells, with a
lint steering bulk shapes to `Vector`; a warned fallback would ship a
silently different program, which this tree does not do elsewhere. B6
depends on C1/C2 machinery, keeps `O(1)` cons and sharing for every list
the proof does not cover, and would sit behind its own `FPR_NO_*` flag.

**C. Two C2 prerequisites worth naming now.** Multi-register returns:
today a result is one word in `a0`; `Option Int` in registers or an unboxed
pair return is a calling-convention extension, exactly what the `.abirev`
stamp exists to version. And a cheap link-tier experiment forcing `RawWord`
fields on one non-escaping type (for example `Pair Int Int`) through the
existing pipeline with a differential oracle is the natural phase-5
pre-step: it proves the representation plumbing end to end before any
budget or cloning work.

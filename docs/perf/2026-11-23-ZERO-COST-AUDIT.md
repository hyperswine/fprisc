# Zero-overhead abstraction audit, 23 November 2026

Kind: measurement notes. Not a design decision. No compiler changes.
Tree: `main` at **512680b3** (after #109/#110), built on the Linux x86-64 box (8 vCPU VM, ghc-9.8.2 via
`cabal.project.local`). C is gcc 14.2 `-O2 -fno-tree-vectorize`.

Question (Jack, 23 Nov): for 1.0, where do abstractions still cost something that we have not looked at yet?

## Method

- 72 small FP-RISC programs and 4 C programs in [`2026-11-23-zero-cost/`](2026-11-23-zero-cost/): each `aNN`/`bNN` is the abstract spelling,
  `hNN` the same computation lowered by hand in FP-RISC, `cNN.c` the C reference. Every pair prints the same value.
- `fpr build -o` (default posix profile, all default passes), then `valgrind --tool=callgrind`, **median of 3**, at
  most 2 at once. Raw medians: [`callgrind-medians.txt`](2026-11-23-zero-cost/callgrind-medians.txt).
- Per-iteration = (Ir − Ir of `empty.fpr`, 0.23 M) / iterations. Loops are 10 M iterations (lists: 10 000 × 1 000
  elements; strings: 1 M).
- Root causes come from `objdump` of the hot function, `--remarks=all`, callgrind call counts and the source.
  Where a cause is read from source but not confirmed by an experiment it says **likely**.
- Already covered in earlier work and not redone: proven-small Int / raw I64 / F64 locals, exact Int
  (still ~1.20x, [EXACT-INT-REVIEW](../2026-11-22-EXACT-INT-REVIEW.md)), RawInts versioning, regalloc 1-2,
  closure callbacks (#95), string runtime, MutMap/alter/sort, reuse + regions, keyed-list/OwnedMapFold rules,
  shallow-stack leaves.

## Results (instructions per iteration)

| # | abstraction | abstract | hand-lowered | ratio | verdict |
|---|---|---:|---:|---:|---|
| 01 | generic recursive HOF loop, Int acc | 33.3 | 33.3 | 1.00 | zero-cost |
| 02 | same, F64 acc | 28.2 | 28.2 | 1.00 | zero-cost |
| 03 | `Sig`/`Struct` dictionary (literal struct) | 32.3 | 33.3 | 0.97 | zero-cost |
| 04 | capturing lambda into a user HOF | 33.3 | 33.3 | 1.00 | zero-cost |
| 05 | `compose f g` passed to a HOF | **151.5** | 32.3 | **4.68** | gap G4 |
| 27 | record of functions `{step, done}` | **123.1** | 33.3 | **3.69** | gap G4 |
| 06 | `List.fold` + lambda (std) | 40.4 | 45.5 | 0.89 | zero-cost |
| 07 | `List.fold` + lambda (prelude) | 40.4 | 45.5 | 0.89 | zero-cost |
| 08a | `map |> sum` | 40.4 | 45.5 | 0.89 | fused |
| 08 | `map |> filter |> sum` (captures k) | **107.2** | 53.9 | **1.99** | gap G6 |
| 08b | same, no capture | 90.2 | 53.9 | 1.67 | gap G6 |
| 09 | `List.map (add k)` (PAP) / lambda | 71.9 / 71.9 | 83.1 | 0.87 | zero-cost, PAP = lambda |
| 10 | Option returned + matched (inlined) | 47.6 | 47.6 | 1.00 | zero-cost |
| 10b | user-declared option-like ADT | 47.6 | 47.6 | 1.00 | zero-cost |
| 11 | Option from a non-inlined recursive fn | 84.8 | 74.9 | 1.13 | 2-register return, no alloc; rest is G9 |
| 12 | `Result Int String` | 61.2 | 60.3 | 1.02 | zero-cost |
| 13 | enum (4 nullary constructors) dispatch | **54.9** | 43.5 | **1.26** | gap G7 (C: 10.3) |
| 14 | newtype `Meters Int` as loop state | **117.3** | 32.3 | **3.63** | gap G1/G2 |
| 14b | newtype built and matched, Int loop state | **117.3** | 32.3 | **3.63** | gap G1 |
| 14r | single-field record as loop state | **107.2** | 32.3 | **3.32** | gap G2 |
| 15 | `area (mk i)`, 2-constructor sum, inlined | **121.3** | 54.1 | **2.24** | gap G1 |
| 15b | `area (Circle x)`, no `if` | **119.2** | 51.6 | **2.31** | gap G1 |
| 16 | record loop state via `{s | ...}` | 49.5 | 49.5 | 1.00 | zero-cost |
| 17 | row-polymorphic `getX` on two records | 54.6 | 43.4 | 1.26 | gap G9 |
| 18 | record / tuple multi-return | 172.7 / 172.7 | 162.7 | 1.06 | near zero |
| 19 | F64 3-field record through `add3` | **73.9** | 29.3 | **2.52** | gap G2 (C: 6.0) |
| 19i | same with Int fields | **152.5** | 51.5 | **2.96** | gap G2 |
| 20 | `case Vec.get i v of (x, v2) -> …` | **168.8** | 26.5 | **6.36** | gap G3 (C: 4.0) |
| 20b | `case Vec.at i v of (x, v2) -> …` | **170.8** | 26.5 | **6.44** | gap G3 |
| 20c | `(x, v2) = Vec.get i v` | 26.5 | 26.5 | 1.00 | the fast spelling |
| 21 | `Int.max` / `Int.min` | 56.6 | 56.1 | 1.01 | zero-cost |
| 22 | mutual recursion even/odd | 35.3 | 35.3 | 1.00 | zero-cost |
| 23 | precondition `b != 0`, arg `bor i 1` | 75.7 | 62.5 | 1.21 | gap G10 |
| 24 | `measure` (checked) vs `unsafe` | 40.4 | 40.4 | 1.00 | no residue |
| 25 | `"k" + "=" + "v" + ";" + "x"` | **650.2** | 37.4 | **17.4** | gap G5 |
| 26 | Bool helpers `both (isSmall a) (isSmall b)` | **57.7** | 40.2 | **1.43** | gap G8 |
| 29 | `List F64` sum per element | 11.1 | (Int list 27.3) | — | F64 cells are fine |

Calibration against C on the same box: the hand-lowered FP-RISC loops are themselves 3.5–6.6x C
(h01 33.3 vs 5.0, h13 43.5 vs 10.3, h19 29.3 vs 6.0, vec sum 26.5 vs 4.0). That is the scalar baseline on x86-64
(G11), separate from the abstraction ratios above, which are mostly target-independent (allocation, indirect calls,
runtime calls).

## Ranked gaps

| rank | gap | measured | root cause | fix | effort | risk | layer |
|---|---|---|---|---|---|---|---|
| G1 | Case of known constructor misses let-bound constructors | 2.24–3.63x (15, 15b, 14b) | `Core/Typed/CaseKnown.hs` `known` accepts only a syntactic `Construct`/`TupleValue`/saturated constructor application as the leaf. After inlining, `area (Circle x)` becomes `s = Circle x; case s of …`, so the leaf is a `Var` and the pass declines. Builtin Option works (a10 → 78.6 per iteration with `FPR_NO_CASE_KNOWN=1`, so the pass does fire there); user `Shape`/`Meters` built then matched do not (b15 unchanged with the pass off). The pass also runs once, after inlining (`Compiler/Compile/Link.hs:36`). | Carry an environment of let-bound constructor/tuple/record values whose binder is used only by cases and projections; iterate CaseKnown with the inliner to a fixed point (or one extra round). | S–M | low (checked pass, verify already in place) | Core (all) |
| G2 | Fresh records/newtypes passed as loop-carried state are heap-allocated each iteration | 2.52–3.63x (14, 14r, 19, 19i) vs 1.00x for the `{s | …}` update form (16) | Product parameters admit the update shape but not a fresh literal/constructor at the recursive call (**likely** `Core/Opt/ProductParameters.hs`); the loop gets a region and 2–4 inline allocation sites. | Constructor specialization (SpecConstr-style worker/wrapper): when every self-call passes a known constructor/record literal, split the parameter into its fields. | M | medium (ABI of private workers, region/reuse interplay) | Core; MVU state loops, nbody-style F64 records |
| G3 | `case Vec.get/at … of (x, v2) ->` takes the slow path | 6.4x vs the `(x, v2) = …` spelling (20, 20b vs 20c); per read: `h_get` + `row_at` + `fpr_alloc` of the pair (10 M calls each) | `Inline.hs:235-257` `vecPeek` matches only the `CLet` desugaring of the tuple binding; the single-alternative tuple `case` lowers differently. | Normalize an irrefutable single-alternative tuple `case` to the let pattern before vecPeek and the typed vector-read plan. | S | low | Builtin (`Vector 1`) |
| G4 | Closures that come out of a call or a record are called indirectly | compose 4.68x (05), record of functions 3.69x (27) | `Mono.hs` `Known = (Name, [Core])`: only names and PAPs at the call site are known. `compose msk inc` is a call whose result is a lifted lambda; `o.step` is a field of a record literal. Remarks: "computed callback target is not safely known". | Inline small closure-returning functions (compose, flip, const, `by`) before callback specialization, and treat a record literal of known callbacks like a `Struct` literal (that path already specializes, row 03). | M | medium (code size budget) | Core / ExtBase (MVU `view`/`update` records, `std/order.by`) |
| G5 | String literal concatenation is not folded; chains allocate per `+` | 17.4x vs the folded literal (25): 4 `strcat` + 4 allocations per iteration for a constant | No constant folding of `String +`; a left-nested chain is n−1 separate `strcat`s. Interpolation already builds once (`$strcatT`, 1 allocation). | Fold literal `+` at compile time; lower an n-ary `+` chain to one sized concatenation as interpolation does. | S | low | Builtin/Base |
| G6 | Three-stage list pipelines over an existing list are not fully fused | 1.99x (08), 1.67x without capture | `Core/Typed/ListFusion.hs` `foldWith` fuses fold over range/map/filter one level; `map |> sum` fuses (1.00x), but with filter in the middle the profile still has a list producer (`$trmc` worker), a filter pass and `sum`. **Likely**: the composed callback from the first rewrite is not re-admitted to the fixed point, and there is no consumer rule over `mapFilter`/`filterMapped`. | Add fold/sum/length consumer rules for `mapFilter`/`filterMapped`, or re-admit composed callbacks; extend the 17-program gate with filter-in-the-middle chains. | S–M | low | Builtin/Base (std/list) |
| G7 | Nullary enums are pointers to static objects; matches are linear header compares | 1.26x vs Int dispatch (13); C 10.3 vs 54.9 | Constructors are static cells (`fpr_obj_opOf+0x20`); each alternative is a tag test + header load + compare; `opOf`'s result is not case-of-cased into `ap`. | Represent nullary constructors as immediates (as Bool/Unit now are), dense tags → jump table; let G1 fold `case (case n of 0 -> Add …) of Add -> …`. | M | medium (representation/codegenRev bump, ABI for exports) | Core |
| G8 | Booleans and overflow guards are materialized, then tested | 1.43x for Bool helpers (26); in raw loops the overflow guard is `jo; mov $1/$0; test; jne`, and the add is computed twice (h01) | X64 lowering emits `setcc/movzx/test` or a branch-built 0/1 for a condition that only feeds a branch; the raw-loop guard and the result are separate computations. | Branch-on-fresh-flag peephole in X64 (and check RV), reuse the guarded result; ties into EXACT-INT-REVIEW item 5 (X64 cheap paths still open). | S–M | low | all (backend) |
| G9 | Phantom loop regions | 1.26x (17), 1.13x (11) | The loop keeps "loop region selected" and a per-iteration region-budget check (`cmp $0x80000` with TLS loads) after the allocation it was for has been optimized away (0 allocation sites left in the loop). | Re-run region selection after CaseKnown/vecPeek, or drop the region when the typed IR has no allocation site in the loop. | S | low | Core |
| G10 | Unproven precondition leaves a check and a region in the loop | 1.21x (23) | `bor i 1 != 0` is not known to the interval facts; the call site checks `b != 0` and keeps the error path (`$strcatT` + `error`) inside the loop region. | Bitwise facts (`bor x 1 ≠ 0`, `band x m ∈ [0,m]`) in the interval pass; cold-out the failure path so no region is needed. | S | low | Core |
| G11 | Scalar baseline on x86-64 | h01 33.3 vs C 5.0 (6.6x) | Of h01's 33 instructions per iteration: fuel tick 3 (TLS load + memory RMW; A64/RV keep it in x27/s11 per [REGISTER-FUEL](../2026-11-10-REGISTER-FUEL.md)), two overflow guards with materialized flags (G8), the duplicated add, immediates loaded into registers. Read from the asm, not separately measured. | X64 register fuel; G8; EXACT-INT item 5. | M | medium (fuel soundness must hold) | all |

## Already zero-cost (confirmed this run)

Within ±3% of the hand-lowered form: generic HOF loops on Int and F64 (specialized, no boxing of F64), `Sig`/`Struct`
with a literal struct, non-escaping capturing lambdas, PAP = lambda, std and prelude `List.fold` with a lambda,
`map |> sum` fusion, `List.map`, Option returned and matched (builtin and user-declared), `Result` with a string
error, record loop state through `{s | …}`, tuple and record multi-returns (equal to each other, 1.06x vs scalar),
`Int.max`/`Int.min`, mutual recursion, `measure` vs `unsafe` (no WCET residue), let-form vector reads. An Option
returned from a non-inlined recursive function comes back in two registers (`$worker.ret2.$variant.firstOdd`, no
allocation).

## Not measured here

Actor send/receive (pingpong was measured in the 11-17 bisect), FFI marshalling, `parMap` (not implemented; design in
[PARALLEL-MAP-FOLD](../2026-11-15-PARALLEL-MAP-FOLD.md)), String/Bytes conversions, MutMap ops, `Sig` with a
non-literal struct (first-class by SEMANTICS §12), laziness (the language is strict; no thunks). A64 numbers: this run
is x86-64 only; A64 has register fuel and the exact-Int cheap paths, so G8/G11 are smaller there, while G1–G7 and
G9–G10 are IR-level and expected on both (not measured on A64).

## Reproduce

`buildall.sh.txt` and `cgall.sh.txt` in the folder (helpers outside the repo's Sol-only rule, saved as `.txt`).
`FPR_HOME=<tree> fpr build -o X.bin X.fpr`; C: `gcc -O2 -fno-tree-vectorize`.

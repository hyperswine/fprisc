# Native performance: what is structurally holding it back

Date: 2026-10-25. Kind: review with proposals. Applies to `main` at
`83ee345`. Evidence: a source reading of `compiler/` (`Compile.hs`,
`Inline.hs`, `Core/Opt/Pipeline.hs`, `Codegen/Lower.hs`, `Codegen/IR.hs`,
`Codegen/Simplify.hs`, `Codegen/Allocate.hs`, `Codegen/Target/{A64,X64,RV}.hs`),
`runtime/runtime.c`, and the dated pages cited. **Nothing was built or
benchmarked for this page.** Every expected effect below is a prediction to
confirm against the benchmark set in the last section.

Status: proposals, none implemented. Companion to
[the 2026-10-25 architecture review](2026-10-25-ARCHITECTURE-REVIEW.md),
which ranks code-structure work; this page ranks run-time cost.

## What changed since the last performance notes

[2026-09-30-SUGGESTIONS](2026-09-30-SUGGESTIONS.md) section 1 described a
frame-slot generator with the inliner and peephole gated to builtin `--arc`.
That is no longer the tree. Since about 2026-10-15 Base compiles through the
typed IR: Core, `Codegen.Lower` to an SSA IR with block parameters and explicit
representations (`TVal`, `TInt`, `TRaw`, `TPred`, `TAddr`, `TF64`), the
`Codegen.Simplify` passes, per-ISA selection, linear-scan allocation
(`Codegen.Allocate`) and frame layout. The Base inliner runs
(`inlineWith pureOutside 3 24`, `Compile.hs`). A self tail call becomes a loop
that skips the stack check. Those items of the 09-30 page are resolved.

What remains is a small number of structural choices around that pipeline.

## 1. Many common operations are calls, and every call clobbers the scratch registers

`Codegen.Allocate`'s contract: a value live across any instruction that
contains a call (a generated call, a C primitive, the fuel tick, the stack
check, a slow path's primitive) must be in the scheduler-preserved
callee-saved budget (x19..x27 on AArch64, rbx and r12..r15 on x86-64) or in a
frame slot. The budget is 9 registers on AArch64 and 5 on x86-64.

Operations that are calls today:

- **Every allocation.** `OMake` selects to a call to `fpr_alloc`
  (`A64.hs`, `X64.hs`, `RV.hs`), which reaches `fpr_hart()`, `cur_pool` and
  `alloc_in`. There is no inline bump fast path. In any loop that builds
  values, every live value is pushed into the callee-saved budget or a slot.
- **The fuel tick** at every function entry and at a self-loop's header. The
  entry sequence declares `siClobbers = callerSaved` for its slow path
  (`fpr_fuel_exhausted`), so loop-carried values cannot use scratch registers
  even though the slow path is rare.
- **Scalar vector access in user code.** `Inline.vecPeek` rewrites
  `Vec.get`/`set`/`len` to pair-free C primitives in `vec.c`; only fused and
  kernel loops use the IR's own `OIndex`/`OLoad`/`OStore`.
- **Deep equality** (`OEqVal`), **generic application** (`OApply`), and most
  string operations beyond `OStrLen`/`OCharAt`.

### Proposal

1. **Inline allocation fast path.** Bump within the current slab in generated
   code (pointer and limit in the hart block, as the region clock already is
   at cell 58); call C only when the slab is exhausted.
2. **Clobber-free slow paths.** The tick's and the allocator's slow paths save
   and restore the live scratch registers themselves (a per-site cold stub, or
   a runtime entry that saves everything), so the fast path declares no
   clobbers. Loops can then keep values in scratch registers. On x86-64, with a
   five-register budget, this is expected to matter more than any other change
   here.
3. **Inline vector fast paths.** Lower scalar `Vec.get`/`set`/`len` to the
   existing address and load/store operations behind the representation and
   bounds guards, with the C primitive as the slow path.

## 2. Optimization stops at unit boundaries

- **Inlining is within a unit only** (size 24, 3 rounds). Every `std` module
  is its own unit, so `List.fold`, `String.*`, `Map.*` never inline into the
  loops that call them.
- **Typed callback specialization is local.**
  [2026-10-25-TYPED-CALLBACKS](2026-10-25-TYPED-CALLBACKS.md): "root/global/
  imported bodies are not cloned here." `List.map f xs` from std keeps a
  generic call to `f` per element.
- **Unboxed scalar signatures (workers) are for private functions.** Public
  and cross-module calls pass tagged `TVal`s.

### Proposal

Export inlinable and specializable bodies in a unit's interface, keyed by the
unit's hash. Content-addressed modules make this unusually safe: the unit cache
already keys on dependency hashes, so a changed dependency recompiles every
unit that inlined from it. Live-reloadable boundaries (calls through a module
value) stay non-inlinable, as now, which keeps reload sound.

## 3. The IR optimizer is shallow

`Codegen.Simplify` runs conversion folding, branch threading on Bool joins,
common-subexpression elimination within a block, float-tree fusion and
dead-code removal. There is no loop-invariant code motion, no
common-subexpression elimination across blocks, and no range analysis. In a
loop:

- every `Int` `+`, `-`, `*` keeps its 63-bit overflow check (`OArith` traps in
  program order);
- every `OCharAt` keeps its bounds check;
- invariant checks and conversions are repeated each iteration.

### Proposal

An interval (or difference-bound) analysis over the IR, used to remove
overflow and bounds checks it proves, plus loop-invariant code motion for pure
operations and for checks that do not depend on the induction variable. Traps
that remain keep their program order, as `Simplify` already requires.

This is the same abstract domain as the refinement proposal in
[2026-10-12-MEMORY-I32-REFINEMENTS](2026-10-12-MEMORY-I32-REFINEMENTS.md)
section 3: one analysis can discharge preconditions at the source level and
drop `i + 1` overflow checks and `charAt s i` bounds checks at the IR level
when `0 <= i < n` is known. Sharing it is worth designing for from the start.

## 4. Register allocation

`Codegen.Allocate` is an initial linear scan (Poletto and Sarkar) with an
access-count victim choice; a spilled value stays in its slot for its whole
range, with no interval splitting. Combined with section 1, this multiplies
cost: high call density forces values into a small budget, and a spill lasts
the whole range rather than only across the call that caused it.

### Proposal

Interval splitting at block boundaries with move resolution (Wimmer-style
linear scan, or regalloc2's approach). Do sections 1 and 3 first: they reduce
the pressure that makes splitting matter, and their effect is easier to
attribute measured alone.

## 5. Representation and scheduling leftovers

- **`I64` is boxed**: each result is a 24-byte allocation and, per section 1,
  a call. The 10-12 proposal's `I32` would be unboxed on 64-bit targets; an
  unboxed `I64` needs a different fix for the pointer-confusion hazard that
  forced boxing (for example a precise layout descriptor per frame and field,
  as builtin ARC already has).
- **`Word`/`Addr` are boxed** in manual-ownership builtin builds.
- **The fuel tick runs every iteration.** A loop with a verified measure could
  tick once per K iterations, or charge its bound once at entry: `Cost.hs`
  already derives it. The scheduling contract is about bounded time between
  safepoints, and a measured bound keeps that bound explicit.

## Order of work and how to measure it

`bench/baseline.json` predates the typed IR becoming the default, and the last
gap-to-C attribution ([2026-10-20-FIB-GAP-TO-C](2026-10-20-FIB-GAP-TO-C.md):
fib about 3.4x clang `-O2`) was measured on the retired generator. So:

0. **Re-baseline** `fib`, `sha`, `byteloop`, `nbody`, `strbuild`, `vecread`,
   `helpers`, `pingpong` on the current compiler, AArch64 and x86-64, with a
   C reference for `fib`, `sha` and `byteloop`.
1. **Clobber-free tick and allocation fast paths** (section 1, items 1 and 2).
   Expected: `strbuild`, `nbody`, `helpers`, and any allocating loop; more on
   x86-64.
2. **Inline vector fast paths** (section 1, item 3). Expected: `vecread`.
3. **Cross-unit inlining and specialization for std** (section 2). Expected:
   anything built on `std/list`, `std/string`, `std/map`.
4. **Range analysis and invariant motion** (section 3). Expected: `byteloop`,
   `sha`.
5. **Interval splitting** (section 4), measured after 1-4.
6. **Tick amortization for measured loops** (section 5).

Each step lands with its benchmark delta recorded against the step-0 baseline,
and with `Codegen.Eval` differential checks unchanged, since every one of these
changes either moves code or removes a check.

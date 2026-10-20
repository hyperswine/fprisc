# The gap to C on fib: what the calling convention and the guards cost

Date: 2026-10-20. Kind: attribution record. Base: FP-RISC `3206b84`
(code generation revision 51), the register-allocation design page at
`35985c7` on branch `register-allocation-design`, Apple M4, macOS, Apple
clang at `-O2`.

Follow-up, 2026-10-20:
[Native cost experiments](2026-10-20-NATIVE-COST-EXPERIMENTS.md) corrects the
checked-C and numerical attribution claims below, measures two guard variants,
and records a direct-literal worker candidate. The half/quarter/quarter split
below must not be treated as measured cost attribution.

## The question

[The register-allocation design page](2026-10-19-REGISTER-ALLOCATION.md)
measured the ceiling of a register allocator on `tests/bench/fib.fpr`
by hand-editing the kept assembly: stock 65 ms, hand-allocated 50 ms
(1.30x), and `long fib(long)` compiled by clang with no checks 19 ms
(3.4x). It attributed the remaining 2.6x to "the calling convention
itself (a frame, two saves, a `bl`/`ret` pair and four overflow guards
per call, against clang's leaf-optimized recursion)". This page says
what, in that 2.6x, is which. The answer changes what the number means:
about half of it is not convention or guards at all.

## What clang emits

`cc -O2 -S` of

```c
long fib(long n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); }
```

on this machine, comments and directives removed:

```
_fib:
    stp  x20, x19, [sp, #-32]!
    stp  x29, x30, [sp, #16]
    add  x29, sp, #16
    cmp  x0, #2
    b.ge LBB0_2
    mov  x19, #0
    b    LBB0_4
LBB0_2:
    mov  x19, #0
    mov  x20, x0
LBB0_3:                       ; Inner Loop Header
    sub  x0, x20, #1
    bl   _fib
    mov  x8, x0
    sub  x0, x20, #2
    add  x19, x8, x19
    cmp  x20, #3
    mov  x20, x0
    b.hi LBB0_3
LBB0_4:
    add  x0, x0, x19
    ldp  x29, x30, [sp, #16]
    ldp  x20, x19, [sp], #32
    ret
```

Two facts about it:

1. **It is not the same algorithm.** `LBB0_3` is a loop. Clang rewrote
   `fib(n-1) + fib(n-2)` as "call `fib(n-1)`, add it to an accumulator
   in `x19`, subtract 2 from `n`, repeat while `n >= 2`". The second
   recursive call of every level is gone, replaced by the next iteration
   of the loop. The number of real calls is roughly halved. FP-RISC makes
   every call the source names.
2. **Per iteration it is eight instructions**, and the frame is six
   instructions in and out (two pre-indexed `stp`, two `ldp`) amortised
   over the iterations of one activation.

A checked variant (`__builtin_add_overflow` / `__builtin_sub_overflow`
with `__builtin_trap`) compiles to the same shape with `subs`/`adds` and
one `b.vs` per operation: for a 64-bit `long`, the hardware overflow flag
is the overflow check, one instruction.

## What FP-RISC emits per call

From the hand-allocated listing in the design page (its section 2), the
recursive path of the fib worker is about 51 instructions per call, in
these parts:

| part | instructions | what it is |
|---|---:|---|
| frame in | 5 | `sub sp`, `stur x30`, `stur x29`, `add x29`, `stp x19, x20` |
| stack-segment check | 5 | two loads from the hart block (`x28`), compare, branch |
| fuel tick | 5 | load, decrement, store, branch on the hart block |
| `n < 2` | 3 | compare, branch, move |
| three guarded operations (`n - 1`, `n - 2`, the final `+`) | 3 x (1 + 4) = 15 | the operation, then the 63-bit fit check `lsl`, `asr`, `cmp`, `b.ne` |
| two calls and the moves around them | 6 | `mov x0`, `bl`, park the result in `x20`, repeat |
| frame out | 6 | `ldur x30`, `mov x9, x29`, `ldp`, `ldur x29`, `mov sp, x9`, `ret` |
| the rest | about 6 | branches to and over the cold slow paths |

The stock (non-hand-allocated) path adds about 16 slot loads and stores
to this; that is the 1.30x the allocator would recover, and it is already
counted in the 50 ms.

## The attribution

Against clang's 14 instructions per iteration and half as many calls,
the 2.6x splits roughly so:

- **About half: the halved call count.** Clang's loop makes half the
  calls. Nothing in FP-RISC's generator attempts this rewrite (it is not
  a tail call: the second call's result feeds an addition, and the
  rewrite turns the addition into an accumulator). It is specific to the
  shape of binary recursion where one branch can be accumulated, so it
  says little about ordinary programs, and it is not something a
  register allocator or a convention change produces.
- **About a quarter: the guards, done the long way.** Twelve instructions
  per call for three checks, where the hardware could do each in one
  (the next section).
- **About a quarter: frame, stack check and fuel tick together.** Twenty
  one instructions per call against clang's six. The design page's
  variants B and C measured the stack check at nothing and the fuel tick
  at about 2% of fib's time: both are independent loads and a predicted
  branch, which the core overlaps with the call chain. The frame is five
  more instructions than clang's because the return address and frame
  pointer are stored separately and `sp` is rebuilt from `x29` on the
  way out: with a segmented, growable stack a frame cannot assume `sp`
  is where it left it. These are the price of preemption (the fuel) and
  of growable stacks (the check and the `fp`-chained frame), and the
  core mostly hides them.

The split is from instruction counts and the design page's component
timings; the per-part times were not measured separately beyond the
fuel and stack variants it recorded. The core's out-of-order execution
is why 51 instructions against 14 (and twice the calls) measures as 2.6x
and not 7x.

## The guards: what the IR can say and what the targets could

Where the twelve instructions come from needs two facts kept apart.

**The tagged path already has the one-instruction algebra.** The base
profile's inline `+` ([2026-10-12-INT-OVERFLOW.md](2026-10-12-INT-OVERFLOW.md),
`Codegen.inlineTable` `$arc.add`) computes `(a0 - 1) + a1`: an Int is
`2n + 1`, so that sum is `2(x + y) + 1`, and the 64-bit word overflows
exactly when `x + y` leaves the 63-bit Int range. Likewise `a0 - a1`
is `2(x - y)` for `-`. The word's signed overflow IS the Int's overflow.
On a machine with flags that is `subs`, `adds`, `b.vs`.

**But the IR is RISC-V, which has no flags.** `Codegen.hs` emits RISC-V
text that `A64.hs` and `X64.hs` translate line by line, so the tagged
path tests the word overflow with the RISC-V idiom:
`xor`, `xor`, `and`, `srai`, `bnez` after the `add`, five instructions,
and the A64 translator emits five instructions for them. That is the
"ten instructions where it was two" the overflow page recorded.

**The worker path gave the algebra up.** The private scalar workers
([2026-10-18-PRIVATE-WORKERS.md](2026-10-18-PRIVATE-WORKERS.md)) that
fib runs through hold raw untagged words, so the word overflow no longer
coincides with the Int's. They use the fit check instead
(`Codegen.hs` `fit`): `slli t1, t0, 1; srai t1, t1, 1; bne t1, t0, slow`,
three RISC-V instructions, four on A64 (`lsl`, `asr`, `cmp`, `b.ne`).
That is the twelve per fib call.

**What the targets could do**, at the translator, without changing the
IR or what Int means:

- The tagged idiom `add; xor; xor; and; srai; bnez` is one pattern.
  `A64.hs` could recognise it and emit `adds` and `b.vs` (`X64.hs`:
  `add` and `jo`): seven instructions to two per tagged `+`, and the
  same for `-`.
- The fit idiom `slli; srai; bne` tests whether bits 63 and 62 of the
  result are equal. On A64 that is `eor t, r, r, lsl #1` followed by
  `tbnz t, #63, slow`: four instructions to two per raw-word operation.
  On x64 it stays three.
- Alternatively the worker could keep its values in the tagged domain
  and use the first pattern; that trades the fit check for a `sub #1`
  before each add, and makes the worker's benefit over the tagged path
  smaller than it looks.

Either way the fib guards go from twelve instructions per call to six,
on every Int `+` and `-` in every program, with the slow paths and the
panic text unchanged. The peephole runs before translation and the
translators have no peephole of their own (the design page's section
1.2), so this is new mechanism in `A64.hs`/`X64.hs`, small, and gated
by the same differential suites (`tests/base/intovf.fpr` in
`check_base.py` covers both ends of every operation).

## What this means for the roadmap

- The design page's "1.3x on call-and-arithmetic code" for the
  allocator stands. This page does not raise it.
- The guard lowering is a separate, smaller change with a comparable
  effect on the same code (about a quarter of the remaining gap on fib,
  and it applies wherever Int arithmetic is dense: `byteloop`, `sha`,
  the kernels' scalar tails). It should be measured on its own before
  the allocator, because it is a page of translator code and no new
  storage model.
- The halved call count is not a target. A rewrite of binary recursion
  into a loop with an accumulator reassociates the partial sums, which
  is sound for a wrapping C `long` and not in general for a trapping
  Int: a different order of partial sums can trap where the source's
  order would not, or the reverse, so the compiler would have to prove
  no intermediate can overflow. It is not worth a pass for the shapes
  real FP-RISC programs have; fib is the benchmark that flatters it.
- Frame, stack check and fuel tick are the price of the actor model and
  stay. Their measured cost on fib is a few percent; the instruction
  count overstates them.

## Not verified

- The quarter / quarter / half split is from instruction counts and the
  design page's two component timings, not from a per-part measurement.
  A hand edit that only shortens the guards (the two-instruction forms
  above) would measure the guard quarter directly; it was not made.
- The x64 and RV64 Linux forms of the same comparison were not made; the
  RISC-V idioms are the IR's and cost the same on RV64, where there is
  no flag form to lower to.
- Clang's loop rewrite was observed on this Apple clang at `-O2`; other
  compilers and levels may not do it, which would change the C side of
  the comparison, not FP-RISC's.
- Nothing in this page was run on a board.

## Reproduce

From this checkout, the C side:

```sh
printf 'long fib(long n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); }\n' > /tmp/fibc.c
cc -O2 -S -o - /tmp/fibc.c
```

The FP-RISC side is the design page's section 2: `fpr build --keep
tests/bench/fib.fpr`, then the hand edit and relink recipe recorded
there.

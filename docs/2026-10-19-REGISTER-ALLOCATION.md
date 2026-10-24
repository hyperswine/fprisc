# Register allocation in the base-profile generator

Status update, 2026-10-25: **historical design and measurements**, describing
the compiler at `3206b84`. The slot generator, RISC-to-A64/x64 translators,
peephole and `# wcet:` pipeline described below have been
[retired](2026-10-23-TYPED-GENERATOR-RETIREMENT.md). Current native allocation
uses `Codegen.IR` and `Codegen.Selected`, then `Codegen.Liveness`,
`Codegen.Allocate` and `Codegen.Frame`; `Codegen.Bounds` reports
`native-insns-v1`. The old module paths and proposed rollout switches below
remain as historical evidence, not instructions for the current compiler.

Date: 2026-10-19. Kind: design, with the measured ceiling the design is
bounded by. Answers items 4 and 5 of
[SUGGESTIONS section 1.7](2026-09-30-SUGGESTIONS.md#17-order-of-work-and-how-to-know-it-worked)
(keep let-bound locals in callee-saved registers; untagged `Int` locals).
Nothing in the compiler changes with this page. Evidence: a reading of
`compiler/Codegen.hs`, `compiler/A64.hs`, `compiler/X64.hs`,
`compiler/Peephole.hs`, `compiler/Workers.hs` and `compiler/Inline.hs` at main
`3206b84` (codegenRev 51); the assembly `fpr build --keep` wrote for
`tests/bench/fib.fpr`, `tests/bench/helpers.fpr` and `tests/bench/strbuild.fpr`;
and two hand-edited copies of that assembly, relinked the way `fpr build`
links and timed against the stock binaries. Times are from this Mac (Apple
M4, macOS, `fpr build` default harts) with other sessions' builds running
beside them: ratios are the finding, milliseconds are indicative.

What was done since the 2026-09-30 roadmap, and what this page builds on:
[NATIVE-PERF](2026-09-30-NATIVE-PERF.md) (inline Int operators, jumping
conditions, direct arguments, the peephole on the shared IR),
[REGISTERS-AND-COSTS](2026-10-01-REGISTERS-AND-COSTS.md) (`registerSlots`:
up to five whole-function slot promotions), [PRIVATE-WORKERS](2026-10-18-PRIVATE-WORKERS.md)
(raw-Int scalar workers and two-field accumulators), the base-profile inliner
with its `$fuel` safepoint (`Inline.hs`).

## 1. The shape of the problem, from the code

### 1.1 How a value flows through `Codegen.hs`

The generator is a stack machine over Core. `gen`/`genT` (`Codegen.hs:1059`,
`1284`) produce every expression's value in `a0`; the environment
`env :: Map String Int` maps a variable to a frame slot addressed through
`s0`; `nxt` is the next free slot. The pieces, in the order a body meets
them:

- **Frame** (`compileFn`, `:615`): `nslots = params + slotsNeeded body + 2`
  words below the saved `ra`/`s0` pair, 16-aligned (`framePro`). Slot k is
  `-(3+k)*W(s0)` (`slotRef`); past the 12-bit displacement `ldSlot`/`stSlot`
  go through `t2`. Parameters are stored to slots 0..n-1 first thing
  (`sd a0, -24(s0)` ...), params 8+ come from the hart spill cells.
- **Entry safepoints** (`:651`-`:705`): one `mv t0, tp` (the hart block),
  then unless the function is *provably shallow* (frame <= 1024 and no
  `call fpr_fn_`/`jalr` in its body) the stack check (`mv t1, sp; ld t2;
  sub; ld t2; bltu; call fpr_stack_grow; beqz; mv sp, a0`), then the fuel
  tick (`ld t1, 0(t0); addi -1; sd; bgtz; call fpr_fuel_exhausted`). Both
  run after the parameters are in slots, because both are real C calls.
- **`let`** (`goThen`, `:1480`): the right-hand side is generated into
  `a0`, `sd a0, slot(nxt)`, the body runs with `x -> nxt` and `nxt+1`. A
  `let x = y` of a local is an alias (no code). After `normIn`, a block is a
  nest whose right-hand side is the deep part, so `goThen` threads the
  following code (`rest`) down into the innermost level.
- **Known saturated call** (`knownCallThen`, `:1498`): `stageArgs` evaluates
  each argument that is not *direct* (a local already in a slot, or an Int
  literal) into slot `nxt+i`; `argLoads` then loads `a0..a7` from those
  slots (a direct local loads straight from its own slot, a literal is an
  `li`); then `call`. In **tail** position the transfer restores `ra`/`s0`/`sp`
  exactly as the epilogue would and `j`s to the target (TCO for any known
  saturated tail call). Arguments 8+ ride the hart spill cells.
- **Constructor** (`CMk` in `goThen`, `mkAlloc` `:1437`): each field is
  generated into `a0` and *pushed* (`addi sp, sp, -16; sd a0, 0(sp)`); then
  `li a0, size; call fpr_alloc; li/sw tid; li/sw var`; then each field is
  popped (`ld t1, 0(sp); addi sp, sp, 16`) and stored into the object.
  Nullary constructors are immortal statics (`la`).
- **Conditions** (`jumpIf`, `:1538`): `if`/`case` conditions are jumping
  code. A tag test loads the scrutinee, then `andi/bnez` (an Int never
  matches), `lw 0(a0); li; bne`, `lw 4(a0); li; bne`. A comparison with an
  inline `Cond` expansion leaves `t0` and branches; otherwise the Bool is
  materialized and `lw t0, 4(a0)` tested.
- **Projection** (`CProj`): `ld a0, 8+W*i(a0)` after the scrutinee load.
- **Generic apply** (`base`, `:1611`): head and every argument pushed 16
  bytes each, then one `fpr_applyN`.
- **Inline primitives** (`inlineTable`, `:1085`): `+ - * / < > ...`,
  `charAt`, `strlen`, band/bor/bxor, F64 ops. Arguments are staged exactly
  as for a call, loaded into `a0`/`a1`, then the expansion runs in place:
  a guard (`t0`/`t1` only) branches to a *slow path that is a C call* to
  the primitive (overflow, zero divisor, non-Int operands).
- **Inlined callee** (`Inline.hs:94`): an inlined body starts with
  `$fuel 0`, which `genT` (`:1377`) emits as the entry fuel tick plus
  `la a0, fpr_unit` (the let of `$tick` is never used; the `la` is dead
  code the peephole does not remove).

After generation, two text passes run on the function's lines
(`compileFn`): `peepholeFor` (`Peephole.hs`: within a basic block, a reload
of a slot just stored or loaded becomes nothing or a `mv`; a slot never
loaded is never stored), then `registerSlots` (`:757`): count textual slot
accesses, take the five most accessed slots with at least six accesses,
give them `s1..s5` for the whole function, rewrite every `ld`/`sd` of those
slots to `mv`, save them after the frame opens and restore them before the
`ld s0, -16(s0)` of every teardown. It gives up when the body already
mentions `s1..s5` or addresses slots through `t2`. The unboxed vector
kernels (`compileUFn`/`genU`, `:2662`) and the Vec specialization loops
have a fixed register convention of their own and get neither pass; the
private scalar workers of `Workers.hs` are ordinary supercombinators and
get both.

### 1.2 What the three translators map and what each line costs

The rv64 emission is the IR. `A64.hs` and `X64.hs` translate it line by
line; the posix rv64 host (`RV64.hs`, cache tag `rv64posixr3`) rewrites
only `mv rd, tp` (a `%tprel` sequence, or `la.tls.ie` for a shared
module) and a `j` to a global into `tail` (JAL's one-MiB range).

| IR | rv64 Linux | a64 / a64mac (`A64.hs`) | x64 (`X64.hs`) |
|---|---|---|---|
| `a0..a7` | a0..a7 | x0..x7 | `%rax %rsi %rdx %rcx %r8 %r9`; a6/a7 ride the TLS cells `fpr_x64_a6/a7` |
| `t0 t1 t2` | t0 t1 t2 | x9 x10 x11 | `%r10 %r11 %rdi` |
| `s0` | s0 | x29 | `%rbp` |
| `s1..s5` | s1..s5 | x19..x23 | `%rbx %r12 %r13 %r14 %r15` |
| `s6..s9` | s6..s9 | x24..x27 | XMM2..5 shadow bank |
| `s10 s11` | s10 s11 | **unmapped** (`A64: unmapped register`) | XMM6..7 shadow bank |
| hart (`tp`) | tp (`%tprel`: 3 instructions) | x28, reserved (`-ffixed-x27 -ffixed-x28`): `mov x9, x28`, 1 instruction; 10 with Darwin TLV | `movq %fs:fpr_posix_hart@tpoff`, 1 instruction |

Costs the IR does not show (per lowered line):

- a64: `ld`/`sd`/`lw` are one instruction each (`ldur`/`stur`/`ldursw`);
  `li` is `mov` or a `movz`/`movk` chain; `la` is `adrp`+`add` (2);
  `andi`/`ori`/`xori` always materialize the mask in `x16` (2); `slt`,
  `seqz`, `snez` are `cmp`+`cset` (2); `beq`/`bne`/`bgeu`/`bltu` are
  `cmp`+`b.cond` (2); `call` is `bl` (1).
- x64: every `call` is `movq %rax, %rdi; subq $8, %rsp; call; addq $8, %rsp`
  (4); every function label gets `movq %rdi, %rax`; a tail `j` gets the
  `%rdi` fixup too. `sd ra`/`ld ra` lower to nothing (the hardware
  call/ret carry it; `raGuard` refuses other frame shapes). `slt`/`seqz`/
  `snez` are `pushq scratch; movq $0; cmp/test; setcc; movq; popq` (6);
  non-commutative three-operand arithmetic with `rd == r2`, register
  shifts and `div` push and pop as well. Any instruction naming `s6..s11`
  is wrapped in `pushq r; movq %xmmN, r; <op>; movq r, %xmmN; popq r`
  (+4 per line), and a function that uses the bank spends 14 instructions
  around every call saving and reloading XMM2..7 (System V preserves no
  XMM register).
- The actor context switch preserves exactly the IR's callee-saved set:
  `machine/unix/ctx_rv64.S` s0..s11 and fs0..fs11, `ctx_a64.S` x19..x27 and
  x29 (never x28), `ctx_x64.S` rbp rbx r12..r15. The XMM bank survives a
  switch only because the translator already saved it around the `call`
  that switched.

### 1.3 Representative emitted sequences, with the memory traffic counted

All quotes are the rv64 IR of `fpr compile --system=posix --target=rv64`
over the bench programs (`fpr build --keep` writes the same functions
lowered). Counts are slot loads and stores of the function's own frame,
not the object or safepoint accesses.

**A let chain**: `tests/bench/helpers.fpr`'s `loop`, after `twice mix` is
inlined (two known calls to `mix`). Five let-bound values and two
parameters, 7 slot stores and 12 slot loads per iteration, plus two fuel
ticks (the entry and the inlined callee's):

```
    sd a0, -40(s0)          # n - 1
    ld a0, -24(s0)
    li a1, 511
    and a0, a0, a1
    ori a0, a0, 1
    sd a0, -72(s0)          # band n 255
    ld a0, -32(s0)
    li a1, 511
    and a0, a0, a1
    ori a0, a0, 1
    sd a0, -80(s0)          # band acc 255
    lui t0, %tprel_hi(fpr_posix_hart)   # the inlined twice's $fuel tick
    add t0, t0, tp, %tprel_add(fpr_posix_hart)
    ld t0, %tprel_lo(fpr_posix_hart)(t0)
    ld t1, 0(t0)
    addi t1, t1, -1
    sd t1, 0(t0)
    bgtz t1, .Lvfuel55
    call fpr_fuel_exhausted
.Lvfuel55:
    la a0, fpr_unit         # dead: the tick's Unit
    ld a0, -72(s0)
    ld a1, -80(s0)
    call fpr_fn_mix
    ld a1, -80(s0)
    call fpr_fn_mix
    sd a0, -64(s0)
    ld a0, -32(s0)
    ld a1, -64(s0)
    ... 7-instruction overflow guard, add ...
    sd a0, -48(s0)
    ld a0, -40(s0)
    ld a1, -48(s0)
    ld ra, -8(s0)           # tail call: teardown and j
    mv t0, s0
    ld s0, -16(s0)
    mv sp, t0
    tail fpr_fn_loop
```

Every let costs one store and one load per use; a parameter costs one
store at entry and one load per use (`n` and `acc` are each loaded three
times). `registerSlots` promoted nothing here: no slot reaches six textual
accesses. The two `band` results are stored, reloaded for the first `mix`,
and `-80` reloaded again for the second.

**A known call**: `tests/bench/fib.fpr`. `Workers.hs` turns `fib` into a
public entry plus the raw-Int worker `$worker.scalar.fib`, which is where
the 29.9 million calls of `fib 35` go. Its recursive arm:

```
.Lelse6:
    li a0, 1
    sd a0, -56(s0)          # the literal 1 staged through a slot
    ld a0, -24(s0)          # n
    ld a1, -56(s0)          # ... and reloaded
    sub t0, a0, a1
    slli t1, t0, 1          # 63-bit fit check (docs/2026-10-12-INT-OVERFLOW.md)
    srai t1, t1, 1
    bne t1, t0, .LscalarSlow0
    mv a0, t0
    j .LscalarDone1
.LscalarSlow0:              # retag, call the C primitive for its panic
    ...
    call fpr_prim_fn__x2d
    srai a0, a0, 1
.LscalarDone1:
    mv s1, a0               # staging slot 2, promoted to s1
    call fpr_fn__x24worker_x2escalar_x2efib
    sd a0, -32(s0)          # fib (n-1), parked across the second call
    li a0, 2
    sd a0, -64(s0)
    ld a0, -24(s0)
    ld a1, -64(s0)
    ... same shape ...
    call fpr_fn__x24worker_x2escalar_x2efib
    mv s1, a0
    ld a0, -32(s0)
    mv a1, s1
    add t0, a0, a1
    ...
```

Per non-direct argument: one store and one load at the call site; per
parameter: one store in the callee's prologue and one load per use. In
this function `registerSlots` gave `s1` to the *argument staging slot*,
which the worker's `stage` reuses for every primitive operand and so
accumulates the most textual accesses (`li a0, 2; mv s1, a0; ld a0,
-24(s0); mv a1, s1`: a constant in the register, the parameter in memory).
The parameter `n`, loaded three times, has four accesses and stays in its
slot. The staging of literals through slots is the worker emitter's (`stage`,
`:2755`, which every `$scalar.` operand goes through); `genT`'s
`directArg` already keeps a literal out of the slots.
The x64 lowering of the same lines: `movq $2, %rax; movq %rax, %rbx; movq
-24(%rbp), %rax; movq %rbx, %rsi; pushq %r11; movq $0, %r11; cmpq %rsi,
%rax; setl %r11b; movq %r11, %r10; popq %r11; testq %r10, %r10; je ...`.

**A constructor**: `tests/bench/strbuild.fpr`'s `pieces`, the `::` after
`"item{n}"` (the constructor stub was inlined, so its `$fuel` tick is in
the middle of the body):

```
    sd a0, -56(s0)          # the piece
    ... the inlined Cons stub's fuel tick (7 lines) ...
    la a0, fpr_unit         # dead
    ld a0, -56(s0)
    addi sp, sp, -16        # push field 0
    sd a0, 0(sp)
    ld a0, -32(s0)          # acc
    addi sp, sp, -16        # push field 1
    sd a0, 0(sp)
    li a0, 24
    call fpr_alloc
    li t0, 2
    sw t0, 0(a0)            # tid
    li t0, 1
    sw t0, 4(a0)            # variant
    ld t1, 0(sp)            # pop field 1
    addi sp, sp, 16
    sd t1, 16(a0)
    ld t1, 0(sp)            # pop field 0
    addi sp, sp, 16
    sd t1, 8(a0)
    sd a0, -48(s0)          # the cell, staged for the tail call
    ld a0, -40(s0)
    ld a1, -48(s0)
```

Per field: two stores, one load and two `sp` adjustments on top of the
field's own evaluation; the header is two `sw`. The whole function moves
21 slot and push words per element (9 stores, 12 loads), plus the frame's
own `ra`/`s0` save and restore, around three C calls (`str`, `strcat`,
`fpr_alloc`) that do the actual work. `pieces` is
shallow (no `call fpr_fn_`), so it has no stack check, and it ends in a
tail `j` to itself: every iteration opens and closes a frame.

**A case**: `count xs k = case xs of Nil -> k | _ :: r -> count r (k + 1)`
(the probe used in section 2):

```
    ld a0, -24(s0)          # xs
    andi t0, a0, 1          # an Int never matches a data tag
    bnez t0, .Lelse3
    lw t0, 0(a0)
    li t1, 2
    bne t0, t1, .Lelse3     # tid
    lw t0, 4(a0)
    li t1, 0
    bne t0, t1, .Lelse3     # variant: Nil
    ld a0, -32(s0)
    j .Lendif4
.Lelse3:
    ld a0, -24(s0)          # xs again
    ld a0, 16(a0)           # r
    sd a0, -40(s0)
    ld a0, -32(s0)          # k
    li a1, 3
    ... 7-instruction overflow guard, add ...
    sd a0, -56(s0)
    ld a0, -40(s0)
    ld a1, -56(s0)
    ... teardown, tail fpr_fn_count
```

A tag test is one slot load and two header loads (nine instructions,
though the type has two constructors and the arm is exhaustive); binding a
field is a slot load, a field load and a slot store; the recursive call
stages both arguments through slots it reloads two lines later.

The pattern across all four: the frame is the only place a value can
wait. Everything that is not the current `a0` is in memory, and the
peephole can only shorten a store/reload pair that sits inside one basic
block with no call between.

## 2. The measured ceiling

Method: `fpr build --keep` kept the a64mac assembly of `fib.fpr` and of a
probe `pieces.fpr` whose `pieces` is the source text of `strbuild.fpr`'s
(with `count` as the consumer, so the whole program is the allocation
loop). The hot function was replaced by hand with what a register
allocator would emit: the same evaluation order, the same inline guards
and slow paths, the same stack check and fuel ticks, values in `x19..x21`
instead of slots. The file was relinked with the `cc` line `Build.hs`
uses (the kept `.units` list, the cached runtime objects under
`~/.cache/fpr/rt`, `-ffixed-x27 -ffixed-x28 -DFPR_HART_X28`). Relinking the
unmodified kept file reproduces the stock time, which validates the
recipe (a later paired run under load average 12: `fpr build`'s binary
72.5 and 73.9 ms, the relinked copy 74.1 and 71.7 ms, the hand-allocated
one 62.4 and 52.8 ms). Each binary was run 15 times (11 for pieces) in two alternating
rounds; the fastest run is the score, as in `tools/bench.py`. Output is
byte-identical across variants.

The hand-allocated `fib` worker (the whole body; the stock version is 97
instructions of text, this one 72):

```
_fpr_fn__x24worker_x2escalar_x2efib:
    sub sp, sp, #48
    stur x30, [sp, #40]
    stur x29, [sp, #32]
    add x29, sp, #48
    stp x19, x20, [x29, #-32]      # the two callee-saved registers used
    mov x19, x0                    # n
    mov x9, x28
    ... stack check, fuel tick: unchanged ...
    mov x0, x19
    cmp x19, #2
    b.lt Lha_ret                   # n < 2: the result is n
    sub x9, x19, #1
    lsl x10, x9, #1
    asr x10, x10, #1
    cmp x10, x9
    b.ne Lha_slow0                 # the overflow slow path, as before
    mov x0, x9
    b Lha_done0
Lha_slow0:
    lsl x0, x19, #1
    orr x0, x0, #1
    mov x1, #3
    bl _fpr_prim_fn__x2d
    asr x0, x0, #1
Lha_done0:
    bl _fpr_fn__x24worker_x2escalar_x2efib
    mov x20, x0                    # fib (n-1), parked in a register
    sub x9, x19, #2
    ... same guard, same slow path ...
    bl _fpr_fn__x24worker_x2escalar_x2efib
    add x9, x20, x0
    ... fit check, slow path ...
Lha_ret:
    ldur x30, [x29, #-8]
    mov x9, x29
    ldp x19, x20, [x29, #-32]
    ldur x29, [x29, #-16]
    mov sp, x9
    ret
```

Frame traffic per call: stock 16 slot and save loads and stores; hand 8
words in 6 instructions (ra, fp, the paired save and restore). Instructions on the recursive path:
about 67 stock, 51 hand, of which 18 are the prologue (frame, stack check,
fuel tick) in both.

| Binary | What differs from stock | fib 35, best of 15 (two rounds) | Ratio |
|---|---|---:|---:|
| stock | `fpr build` at 3206b84 | 65.4 / 65.2 ms | 1.00 |
| A | registers instead of slots, everything else kept | 50.3 / 50.0 ms | **1.30x** |
| B | A without the stack check | 50.5 / 50.2 ms | 1.30x |
| C | B without the fuel tick | 49.1 / 49.1 ms | 1.33x |
| C, clang -O2 | `long fib(long)` with no checks at all | 19.2 ms | 3.4x |

So the allocator's ceiling on fib is 1.30x: 65 -> 50 ms, 2.2 -> 1.7 ns per
call. The stack check costs nothing measurable and the fuel tick about
2%: both are independent loads and a predicted branch, which the core
overlaps with the call chain; "fib is dominated by the prologue" is true
of the instruction count (18 of 51 after allocation) but not of the time.
The remaining 2.6x to C is the calling convention itself (a frame, two
saves, a `bl`/`ret` pair and four overflow guards per call, against
clang's leaf-optimized recursion), which no allocation pass touches.

`pieces` (3,000,000 elements, then `count`):

| Binary | What differs from stock | best of 11 (two rounds) |
|---|---|---:|
| stock | | 169.3 / 173.1 ms |
| A | registers instead of slots and pushes, frame per iteration kept | 170.2 / 171.7 ms |
| B | A as a loop: one frame, the tail self-call a back-edge, both ticks kept | 163.9 / 167.0 ms |
| C | B with the inlined stub's second tick dropped | 168.0 / 168.1 ms |

Within noise: at most 3%. The 23 slot words per element cost nothing
against `str`, `strcat` and `fpr_alloc` (about 55 ns per element in all).
For allocation-heavy code the allocator is not where the time is; this
bounds the expectation for `strbuild`, `pingpong` and the string-building
std paths, and says the ratchet's job there is "not slower", not "faster".

The number to design against: **1.3x on call-and-arithmetic code, nothing
on allocation-heavy code, with the hosted calling convention unchanged.**
`helpers`' `loop` (two known calls and five lets per iteration) was not
hand-edited; by the fib count it sits between the two.

## 3. The design

### 3.1 Input, output, and where it sits

The pass runs inside `compileFn` on the Core body `gen` is about to emit
(after `normIn`/`indexedMemory`, before `gen`), per function. It is a
linear scan over the **emission order** of the Core, not over the
assembly: the order `genT` walks the tree is deterministic (a let's
right-hand side before its body; a call's arguments left to right before
the call; a constructor's fields in order before the allocation; a
condition before its branches; `goThen`'s `rest` after the inner code), so
every binder and every staged temporary gets a definition point and use
points on one number line. A pre-walk numbers them; the scan assigns each
a location:

```haskell
data Loc = Reg String      -- a callee-saved IR register, s1..sN
         | Slot Int        -- a frame slot (today's storage)
type Env = M.Map String Loc
```

`gen`'s `env :: Map String Int` becomes `Env`; `ldSlot tgt "a0" k` at a
variable, `directArg`, `argLoad` and `stSlot "a0" nxt` at a let become
`loadVar`/`storeVar` on a `Loc` (`mv` for a register). Staged call
arguments and constructor fields are temporaries in the same scan (a
temporary that must survive a call is a `Reg` or a `Slot`; one that does
not is loaded straight into `a_i`). Nothing about *what* is evaluated or
*when* changes: the pass decides where values wait, and the emitted
expression sequence is the stock one. Program order stays device order by
construction.

Why linear scan is enough here: within a function, Core has no loops (every
loop is a tail call), so each binder's live range is one interval of the
number line, and greedy interval coloring is optimal for an interval graph.
No splitting, no second chance. `if` does not break this: the two branches
are numbered one after the other, a value used in one branch ends there
and its register is free in the other, which never runs after it; a value
used in both is live across both. Spilling, when more intervals are live
than registers, evicts the live interval with the fewest remaining uses.
Section 3.4 is the one place a cycle appears, and it keeps intervals.

### 3.2 Calls, allocation, traps and the fuel tick

Every point that emits a `call` clobbers `a0..a7` and `t0..t6` on all
three hosts and preserves the IR's `s` registers (C ABI on rv64 and a64;
on x64 `%rbx %r12..%r15` are preserved by the ABI and the XMM bank by the
translator). The scan marks these points and gives anything live across
one a `Reg` or a `Slot`; everything else may ride `a0` as today:

- **Known calls and C primitives**, including `fpr_applyN`: a call.
- **`fpr_alloc`** is a C call (`runtime.c:477`): `fpr_hart()`, the bucket
  take, the slab path behind it. It preserves the `s` registers and nothing
  else; whether a slab refill can park the actor does not matter, because
  the switch preserves the same set. So a constructor's fields evaluated
  before it are kept in `s` registers (or slots) across it and stored from
  there; the push/pop pairs go away.
- **The inline fast paths' slow branches** (`Guarded`, `ScalarChecked`,
  `GuardedCond`) *return* from a C call (`fpr_prim_fn_+` answers when the
  operands were merely too wide for the inline check; it panics only on a
  real overflow). Each guarded primitive is therefore a call point for the
  scan, exactly as the stock emission treats it (its arguments are staged).
- **Traps** (`fpr_panic`, `CErr`, `fpr_int_overflow_kernel`) do not return;
  nothing is live after them. Failure order is untouched because the
  evaluation order is.
- **The fuel tick** (`call fpr_fuel_exhausted`) and **the stack check**
  (`call fpr_stack_grow`) are calls, and the tick may switch actors; the
  switch saves the IR's callee-saved set (section 1.2), so a local in `s3`
  is still in `s3` when the actor resumes, as `registerSlots` already
  relies on. After a stack grow `sp` is in a new segment but `s0` and the
  slots are not: spill slots stay valid, registers are unaffected.
- **Inlined `$fuel` ticks** are calls at their position; the `la a0,
  fpr_unit` they leave behind is dropped (the `$tick` binder has no use).
- **Tail calls**: argument moves (`mv a_i, s_k`, slot loads, `li`) happen
  first, then the saved registers are restored, then `ra`/`s0`/`sp` and the
  `j`; moves go from `s` to `a` registers only, so there are no cycles. The
  stock `promote` hooks its restores textually onto the epilogue's `ld s0,
  -16(s0)` line; the pass emits them in `knownCallThen`'s `Tail` transfer
  and in `compileFn`'s epilogue instead.
- **Parameters** are intervals from entry; a parameter 7 or 8 in a register
  is `mv sN, a6` in the prologue, the form `X64.hs` already lowers from the
  TLS cells. Parameters 9+ stay in the spill cells until copied, as now.

### 3.3 Register budget per target, and the translators

The IR's usable callee-saved set is `s1..s9`: `s10`/`s11` have no a64
mapping (x28 is the hart register, x27 is paired with it by Apple clang,
see `Build.hs:172`). Cheap on every host: `s1..s5`. `s6..s9` are real
registers on rv64 and a64 but the XMM shadow bank on x64, where a use
costs 4 extra instructions and a function that uses them pays 14 around
every call; a spill slot (`ld`/`sd`, 1 instruction each) is cheaper than
the bank on x64. So the budget is a `Target` field, not a constant:

| Target | `Reg` budget | Beyond it |
|---|---|---|
| rv64 (Linux host, virt, qos-native) | `s1..s9` | spill slots |
| a64, a64mac, qa64 | `s1..s9` | spill slots |
| x64, qx64 | `s1..s5` | spill slots (never the XMM bank for locals) |

The budget is a fundamental of each host's ABI and the x28 convention, not
a tuning knob; it needs no [BOUNDS](2026-09-19-BOUNDS.md) entry beyond a
line saying so. Changes in the translators: **none required**. `A64.hs`
maps `s1..s9`; `X64.hs` maps `s1..s5` directly and already lowers `mv sN,
a6/a7`; `RV64.hs` passes `s` registers through. Two optional refinements
for later, not part of the plan: a paired `stp`/`ldp` save form in the IR
(2 instructions saved per pair on a64, nothing on the others), and letting
`X64.hs` use `%r12..%r15` for `t`-register scratch instead of push/pop when
a function leaves them unallocated.

### 3.4 Self tail calls as loops (the one cycle)

`pieces`, `count`, `loop`, `cat`: a tail call to the function itself
reopens the frame every iteration, so even with registers the saves and
restores of the used `s` registers are paid per iteration (section 2's
`pieces` A), and `registerSlots`' whole-function promotion is a loss on
tail-recursive loops with few other accesses. A tail self-call with the
same arity becomes a back-edge: a parallel move of the new arguments into
the parameters' locations (a `t0` temporary breaks a swap cycle), then `j
.Lloop`, where `.Lloop` is placed after the prologue's saves and the stack
check and *at* the fuel tick. The frame is constant, so the stack check is
right to run once; the tick runs once per iteration, which is what today's
entry tick did. Parameters are then live for the whole function (as
today), so the live ranges stay intervals and the scan is unchanged.
Mutual recursion and tail calls to other functions stay teardown-and-`j`.

Three places assume "all intra-function branches are forward" and need
the back-edge made explicit to them: `wcetAnnotate` (a grey back-edge is
UNBOUNDED unless the cycle passes a reset, which the tick in the loop
block is: the memoized visit stops at a block with a reset inside and
never follows the edge), `Peephole.deadStores` (a backward branch already
falls back to the function-wide rule, so it is correct and merely weaker),
and `Peephole.forward` (a label forgets all forwarded pairs, correct). The
x64 `raGuard` sees no new `sp` shape.

### 3.5 Moving the fuel tick, and the bound

Today a fuel unit is one supercombinator entry (`FUEL_QUANTUM 2000` entries
a slice, `actors.c:86`), and the per-function `# wcet:` line bounds the
generated instructions between two safepoints (`segmax`; `FPRC_WCET=1`
prints the table and program maximum). C calls do not reset the segment
and carry their own bound (G2). Two moves are on the table:

1. **To the back-edge** (section 3.4): the tick stays one per iteration,
   the loop body is the function body it was, so `segmax` is unchanged.
   This is a consequence of the loop form, not an optimization, and it
   costs nothing to bound.
2. **Off shallow leaves** (`clamp`, the stubs, the overflow-free helpers):
   a function with no `call fpr_fn_`, no `jalr` and no `j fpr_fn_` (a
   tail self-jump is a loop and keeps its tick) drops its entry tick, and
   its callers treat `call fpr_fn_leaf` as `segmax(leaf)` straight-line
   instructions instead of a reset, as `wcetAnnotate` already treats a C
   call. The bound for a function f becomes `segmax'(f) = max over paths
   of (own instructions + sum of segmax(g) for the tickless leaves g on
   the path)`, finite because a leaf has no cycle, computable from the
   same DAG walk given the callees' table, and printed by the same line. A
   leaf qualifies only when `segmax(g) <= L`, a leaf budget that is a
   scheduler tuning constant beside `FUEL_QUANTUM` and would be registered
   in BOUNDS as such. Inlined leaves then need no `$fuel` either, which
   removes the double tick in `pieces`. The measured value on the hosted
   targets is about 2% (fib: B against C; `pieces`: B against C), so this
   is **not in the staged plan** below; it is a separate decision for the
   small cores where a tick is a real fraction of a tiny function, and it
   is stated here so the bound is on record when that decision comes.

### 3.6 Retiring the peephole and `registerSlots`

`registerSlots` is subsumed: the pass chooses registers by liveness and
weighted use, including the staging temporaries it could only count. It
goes, and `FPR_NO_REGISTERS=1` (the differential flag `tests/check_registers.py`
drives, with its own unit-cache key) becomes "the slot path": the stock
emission, which stays as the fallback and as the profile selection of
section 4. The peephole stays: it is correct on the new output, still
removes the `sd a0, slot; ld a0, slot` pairs of spilled binders and of the
stock path, and its dead-store pass removes stores the scan left for
values whose uses all turned into `mv`. Its forwarding knows `mv` already.

### 3.7 Untagged `Int` locals (SUGGESTIONS item 5): a separate page

Placement (register or slot) and representation (tagged word or raw
integer) are orthogonal, and the repository already has the representation
side for the closed arithmetic case: `Workers.hs` makes the raw-Int worker
that fib's measurement ran on. What item 5 adds is raw `Int` *locals* in
functions Workers cannot take whole (mixed data and arithmetic), by
`Representation.hs`-driven `$scalar.unbox`/`$scalar.box` at boundaries
(calls to unknown functions, heap stores, sends) with the overflow traps
kept per operation. That is a Core-to-Core rewrite with its own
failure-order argument, and it layers on top of this pass: a raw local is
a value like any other to the scan, and `Loc` grows a representation bit
when the rewrite exists. It gets its own page; this one must only not
assume a value's representation, and does not. One honest expectation from
section 2: on fib, whose hot code is already raw, item 5 is worth nothing;
its value is on the mixed functions, and it should be measured there
first.

## 4. Out of scope, and why

- **The builtin profile (MMIO, drivers, `--arc`)** keeps the stack-machine
  emission. The selection is a `Target` flag, set in `Compile.hs` where
  `tgt` is assembled (`:906`): `tgtAlloc = not oBuiltin && tgtW == 8 &&
  tgtScalarFast && not envNoRegisters`. That is the base profile on every
  rv64 system (hosted posix, bare-metal virt, qos-native, the QOS Portable
  apps), and never `tgtArc` or `not tgtFuel` (builtin). Today's
  `registerSlots` runs on builtin code without `--arc` (`:640` gates on
  `tgtArc` only); the new pass does not, and whether that promotion stays
  there is the builtin owner's call, not this page's. The evaluation-order
  guarantee holds either way (3.1), but builtin code is the profile where
  "every value through the frame, nothing elided" is the stated and audited
  strategy (`Codegen.hs` header), and the differential checks for it
  (`tests/check_riscv_scalar.py` on QEMU) must keep a byte-identical
  reference.
- **RV32** (`--target=rv32`: ESP32, Tang Nano): a 4-byte word, 31-bit tags,
  boxed floats, its own differential flag (`tgtScalarFast` off by
  `FPR_NO_RV32_FAST`) and its own QEMU gate. The design generalizes (slots
  are `tgtW` bytes, the register names are the same), but the hosted stages
  must land and settle first; RV32 is a later stage with its own numbers.
- **Sol** runs on the bytecode VM (`fpr run` of a `profile sol` file); it
  has no native generator to allocate for.
- **The unboxed vector kernels and Vec specialization loops**
  (`compileUFn`/`genU`, `emitSpecs`) keep their fixed `s1..s9` roles; they
  are not supercombinators the scan sees. `genU`'s literal staging
  (section 1.3) is a one-line `directArg` fix that can ride stage 1 or be
  left.
- **Caller-saved temporaries** for short ranges (a let used once two lines
  later, in `t`/`a` registers instead of `a0` round trips), **`stp`/`ldp`
  save pairs**, and the **calling convention** (leaf frames, no frame
  pointer) are each a later page; section 2 shows the convention is where
  the remaining 2.6x to C lives.

## 5. The staged plan

Every stage keeps the same gates, run from the main checkout and in the
branch worktree: `tests/check_base.py` (which runs `check_registers.py`,
`check_workers.py`, `check_specialization.py`, `check_x64_vectors.py`,
`check_rv64_linux.py` among the rest), `tests/check_riscv_scalar.py` (QEMU
rv32 and rv64, the bare-metal paths), `tools/bench.py` against
`bench/baseline.json` (every `.expected` byte-identical; nothing more than
10% slower on the recording host; a stage that claims a speedup records a
new baseline in the same commit), and `FPRC_WCET=1` (the program maximum
must not grow). Each stage bumps `codegenRev` (the unit cache keys on it)
and so invalidates QOS's pinned units: QOS is rebuilt and its own checks
run before the stage is called done, or the page says it was not.

**Stage 1: liveness-weighted promotion, same storage model.** Replace
`registerSlots`' textual count with a Core live-interval pass that chooses
up to five binders or parameters for whole-function `s1..s5`, weighting
uses that cross a call point and never choosing a literal's staging slot;
the emission and frame are otherwise the stock ones (`promote`'s rewrite
stays). Expected: fib's worker gets `n` in a register instead of the
constant `2`; `loop`'s `n`/`acc`. Risk: low. The storage model is today's,
so the only new failure is a worse choice, which the ratchet shows; the
differential gate is `check_registers.py` as it stands. This is the stage
small enough to land alone: one new function in `Codegen.hs` and a changed
`regs` line in `compileFn`, no translator change, measurable on `fib` and
`helpers`.

**Stage 2: the allocator for binders and parameters.** `Env` of `Loc`,
interval reuse of `s1..sN` under the per-target budget, spill slots in
place of today's slots, staged arguments as scan temporaries (`mv a_i,
s_k` instead of store/reload), the restores emitted explicitly in the
tail transfer and epilogue, `nslots` from the spill count. Target: fib
toward the 50 ms ceiling of section 2 (any result above 1.2x is the pass
working; below is a bug to find, not a tuning). Risk: medium, and it is
all correctness: an interval ended too early is a wrong value (caught by
the differential suites, which is why `FPR_NO_REGISTERS` keeps the stock
path), a missed call point clobbers a register (the guarded primitives'
slow paths and the inlined `$fuel` are the two easy ones to miss), the x64
a6/a7 cells, deep frames beyond the 12-bit displacement, arities over 8.
`check_registers.py` grows a case per shape.

**Stage 3: constructor fields and generic-apply arguments through the
scan.** Fields that are locals or literals are stored into the object
straight from their location after `fpr_alloc`; fields that need
evaluation are temporaries; `push`/`popTo` remain only for the generic
`fpr_applyN` spine, whose argument vector is a memory contract with the
runtime. Expected: nothing measurable (section 2's `pieces` A), fewer
instructions, no regressions. Risk: low to medium: the field evaluation
order and `goThen`'s `rest` threading (the quadratic-copy history in its
comments) must be kept exactly.

**Stage 4: self tail calls as loops.** Section 3.4, with the `# wcet:`
walk taught the back-edge-with-tick shape and `Peephole.deadStores` left on
its fallback rule for such functions. Expected: `pieces`-shaped loops stop
paying a frame per iteration (3% in section 2; more where the loop body is
cheap, such as `count`, `cat`, `byteloop`), pingpong/xpingpong untouched.
Risk: medium: the "all loops are tail calls" invariant is relied on in
`wcetAnnotate`, `Peephole`, `Inline.hs`'s safepoint reasoning and the
frame-growth argument in BOUNDS; each is checked by name, and the WCET
table is the gate that says the bound survived.

Not staged: RV32 (section 4), tickless leaves (3.5), untagged locals
(3.7), caller-saved temporaries and the calling convention. Each is a
page of its own, written against the numbers this one leaves behind.

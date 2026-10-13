# Int overflow traps

Date: 2026-10-12. Kind: decision and implementation record. Answers
work item 1 of [2026-10-11-EDGE-CASES.md](2026-10-11-EDGE-CASES.md):
`4611686018427387903 + 1` used to answer `-4611686018427387904`,
`a * a` answered `1`, and nothing in the language said so.

## The decision

`Int` is the tagged 63-bit integer (31 on a 32-bit word). Its `+`, `-`,
`*` and `/` now TRAP when the mathematical result does not fit:

```
*** FPRISC PANIC [actor 0]: Int overflow: 4611686018427387903 + 1 does not fit an Int (-4611686018427387904..4611686018427387903); I64 is the type that wraps ***
```

Nothing wraps silently. The program that wants wrapping says so by
using `I64` ([2026-10-05-I64.md](2026-10-05-I64.md)), whose contract is
to wrap. The bit operations (`band`, `bor`, `bxor`, `BITSHIFTL`,
`BITSHIFTR`) are not arithmetic: they act on the 63-bit word and a shift
past it is a named refusal already (`tests/base/bitrange.fpr`).

Two neighbours of the same shape are refused by name too: `chr n` with
`n` outside 0..255 (it makes one byte; a code point wants
`String.fromCodes`), and `Sys.exit n` with `n` outside 0..255 (a process
status is one byte; 300 used to leave as 44).

## Where the check lives

The arithmetic is generated in four places, and each checks:

1. **The C primitives** (`runtime/runtime.c`, `fpr_prim_fn_+` and the
   others): `__builtin_add_overflow` on the untagged values, then the
   63-bit fit (`(n << 1) >> 1 == n`). `/` has one overflow, the most
   negative Int divided by -1. The panic names both operands. Every other
   path comes here for the panic, so the message is one.
2. **The inline fast paths** (`Codegen.inlineTable`, the 64-bit
   targets): `+` computes `(a0 - 1) + a1`, which is exactly `2(x+y)+1`,
   so the word's signed overflow IS the Int's; `-` likewise on `a0 - a1`
   = `2(x-y)`; on overflow the guard branches to the C primitive. `*`
   stays inline only when both operands fit 31 bits (the product then
   fits 61); wider operands take the exact check in C. `/` sends a zero
   or -1 divisor to C. The checks use `xor`/`and`/`srai`/`bne`, which
   every native lowering (A64, X64) already translates.
3. **The unboxed vector kernels** (`genU`, the column loops of `Vec.map`,
   `Vec.filter`, `Vec.fold`): the operands fit 63 bits, so `+` and `-`
   cannot wrap the word and the result's fit is the whole test; `*`
   verifies its product through a division unless both operands fit 31
   bits. The trap is `fpr_panic` from the kernel's own frame: "Int
   overflow in a vector kernel", without the operands.
4. **The NEON lanes** (A64): an Int body is vectorized only when it is
   ONE `+` or `-` over the element and literals; the two stored lanes are
   then checked for the 63-bit fit, which is exact for one operation on
   fitting operands. A longer Int body could wrap an intermediate and
   land back in range, so it runs the scalar kernel, which checks every
   step. The RVV map kernel declines Int bodies for the same reason
   (there is no lane check yet); F64 kernels are untouched, IEEE does not
   trap.

A raw library unit (`--arc --raw --lib`, the virt PLIC, CLINT and
network-policy units) carries the same inline guards, and its link had
no adapters for them: `machine/virt/rawunit.c` now defines
`$arc.add`/`sub`/`mul`/`div` as the core primitives (they allocate
nothing). Before this the raw units' `/` had the same gap, unseen
because no raw unit divided.

The prelude's lenient `parseInt` accumulated with `*` and answered
-1 for a 19-digit string; it now stops at the digit that would not fit
(`922337203685477580` for that string). `String.toInt` and `wireInt`
are the checked parses.

The parses need the Int's bounds, and a 63-bit literal is refused on a
32-bit target: `intMax Unit` and `intMin Unit` are primitives now (the
runtime, the Sol VM), and `String.toInt`, `wireInt`, `parseInt` and the
terminal decoder use them.

## Fusion

[2026-10-03-FUSION-EFFECT-ORDER.md](2026-10-03-FUSION-EFFECT-ORDER.md)
fuses two maps only when neither element function can be observed
running, failure included. Int `+ - *` can now fail, so on this day they
left the fusion-safe set as `/` did and every Int pair ran as two passes.
On 2026-10-13 that was relaxed: a pair whose only possible failure is an
Int overflow fuses, and the fused kernel may raise that overflow on an
earlier element or in the other function than the two passes would. The
reasoning, the evidence and the better answer still wanted are in the
fusion page's 2026-10-13 section. `tests/base/vecfuse_effects.fpr` shows
an F64 pair and an Int pair fusing beside the declined printing pair.

## Cost

A scalar `+` is ten instructions inline where it was two; a `*` of small
operands eight where it was five. No measurement of a real program was
made for this record; the kernels keep their loops.

## Evidence

`tests/base/intovf.fpr` in `check_base.py`: `+ - * /` at both ends, the
negation of the most negative Int, a NEON kernel, a two-operation kernel,
a fold, `chr 256`, `Sys.exit 300`; and the edges that are fine.
`tests/base/vecsimd_int.fpr` still emits `add v.2d` with the lane check
after it. The edge battery's `int_edge` probe now panics on its first
line instead of printing four wrapped numbers.

## Open

- The RVV Int kernels (a lane check, or a vectorized check).
- `I64.toInt` already refuses what does not fit; there is no checked
  "wrapping Int" operation beside `I64`, and none is planned.

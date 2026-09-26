# The native JIT tier (hand-rolled, x86-64 and A64, no LLVM)

Sol's HostedBytecode profile has three execution tiers for the recursion
schemes: the interpreter, the native JIT, and the GPU (f64 `vecmap` only).
Every tier is bit-identical to the interpreter; a tier that cannot honour
that DECLINES and the next one runs.  This page is the native tier.

    typed Core --JitCore--> typed closure --KIR--> kernel IR
               --AsmX64 | AsmA64--> bytes --hj_alloc--> callable

| module | job |
| --- | --- |
| `compiler/Sol/JitCore.hs` | the pure arithmetic fragment (`jitOK`, `jitOKVec`), closure gather, join-point saturation, and the per-callsite type inference (JI exact int, JD inexact f64, JW ambiguous, JB bottom). Unchanged from the LLVM tier it replaced. |
| `compiler/Sol/KIR.hs` | the kernel IR and the type-directed lowering from Core (the twin of the interpreter's `arith`); the list / vec / vecmapr drivers written in the same IR |
| `compiler/Sol/AsmX64.hs` | SysV x86-64 assembler for the IR (SSE2 scalar f64, SSE4.1 `roundsd`) |
| `compiler/Sol/AsmA64.hs` | AAPCS64 assembler for the IR |
| `compiler/Sol/HandJIT.hs` | orchestration: `compileScheme` (list map / filter / foldl), `compileVecScheme` (vecmap / vecfilter / vecfold), `compileVecMapR` (record-returning map, native SoA construction), the compile cache, the FFI runners, and the cross-check dumps |
| `compiler/cbits/handjit.c` | `hj_alloc` (mmap RW, copy, mprotect RX) and the SSE4.1 probe |

## What gets compiled

Exactly what the LLVM tier compiled: a scheme whose element function is
a top-level supercombinator in the pure arithmetic fragment (ints,
floats, `+ - * /`, comparisons, `if`, `let`, `Num.div/sqrt/floor/round`,
saturated calls to other such functions, recursion allowed), with
captured scalars as typed extras and SoA columns as typed loads.  Lists
must be all-Int or all-Numeric (a mixed list bails except for folds);
a Vec layout with a boxed column bails when the kernel touches it.
`SOL_JIT_DEBUG=1` prints every decline with its reason; `SOL_JIT=0`
turns the tier off; `SOL_HJIT_DUMP=1` prints the IR of every unit.

## The IR

A stack machine over 64-bit words.  A word is an i64 or the bits of an
f64; the op that consumes it decides.  This is the whole reason both
backends are small: the machine stack is the operand stack, arguments
are pushed words, and a float op is "two words into FP registers,
operate, result back into a word".  Not the fastest shape, but one
whose correctness is visible per instruction on both ISAs, and still
1.5-2x the interpreter on the lattice programs.

    PushImm w | Local i | SetLocal i | LoadIx | StoreIx
    Bin AddI|SubI|MulI|DivI|AddD|SubD|MulD|DivD | Cmp TI|TD cc
    IToD | DToI | SqrtD | FloorD | RintD
    Jz l | Jmp l | Lbl l | Call l n | Ret | FuelTick

Functions are EXTERN (the driver the VM calls: register args spilled
to frame slots, param 0 is always the fuel cell pointer, parked in a
callee-saved register for the whole call tree) or INTERNAL (compiled
Sol variants: arguments are the top `n` stack words, result comes back
on the stack).  Fuel is reified exactly as before: every internal
function decrements the cell at entry; the VM reconciles on return.

## The driver ABI (unchanged, so the VM runners did not move)

    list map/filter  i64 drv(fuel*, in*, n, out*)        returns n / kept count
    list foldl       i64 drv(fuel*, in*, n, acc0)        returns acc (f64 as bits)
    vec  map/filter  i64 drv(fuel*, extras*, cols**, n, out*)   filter emits row indices
    vec  fold        i64 drv(fuel*, extras*, cols**, n, acc0)
    vecmapr          i64 drv(fuel*, extras*, cols**, n, outs**)  one column per field

## Semantics pinned to the interpreter

* int `/` is quot (`idiv` / `sdiv`); f64 `/` is IEEE division.
* exact ints promote to f64 on contact (`cvtsi2sd` / `scvtf`).
* `Num.floor` is `roundsd 9` / `frintm`; `Num.round` is `roundsd 8` /
  `frintn` (nearest, ties to even = Haskell `round`); both then `fptosi`.
* f64 compares are ordered: every relation and `==` are false on NaN,
  `!=` is true -- Haskell's `Double` instance.
* integer division by zero cannot panic from native code, so the
  kernel POISONS the fuel cell (`fuelPoison`, -2^62) and yields 0; the
  VM turns the poisoned cell into the interpreter's
  `SOL PANIC: division by zero` on return.  (The LLVM tier's `sdiv`
  by zero was undefined behaviour.)
* an `error "literal"` inside a kernel (a guard's refusal, `^`'s
  exponent check) is admitted by the fragment and compiles to a TRAP:
  a second, deeper poison (`fuelTrap`); the VM panics on return naming
  the native kernel (rerun with `SOL_JIT=0` for the message).  Before
  this, one `error` demoted the whole scheme to the interpreter.
* `%` and `^` are the prelude's `Int.mod` / `Int.pow`, ordinary calls
  in the fragment, so operator-heavy element functions stay native.

## Proving the ISA you are not running on

`SOL_HJIT_XCHECK=<dir>` makes every install also assemble the unit for
the OTHER ISA and every native call dump a case file (kind, n, extras,
the columns, acc0, and the host's outputs).  `tools/hjrun.c` maps a blob
executable and replays a case through the driver ABI; built for
aarch64 and run under `qemu-aarch64` it executes the A64 blob on the
same inputs and compares word for word.  `tools/sol-hjit-a64-check.sh`
drives it over dispatch, handint, mlpipe and a mixed program (list and
vec schemes, i64 and f64, guards, floor/round, extras, SoA records,
vecmapr, division by zero): several hundred cases, all bit-identical.
It is a check-all leg and skips itself when `aarch64-linux-gnu-gcc` or
`qemu-aarch64` are absent.

What that proof does NOT cover: an A64 host running the whole `fpr`
(GHC's FFI entry into the blob on real Apple/ARM silicon).  `hj_alloc`
does what the harness does -- `mmap` RW, copy, `mprotect` RX, then
`__builtin___clear_cache` for the split I/D caches -- so the first
native A64 run should be a build-and-run, not a port.

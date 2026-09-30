# Native performance: the first ratchet

Date: 2026-09-30. Kind: implementation record for
[SUGGESTIONS section 1](2026-09-30-SUGGESTIONS.md#1-native-performance). Of
the order of work in 1.7, this covers item 1 (the benchmark set), item 2's
peephole and item 3 (primitive fast paths), plus the builtin path's inline
operators and conditions for the base profile. The numbered steps below are
the order in which this work was done.

## The ratchet

`tools/bench.py` builds each `tests/bench/*.fpr` once with `fpr build`, runs
the executable five times, and scores the median wall time. A run's output
must equal `tests/bench/<name>.expected`: a code-generation change that is
faster because it computes something else is a failure. The command exits 1
when a benchmark is more than 10% slower than `bench/baseline.json`. The
baseline records the host it was measured on, and a comparison on another
host is reported but not enforced. `--record` moves the baseline.

| Benchmark | What it stresses |
|---|---|
| `fib` | `fib 35`: calls, tagged Int arithmetic, comparisons |
| `byteloop` | 50 passes over 800 KB: `charAt`, `strlen`, compare, add per byte |
| `sha` | SHA-256 of 1 MiB written in FP-RISC (`std/digest`) |
| `strbuild` | a 1,000,000-piece `strJoin` and 20,000 `strcat`s |
| `nbody` | 10,000,000 F64 Euler steps |
| `pingpong` | 1,000,000 actor round trips |

## Results (Apple M4, macOS, median of 5)

| Benchmark | Before | After | Speedup |
|---|---:|---:|---:|
| sha | 559.7 ms | 153.8 ms | 3.64x |
| byteloop | 318.3 ms | 103.2 ms | 3.08x |
| fib | 104.1 ms | 54.9 ms | 1.90x |
| nbody | 519.6 ms | 443.3 ms | 1.17x |
| pingpong | 180.6 ms | 155.4 ms | 1.16x |
| strbuild | 112.6 ms | 104.9 ms | 1.07x |

All outputs are identical to the baseline. SHA-256 in FP-RISC went from about
1.9 MB/s to about 6.8 MB/s.

## What changed, and what each step gave

What we found first: base code called `+` and `>` as C functions. It sent
`charAt` and `strlen` through the generic `fpr_applyN` spine, and built a
heap `True`/`False` for every comparison, which the branch then re-tested.
The builtin `--arc` path already avoided all of this, behind `tgtArc`
guards.

1. **Inline Int operators, jumping conditions, direct arguments**
   (codegenRev 11). Base `+ - * / < > <= >= == !=` use the builtin path's
   tagged-word expansions. These are exact against `runtime.c`: the C prims
   untag unconditionally, `/` keeps its C path for a zero divisor, and
   `==`/`!=` stay deep in C unless both operands are Ints. `if`/`case`
   conditions compile to branches, and locals load straight from their
   slots. fib 1.72x, sha 1.51x, byteloop 1.45x.
2. **Normalized bodies** (`normIn`, rev 12). A let-bound condition fuses
   into its branch. A regression the full suite found: `normArc`
   substituted *any* variable alias, and in base code a zero-arity global
   is evaluated where it is named (a CAF that prints). Substitution now
   applies only to locals (rev 15; `tests/base/cafalias.fpr`).
3. **The peephole on the shared IR** (rev 13). It now runs before the
   a64/x64 translators. The gain was small on this machine, because the M4
   forwards stores to loads cheaply.
4. **Direct primitive calls** (rev 14). A saturated call to a primitive of
   known arity is `call fpr_g_<name>_call<n>`, an entry `FPR_FN` now
   defines, instead of staging the spine for `fpr_applyN`. Arities come
   from the compiler's builtin schemes and every bare (foreign) signature
   (`Target.tgtHal`). The arity is part of the symbol, so if the compiler
   and the C side disagree, the program fails to link instead of passing
   the wrong number of arguments. The clause comes after the `Vec`
   specializations, so those keep their loops. This was the largest step:
   sha 3.66x, byteloop 2.96x.
5. **Inline primitive fast paths** (rev 16): `charAt`, `strlen`, `band`,
   `bor`, `bxor`, `BITSHIFTL`, `BITSHIFTR`, each exact against the C, with
   the direct entry as the slow path. The slow path still produces the
   named panic. A64 and X64 learned `lbu`, `or` and `srl`. The gain is small
   once the call is already direct. `tests/base/inlineprims.fpr` compares
   every operation with the same primitive called through the C path.

The macOS fuel TLS call (1.6) was already handled:
`fpr build` lowers hosted A64 through `deTlsQosAppA64`, so the hart is in
`x28`. The TLS sequence appears only when `fprc` is invoked directly without
the base flags.

## What is left

- **The base-profile inliner** (1.7 item 2). `inlineSmall` still runs only after
  ARC lowering. `fib` is now mostly the prologue: the stack check and the
  fuel tick on every entry.
- **F64.** `nbody` barely moved. Every F64 operation is still a C prim
  (`fpr_prim_fn_F64_x2e...`), and floats travel as raw bits in the integer
  ABI. Inline `fadd.d`/`fmul.d` over `fmv.d.x` would be the next step there.
- **Allocation-bound code.** `strbuild` and `pingpong` are bound by the
  allocator and the runtime (message copy, channel rings), not by generated
  code.
- **1.7 items 4 and 5** (locals in callee-saved registers, untagged Int
  locals) are unchanged and remain the larger project.

## Found on the way, not fixed here

`./qos.py test` fails its `liveview` leg on `main`. `mods/liveview.fpr` is
not in `qos/core/trusted-modules.txt`, and since the 2026-09-30 import-trust
change, its unsafe helpers are refused. Adding the entry or marking the
module is a trust-policy decision, so it is left open.

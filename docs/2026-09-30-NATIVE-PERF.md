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

## 2026-10-01: the base-profile inliner, and a frame-size bug it exposed

**The inliner.** `Inline.inlineWith` now runs on every base unit before the
generator. It is the builtin path's `inlineSmall`: small non-recursive
functions at saturated sites, arguments let-bound in call order, fresh
binders, three rounds. There are three base-specific additions:

- **Function-valued arguments are substituted.** If an argument names a
  function (a global of this unit with parameters, another unit's function,
  or a primitive), it replaces the parameter instead of being let-bound. So
  `twice band x y` inlines to direct, and here inline, `band` operations
  instead of two generic applies through a local. A zero-arity global is
  never substituted, because it runs where it is named.
- **Alias propagation.** Clause desugaring rebinds each parameter under its
  source name (`f = a1`), so a substituted parameter reappears as an alias
  of a global function. Each round propagates such aliases when nothing in
  scope shadows the name.
- **Aliases are free in the size measure.** `x = y` costs nothing after
  normalization. Counting it priced three-line helpers out of the 24-node
  limit, because base clause desugaring adds one per parameter. Raising the
  limit to 64 inlined more and gained nothing, so it stays at 24.

- **Safepoint-preserving.** Every inlined body starts with the fuel tick
  its callee's entry had (`$fuel`, a Core primitive the generator emits as
  the standard tick). A call is a preemption point. Without the tick, the
  kernel's WCET ratchet measured 408 IR instructions between safepoints,
  against a ceiling of 200. With it, the longest path is 116, exactly as
  without inlining. What goes is the frame, the argument staging and the
  stack check. The cost is a few instructions, which does not show in any
  benchmark.

`--no-inline` or `FPR_NO_INLINE=1` turns it off, and the unit-cache tag
records the choice. `FPR_DUMP_CORE=name` now also prints base Core.
`tests/base/inlining.fpr` is built both ways and the outputs must match. It
covers argument order with effects, a CAF argument, function-valued
parameters, shadowing, mutual recursion, a primitive and a lambda.

**The bug it exposed (fixed here, and present in the 2026-09-30 merge).**
`slotsNeeded` sizes a frame from the argument slots of known calls. Direct
primitive calls and their inline expansions stage arguments into slots too,
but were not counted. A function whose only staged arguments belonged to
primitives therefore got a frame too small. The slots sat below `sp`, where
the nested C calls' frames overwrote them. `tests/base/slotprims.fpr` panics
(`strJoin: not a List of String`) without the fix, with or without inlining.
Inlining `std/digest`'s `lengthBytes` into a list literal made the
`examples/logbook.fpr` WebSocket handshake hit it. The comment in
`slotsNeeded` already named this class from an earlier incident (the
cross-unit case). codegenRev 18.

**A kernel leak it exposed (fixed in QOS).** The native launcher waited for
a key by spinning on `svcPollKey`/`svcClock`. Each poll allocated a little
(the route's substring, the boxed reply), and the launcher's pool is never
reset, so an idle launcher grew without bound. It exhausted the heap in
under 40 s with or without inlining, so the faster code only made it fail
inside check-all's 8-second launch window. The bisect looked
layout-dependent because it was really time-dependent. The fix is in
`qos/programs/system.fpr` (`lWait`/`lPoll`): the wait runs inside
`Sys.arena`, and it parks 1 ms between empty polls. See
`qos/docs/2026-10-01-LAUNCHER-IDLE.md`.

**Benchmarks** (min of 7, macm4, against the baseline recorded with
inlining off): helpers 1.60x, sha 1.05x. fib, byteloop, nbody, pingpong and
strbuild are within noise: their hot loops are self-recursive or already
primitives. `tests/bench/helpers.fpr` was added for the shape the inliner is
for: small helpers in a hot loop, and a higher-order helper given a known
function.

`tools/bench.py` now scores the *fastest* of 7 runs. Desktop background load
(audio, other apps) only ever adds time, and it moved pingpong's median by
50%.

**Not caused by this work, still open.** About 1 in 100 runs of a
`Task.map Digest.sha256` stress program (and once `tests/std/apps.fpr`)
hangs. The caller stays in `receiveRes` while every worker has exited. It
happens with inlining off too, and it survives the frame fix. It looks like
a lost wake-up in the actor runtime and is being investigated separately.

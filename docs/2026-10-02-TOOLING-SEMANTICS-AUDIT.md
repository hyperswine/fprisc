# Tooling and semantics against the intended language, second pass

Date: 2026-10-02. Kind: review/status report with live probes.
Scope: native FP-RISC and Sol at revision `edfbaac` (main). No compiler or
runtime changes were made for this audit. The first pass is
[2026-09-29-TOOLING-SEMANTICS-AUDIT.md](2026-09-29-TOOLING-SEMANTICS-AUDIT.md);
this document re-checks every row of that matrix against the current tree,
records what the failure-honesty and typed-vector batches fixed, and adds two
findings the first pass missed.

## The intended contract (unchanged)

Immutable hash-addressed modules, published with `fpr commit`, imported as
`use "name#hash"`. Every value is statically typed: annotated, inferred, or a
compile error. An extended Hindley-Milner core with linear types and lightweight
refinements. Unproved recursion needs `unsafe`; a verified `measure` removes
the need. Time and memory bounds are part of signatures, compose symbolically,
and are discharged against a versioned target such as
`<FPRISC.v1, QOS.v2, Hardware.v2>`. Tabling, TCO, built-in recursion schemes
with known bounds, JIT and GPU for the bytecode target. MVU as the default
program shape.

## Status matrix

| Area | 2026-09-29 | 2026-10-02 | Change |
|---|---|---|---|
| Module pins, commit, store fallback | Implemented | Implemented; pinned import still builds after the working file is deleted | none |
| Commit certifies typing | No: ill-typed module committed | **Yes**: `commit` of `f x = 1 + "wrong".` fails with the type error, exit 1 | fixed |
| Commit compatibility | Written signatures only | Unchanged: `extra x = x + 1.` to `extra x = "text".` is still a "signature-compatible" patch (v1.1 to v1.2) | open |
| Hash | FNV-1a-64 over printed AST | Unchanged | open |
| Sol module identity | Local AST pin, no store fallback | Unchanged | open |
| HM inference | Real | Real: `1 + "x"`, unbound names and an over-general `a -> a` are refused | none |
| Vector element typing | Unchecked | **Checked**: an `Int` pushed and read as `String` is a type error before codegen | fixed |
| Actor and module-lookup typing | `Int` handles, free message type, `Mod.fn : String -> String -> a` | Unchanged (`Infer.hs:540-686`) | open |
| Sol `# sol:notypes` | Reaches runtime panic | Unchanged: `1 + "x"` panics at run time with the pragma | open |
| **Malformed signature** | not examined | **Silently dropped** in both profiles (new finding, below) | new |
| Linear checking | Both profiles | Both profiles refuse a double `Vec.free` | none |
| Refinements, native | Static discharge or runtime check | Unchanged; `positive (-1)` is a named precondition panic | none |
| Refinements, Sol | **Not applied**: printed `-1` | **Applied**: same panic as native, exit 1 | fixed |
| Result refinements | `post_f` convention in stdcheck only | Unchanged; `T | pred` on a result type parses as a dropped signature | open |
| Measures | Self-recursion only | Unchanged: mutual measure is refused with the "self-recursion only" message | open |
| Imported unsafe trust | Imported unsafe accepted from unmarked `main` | **Taints `main`**: refused unless `main : unsafe ...` | fixed |
| `--stdcheck` exit status | 0 on failure | **1 on failure** | fixed |
| stdcheck vs Safety termination | not compared | **Disagree** on `measure (lim - i)` (below) | new |
| `time f` / `mem f` in signatures, target triple | Absent | Absent | open |
| Tabling | Sol default-on, arithmetic fragment | Unchanged: `fib 27` 25 hits / 28 misses, 0.04 s vs 0.86 s untabled; nothing native | none |
| TCO native | Known saturated tail calls jump | Confirmed: 50M-iteration measured loop runs in 0.13 s | none |
| TCO Sol | No tail opcode | **Confirmed absent by measurement**: memory grows linearly with depth (below) | open |
| JIT | AArch64/x86-64 kernels for list and Vector schemes | Confirmed: `vecmap` and `vecfold` kernels compiled for a 1000-element `Vector Int`, result equals the interpreter's | none |
| GPU | EGL/OpenGL compute; macOS stub | Unchanged: `SOL_GPU=1` on this Mac produces no GPU tier | none |
| MVU | Library convention | Unchanged: `App`/`MApp` are untyped-field constructors, `run` is `unsafe`, `main` is the entry | open |

Test suites: `tests/check_cases.py` passes (clauses, signatures, operators,
stdcheck exit codes).

## New finding 1: a signature the parser cannot read is silently discarded

`signature` in [`FPRISC.hs`](../compiler/FPRISC.hs) (line 1133) is

```haskell
try (fullSig n) <|> (skipTillDot >> pure TSkip)
```

If the full signature grammar fails anywhere, the parser skips to the next
terminator and emits `TSkip`. The function is then treated as unannotated and
inferred from its body. No diagnostic is printed. Three probes, each with a
body returning a `String` under a signature promising `Int`:

| Program | Native `fpr build` | Sol `fpr sol` |
|---|---|---|
| `f : Int -> Int \| junk .` | builds, prints `not an int` | prints `not an int` |
| `f : Int -> -> Int .` | builds, prints `not an int` | not probed |
| `f : (a : Int) -> Int \| time f == omega * a .` | builds, prints `1` | not probed |

This directly breaks the "annotated, inferred, or compile error" rule: a typo
in a signature does not produce an error, it removes the signature. It also
means the proposed resource-bound syntax looks accepted when it is not. The
same mechanism would swallow any future signature extension that an older
compiler does not understand, which is the wrong failure mode for a
hash-pinned module system.

Fix: a signature header `name :` that does not parse as a full signature must
be a parse error. If `TSkip` exists for a legacy form, that form should be
named and matched explicitly, not reached by backtracking. Add refused cases
for the three probes above to `tests/check_cases.py`.

## New finding 2: Sol has no tail calls, and a measured loop proves it

The same program, a `measure n` countdown accumulating a sum, in both profiles:

| Profile | Iterations | Wall time | Peak RSS |
|---|---|---|---|
| native (`fpr build`) | 50,000,000 | 0.13 s | not measured, completed |
| Sol (`fpr sol`) | 1,000,000 | 3.9 s | 1.87 GB |
| Sol | 3,000,000 | 11.6 s | 5.46 GB |
| Sol | 30,000,000 | did not finish in 300 s | killed |

Memory grows about 1.8 GB per million iterations. The bytecode
([`Sol/Bytecode.hs`](../compiler/Sol/Bytecode.hs) line 52) has `Call` and
`Ret` but no tail-call instruction or frame reuse, which the first audit noted
from source; the measurement confirms the consequence. A function the compiler
has proven to terminate in `measure(entry)` steps therefore has O(n) memory on
the VM and O(1) natively. Any WCET or memory bound derived for a tail-recursive
function is profile-dependent until this is closed.

Fix: a `TailCall` opcode (or `Call` with a tail flag) that reuses the frame for
known saturated self and mutual calls, mirroring native `knownCall`. Acceptance:
the 30M-iteration probe completes in bounded memory on the VM.

## The two termination checkers disagree

`fpr build` accepts `sumTo : Int -> (i : Int | measure (lim - i)) -> Int -> Int`
(the count-up form documented in `tests/measure.fpr`). `fpr stdcheck` on the
same file fails:

```
error[sumTo]: cannot certify termination: no parameter with a finite lower-bound
precondition decreases syntactically (p - k, k>=1) at every self-call
```

[`Safety.hs`](../compiler/Safety.hs) understands expression measures with a
floor derived from the case guard; [`StdCheck.hs`](../compiler/StdCheck.hs)
only understands a parameter decreasing by a constant. A program can be
"safe" to the main compile and "unproved" to the cost tool. Since the cost tool
is the only place where symbolic work bounds exist, measured loops that the
language sanctions get no cost equation. One measure language, consumed by
both, is the prerequisite for a WCET that reaches signatures.

## Modules, re-probed

- `Dep = use "dep".` prints the pin and runs; `Dep = use "dep#79d8...".` runs
  pinned; after the working file drifts, and after it is deleted, the pinned
  import still resolves from `.fpr/store`.
- `fpr commit bad.fpr` where `bad` is ill-typed: refused with the type error,
  exit 1. This is new since the first audit, which committed such a module.
- Compatibility is still the written interface. Adding an unannotated `extra`
  was a patch; changing its inferred type from `Int -> Int` to `a -> String`
  was also a patch. Downstream code using `extra` breaks on a "compatible"
  bump. Commit has the inferred environment available now that it runs the
  pipeline; it should diff that.
- The Sol resolver (`Sol/Mod.hs`) still hashes the local AST before dependency
  expansion and has no `.fpr/store` fallback.

## Types, re-probed

Rejected before code generation: `1 + "x"`, an unbound name, a declaration
`f : a -> a` over a body `x + 1`, a `Vector` element pushed as `Int` and read
as `String`, and a double free in both profiles. The typed-vector batch closed
the largest boundary from the first audit.

Still open: `send`, `receive`, `receiveFrom`, `spawn` use `Int` handles and an
unconstrained message type; `Mod.fn` returns a free type variable; the
`SOL_NOTYPES` / `# sol:notypes` escape still exists and a probe with the
pragma reached a runtime arithmetic panic. These are the remaining places a
value can be dynamically typed.

## Refinements, measures and unsafe, re-probed

Native and Sol now agree on parameter preconditions: both panic with
`positive requires (n > 0), got n=-1 (in main)`. The first audit's divergence
is closed (`Sol/Main.hs` line 177 applies `applyPreconds`).

An unproved self-recursive `loop n = loop n` is refused without `unsafe`. A
mutual measure is refused with the "self-recursion only" message. An imported
`spin : unsafe Int -> Int` called from an unmarked `main` is now refused:
`main is unsafe (calls an unsafe-marked function)`. The `blessed` set in
`Safety.hs` is the prelude only; import qualification no longer counts as
verification.

There is still no result refinement in the main pipeline. `Precond.hs` builds
its table from parameter predicates only; a predicate on the result type is
not grammar and falls into the dropped-signature path above.

## WCET

What exists: `fpr stdcheck` prints symbolic op counts with opaque `ω(f)` terms
for unsafe callees and now exits 1 on failure; `FPRC_WCET=1 fpr compile` prints
per-function `segmax` (IR instructions between safepoints) and C-call counts.
Neither is a time or memory bound in signature position, neither takes a
target, and nothing instantiates coefficients for a
`<FPRISC.v1, QOS.v2, Hardware.v2>` triple. `Target.hs` is still execution
profiles. The first audit's proposed resource semantics (upper bounds, named
units, a target manifest, three outcomes: proven within, proven over,
unproved) stand; nothing has been built toward them, and finding 1 means the
proposed syntax currently compiles by being ignored.

## Tabling, TCO, JIT, GPU

Tabling is Sol-only, default-on, arithmetic fragment, LRU 4096. `fib 27` with
`SOL_TABLE_STATS=1`: 25 hits, 28 misses, 0 evictions, 0.04 s against 0.86 s
untabled. Tabled functions still require `unsafe` because `fib` has two
self-calls with no measure; tabling does not feed the safety or cost story.

Native TCO is confirmed by measurement; Sol TCO is confirmed absent by
measurement (finding 2).

JIT: `SOL_JIT_DEBUG=1` reports `vecmap f=sq` and `vecfold` kernels for a
1000-element `Vector Int` and the result (332833500) equals the `SOL_JIT=0`
run. No speedup or float equivalence was measured here.

GPU: the default macOS build is the stub at `cbits/vecgpu.c` line 17;
`SOL_GPU=1 SOL_GPU_MIN=10` produced no GPU tier output. Unchanged.

## MVU

`std/mvu.fpr` is substantial and unchanged in shape: `App = Type (App ini upd
sbs vw)` and `MApp` are constructors over untyped fields, `run` and the frame
loop are `unsafe`, and the compiler's entry point is `main`. MVU is the
recommended library, not the executable's type.

## Recommended order

1. **Refuse unparseable signatures.** Smallest change, closes a hole in the
   core typing rule, and makes every later signature extension fail loudly on
   older compilers. Tests: the three probes above.
2. **Sol tail calls.** A `TailCall` opcode with frame reuse for known saturated
   calls. Test: 30M-iteration measured loop in bounded memory.
3. **One termination and measure language** shared by `Safety.hs` and
   `StdCheck.hs`, so every loop the compile accepts gets a cost equation.
4. **Resource bounds in signatures.** Grammar for upper bounds on work and
   peak memory with named coefficients; a target manifest that binds
   coefficients; `fpr build --target=<triple>` reporting proven within,
   proven over, or unproved per function. Blocked on 1 and 3.
5. **Commit compares inferred interfaces**, not written ones; Sol resolver
   gains the store fallback.
6. **Close the last dynamic boundaries**: protocol-typed actor handles,
   statically checked `Mod.fn`, no `notypes` in a strict profile.
7. **Typed MVU runner** with per-turn budgets once 4 exists.

## Verification scope

Probes were disposable programs under the session scratchpad, built with the
`fpr` from `make fpr` at `edfbaac`, with throwaway `.fpr/` stores and default
caches. Native probes ran as host executables; Sol probes ran on the VM. The
30M Sol run was killed after 300 s. No remote pkgstore, GPU device, QOS target,
or bare-metal run was exercised. `tests/check_cases.py` was run; the other
suites were not.

## Fixed the same day

Findings 1 and 2 are closed in
[2026-10-02-SIGNATURES-AND-TAIL-CALLS.md](2026-10-02-SIGNATURES-AND-TAIL-CALLS.md).
Removing the fallback showed the hole was wider than a typo path: record types
were not signature grammar, so 13 std modules had never had their record-typed
headers checked. They are grammar now and all check. Sol tail calls run the
30M probe in 30 MB. The other rows of the matrix are unchanged.

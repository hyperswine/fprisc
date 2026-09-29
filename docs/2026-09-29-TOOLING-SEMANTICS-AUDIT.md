# Tooling and meta-semantics against the intended language

Date: 2026-09-29. Kind: review/status report plus proposed acceptance criteria.
Scope: native FP-RISC and Sol in this checkout, source revision
`cb71302adf0f023949b5b382574094183d47b251`. No compiler/runtime changes were made
for this audit. Recommendations below are not implemented guarantees.

Companion: [native architecture audit](2026-09-29-NATIVE-IDEAL-AUDIT.md).

## Intended contract

The intended language has immutable, hash-addressed modules, published locally
with `fpr commit` and imported with `use "name#hash"`. Types are statically
checked through annotations or inference: an extended Hindley-Milner system,
linear ownership, and lightweight refinements. Unproved recursion requires
`unsafe`; a verified `measure` should avoid that requirement. Approved library
recursion schemes should carry reusable proofs and resource contracts.

Time and memory bounds should compose symbolically, then be discharged for a
versioned language/runtime/hardware target such as
`<FPRISC.v1, QOS.v2, Hardware.v2>`. Native TCO, automatic tabling of suitable
functions, and Sol JIT/GPU acceleration should preserve those semantics. MVU
should be the standard executable/app pattern.

## Assessment

| Area | Current status |
|---|---|
| Native module pins and local commit/store | Implemented, including transitive pinned dependencies and store fallback. Commit does not certify typing or cost. |
| Immutable identity | AST identity, not exact source-byte identity; FNV-1a-64 rather than a cryptographic digest. |
| Sol module identity | Separate loader hashes the local AST before dependency expansion; no equivalent committed-store fallback in that resolver. |
| HM inference | Shared inference with polymorphism, algebraic data and row-polymorphic records; ordinary unknown names and type mismatches fail. |
| Complete static typing | Not achieved: Vector elements, actor messages and dynamic module lookup have unchecked type boundaries; Sol can disable checking. |
| Linear checking | Real compile-time checks in both profiles; not proof of complete lifetime/memory safety. |
| Refinements | Native parameter contracts with local discharge and runtime fallback; Sol does not apply the same contract pass. |
| Termination | Verified self-recursion measures exist; mutual measures are unsupported; imported unsafe functions are broadly trusted. |
| WCET | Separate symbolic Int-fragment proof tool plus emitted safepoint instruction accounting. No integrated target-bound time/memory certification. |
| Tabling | Operational, default-on Sol memoization for a restricted arithmetic fragment. No native equivalent found in the audited path. |
| TCO | Native known saturated tail calls become jumps. Ordinary Sol bytecode has no explicit tail-call instruction/frame-reuse mechanism. |
| JIT | Operational hand-written AArch64/x86-64 kernels for selected list/Vector schemes. |
| GPU | Restricted F64 map path through EGL/OpenGL compute; default macOS build declines GPU availability. |
| MVU | Substantial library/host patterns, not an enforced entry-point contract for every executable. |

## 1. Modules: identity is implemented; certification is not

[`Modules.hs`](../compiler/Modules.hs) hashes the position-free parsed AST after
normalizing each dependency import to its resolved hash. Native hashes therefore
incorporate the dependency tree. Names are qualified by hash for compilation,
allowing different module versions to coexist. Whitespace/comments do not
change identity. The serialization currently relies on the printed AST, and
the digest is FNV-1a-64; the source itself notes that a real registry would use
canonical serialization and SHA-256.

[`Commit.hs`](../compiler/Commit.hs) implements `.fpr/store/<hash>.fpr` and
`.fpr/versions.db`. Commit refuses unpinned imports throughout the dependency
closure and stores dependency sources. The native resolver rechecks identity
and falls back to the store when working files have disappeared or drifted.
A disposable test committed a parent and dependency, deleted both working
files, and successfully compiled a pinned import from the store.

Important limits:

- Commit calls the module loader, not the normal type/safety/proof pipeline.
  A module containing `f x = 1 + "wrong".` committed successfully, while native
  compilation correctly rejected it.
- Compatibility compares exported names/arities, written signatures, and type
  constructor declarations. It does not compare inferred interfaces. Changing
  unannotated `f x = x + 1.` into `f x = "text".` was classified as a compatible
  patch (`v1.0` to `v1.1`). Thus “signature-compatible” is not a safe general
  hot-reload claim today.
- Content-addressed files are ordinary local files written with `copyFile`;
  identity verification is the important protection, not filesystem immutability.
  Multiple source spellings can have the same AST hash.
- A module hash is not a build/proof identity covering compiler, runtime, hardware,
  primitive contracts, optimization settings and all linked native code.

Sol uses [`Sol/Mod.hs`](../compiler/Sol/Mod.hs) and
[`Sol/Main.hs`](../compiler/Sol/Main.hs), `expandUses`. It verifies local AST pins
before recursively expanding imports, unlike native dependency-normalized
hashing. An unpinned descendant can therefore change without changing its
parent's local AST hash. That resolver has no native-style `.fpr/store` fallback.
The two profiles need one explicit identity contract if they are to share the
same immutable module promise. Remote push/pull was not exercised in this audit.

## 2. Types: a real inference engine with important escape boundaries

[`Infer.hs`](../compiler/Infer.hs) implements Algorithm-W-style inference,
unification, generalized type/row variables, monomorphic recursion within SCCs,
algebraic constructors, records, and Sig/Struct checking and specialization.
Native compilation rejects accumulated inference errors before code generation.
Unknown names are reported, rather than silently accepted as inferred externs.
Type variables remaining in a legitimate polymorphic scheme are not dynamic
typing and should remain legal.

Fresh probes rejected an unknown name, `1 + "x"`, and a false polymorphic
promise `f : a -> a.` implemented by `f x = x + 1.`. The latter uses rigid type
variables when checking the declaration. However, `skolemize` explicitly leaves
row variables flexible, so full generality checking of row-polymorphic promises
remains incomplete. The representation also has no kind system.

The stronger “everything is statically typed” requirement is not met:

- `Vector` carries no element parameter. `Vec.push` and `Vec.get` quantify their
  element variables independently. A fresh native compilation accepted storing
  integer `1`, reading it as `s`, then passing `s` to `String.len`. This unsafe
  executable was not run.
- `send`/`receive` use `Int` actor handles and unconstrained message type
  variables, not a protocol-indexed actor reference.
- `Mod.fn : String -> String -> a` gives dynamic lookup an unconstrained result
  type rather than validating a statically known exported signature.
- Sol accepts `SOL_NOTYPES=1` or `# sol:notypes`. A probe with the pragma bypassed
  the checker and reached a runtime arithmetic panic for `1 + "x"`.
- Named typed holes block compilation; anonymous `??` holes can compile as
  runtime traps. These are typed bottom/unimplemented expressions, not successful
  implementations of their inferred type, and need a release policy.

Linear checking is real: native and Sol probes both rejected freeing a vector
twice. Native combines explicit, inferred and builtin linear shapes before
`lcheck`; Sol uses its own frontend wiring. This audit does not establish full
parity or soundness of every higher-order/ADT ownership path. Linearity checking
also does not remove the separate unsafe pool-reset lifetime contract described
in the companion audit.

## 3. Refinements, measures and unsafe are different mechanisms

[`Precond.hs`](../compiler/Precond.hs) handles native parameter predicates such as
`positive : (n : Int | n > 0) -> Int.`. Local facts can discharge obligations;
otherwise the pass inserts runtime checks. Unsupported predicate syntax is an
error. This is a hybrid contract system, not a policy that every unproved
predicate makes compilation fail.

A fresh native program calling `positive (-1)` built successfully and then
failed with the named precondition panic. The corresponding Sol program printed
`-1` and exited successfully: its preparation pipeline does not run the same
precondition insertion/discharge pass. Shared parsing is not shared enforcement.

[`Safety.hs`](../compiler/Safety.hs) separately checks recursive SCCs and declared
measures. Self-recursive calls can be justified by structural descent or a
linear decrease with a derivable nonnegative floor. A countdown measure passed;
a non-decreasing measure failed. Mutual-recursion measures are explicitly
rejected. Unproved recursion requires `unsafe`, with profile/transition bypasses
also present (`--no-safety`, Builtin, `SOL_NO_SAFETY`).

The major trust gap is `blessed`: names from the prelude or containing `.`/`@`
stop unsafe propagation. This admits imported custom modules, not only a
verified standard-library set. A custom imported `f : unsafe Int -> Int` with
`f n = f n` was accepted from an unmarked `main`. It was compiled only, not run.
Importing a function is therefore currently enough to cross this safety boundary;
no proof certificate is required.

Termination is not a total-work bound. If two recursive calls each decrease a
measure, recursion depth may be bounded while work branches exponentially.
General claims that a verified measure means “measure(entry) iterations” must
be restricted to suitable single-chain recursion or replaced with recurrence
analysis. `unsafe` here primarily marks unproved recursion/cost; it is not a
complete purity, effect or memory-safety system.

## 4. WCET: useful components, not the target-triple contract

There are two distinct implementations:

1. [`StdCheck.hs`](../compiler/StdCheck.hs) and
   [`StdBridge.hs`](../compiler/StdBridge.hs) implement a separate proof tool,
   invoked with `fpr compile --stdcheck file.fpr`. It lowers an Int-oriented
   subset, analyzes intervals and restricted termination, and prints symbolic
   operation-count equations with opaque `omega(function)` terms. `foldRange`
   is a recognized bounded scheme. Postconditions use a special `post_f`
   convention. This path parses a single file and exits without normal codegen.
2. [`Codegen.hs`](../compiler/Codegen.hs), `wcetAnnotate`, emits `segmax`,
   `exittail`, and C-call counts. `FPRC_WCET=1` summarizes them. These count
   pre-lowering instructions between scheduler safepoints, not elapsed time or
   whole-program work. Native/C callees still need external cost bounds.

Fresh `--stdcheck` probes printed a one-operation cost for increment, and
reported a signed unsupported list body as `stdcheck: FAILED`. **The failure
still returned exit status 0**: `runStdCheck` prints errors, and its caller exits
successfully. It is not currently a reliable build admission gate.

The requested general `time f` / `mem f` signature language, symbolic memory
bounds, versioned target-triple instantiation, and end-to-end confirm/deny gate
were not found in the integrated compiler. `Target.hs` describes execution
profiles, not a database of certified language/runtime/hardware costs. Existing
fuel and symbolic-cost work are useful foundations, not substitutes for that
missing composition.

### Proposed resource semantics

Prefer upper bounds over exact equalities. A conceptual contract might say:

```text
requires a >= 0
work(f, a) <= omega * a + beta
peak_live_bytes(f, a) <= gamma * a + delta
```

This is proposed notation, not accepted syntax. Define the meaning and units
of each quantity: operation count, CPU time, wall-clock response, total allocated
bytes, peak live heap, stack, mailbox storage, and accelerator storage differ.
Unknown coefficients must become certified bounds or explicitly unresolved
obligations, not free variables chosen to make an inequality pass.

A target manifest should bind exact compiler/lowering, runtime/QOS, hardware,
allocator and scheduler policies, foreign primitive contracts, and optimization
settings. Versions can be readable names, with hashes identifying the actual
artifacts. A proof result must identify these assumptions and the module graph.

Composition must account for callee cost, branch maxima, recursion multiplicity,
allocation lifetime, callbacks, mailbox capacity, contention, interrupts and
blocking I/O. For `Vec.map`, a known iteration count only helps when element
function work and allocation are bounded too. Parallel speedup cannot simply
divide sequential WCET by worker count.

Use distinct outcomes: proven within budget; proven over budget; unproved under
the selected assumptions. A strict build profile should reject both over-budget
and unproved obligations. A general profile may permit explicitly unsafe code,
but must not describe that artifact as fully certified.

## 5. Tabling, TCO, JIT and GPU

[`Sol/VM.hs`](../compiler/Sol/VM.hs) implements default-on tabling unless
`SOL_TABLE=0`. Eligibility is restricted to arithmetic Core, including suitable
self-recursion; runtime cache keys require integer arguments and eligible
functions have at most four parameters. Tables have an LRU capacity (default
4096) and a cost/probe-based rule to disable cheap, shallow cases. This is real
memoization, not a generic cache of arbitrary functions. The tabling example
returned `fib 27 = 196418` twice and reported 26 hits, 28 misses, zero evictions.

For resource proofs, cache capacity, cold misses, eviction work and retained
results must be modeled. An optimistic observed speedup is not a worst-case
bound.

Native `knownCall` restores the frame and jumps in tail position, covering
known saturated self/mutual calls. Generic application is not the same guarantee.
Sol bytecode uses `Call` followed by continued interpretation; there is no
explicit tail-call opcode/frame reuse in the ordinary VM path. Native TCO must
not be advertised as blanket VM TCO.

[`Sol/HandJIT.hs`](../compiler/Sol/HandJIT.hs) emits native AArch64/x86-64 kernel
bytes from typed Core/KIR, without LLVM. Selected list/Vector map/filter/fold
schemes qualify when callback code and layouts are supported; scalar captures
and SoA loads are supported. The VM threshold is 64 elements. A disposable
1,000-element Vector map/fold returned `501500` with JIT disabled and enabled;
diagnostics confirmed compilation of both AArch64 kernels. This establishes
execution and result agreement, not a speedup or full numeric equivalence.

[`Sol/Gpu.hs`](../compiler/Sol/Gpu.hs) supplies a narrower F64 map tier, gated on
availability, translatable arithmetic and size (default 65536). It falls through
to JIT/interpreter. [`cbits/vecgpu.c`](../compiler/cbits/vecgpu.c) uses EGL/OpenGL
compute shaders; the default Apple build is an unavailable stub, not a Metal
implementation. GPU execution and numeric edge-case equivalence were not tested
here. Existing comments claiming bit-identical IEEE behavior are not enough to
certify every GPU/compiler combination. JIT compilation and GPU startup/transfer
costs also need explicit treatment in any bounded execution profile.

## 6. MVU is a library convention, not the executable type

[`std/mvu.fpr`](../std/mvu.fpr) provides App/MApp, initialization, update,
subscriptions, view, event data, and an actor-backed render lifecycle. Sol has
web hosting and a typed UI ADT in `sol/lib/ui.sol`; the older `web.sol` record
vocabulary is marked legacy. These are substantial implementations.

Native programs still enter through `main`; Sol runs top-level effects and a
zero-arity `main`. The compiler does not require an MVU App for every executable.
Current `App`/`MApp` declarations also do not parameterize and tie together all
Model/Message/View roles as a strict application protocol would.

For an MVU default, provide a typed application interface and standard runner
while retaining a deliberate one-shot/low-level program form. A persistent app
does not terminate as a whole: certify bounded update/view/actor turns, state
growth, event rates and queue capacities rather than requiring termination of
the entire event loop.

## 7. Recommended work and acceptance boundaries

1. **Close type boundaries.** Parameterize Vector elements and actor protocols;
   constrain module lookup and finish row-signature checks. Remove no-types
   paths from a strictly checked/release profile. Negative tests must reject
   cross-type Vector reads before code generation.
2. **Share semantic enforcement.** Run the same refinement/measure rules across
   native and Sol; distinguish static proof from runtime guards. An identical
   precondition must not silently disappear when switching profile.
3. **Make trust explicit.** Import qualification must not count as verification.
   Attach declared unsafe/effect/resource assumptions to exported interfaces;
   approved primitives and library schemes need versioned contracts.
4. **Unify module and interface artifacts.** Native/Sol pins should freeze the
   same dependency closure. Compatibility must compare checked inferred
   interfaces, not just arity/written annotations. A raw snapshot operation may
   remain separate from a certified publication operation, with clear labels.
5. **Make proof failure actionable.** Fix `--stdcheck` exit status, then integrate
   symbolic time/memory obligations and target manifests into build admission.
   Document unsupported proof fragments and unresolved external costs.
6. **Specify optimization semantics.** Define resource/semantic contracts for
   fusion, memoization, tail calls, JIT and GPU paths, including fallback and
   startup costs. Do not use benchmark wins as proof bounds.
7. **Make MVU the standard typed runner.** Model per-turn budgets and bounded
   storage explicitly; prove callback contracts, not just the outer loop shape.

## Verification scope

Focused probes used the locally rebuilt `fpr` binary, temporary source/store
directories and temporary native/Sol caches. Native compile-only tests emitted
AArch64 assembly. Deliberately unsafe type/termination examples were not run.
Only the precondition runtime probe and the stated Sol examples were executed.

No remote registry, live app/browser, GPU device, alternate ISA or full test suite
was exercised. The source findings and disposable probes above are audit evidence;
they are not a committed regression suite or a proof of type-system soundness.

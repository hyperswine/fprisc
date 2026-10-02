# Specialization: removing function values at known call sites

Date: 2026-10-03. Kind: plan. Nothing here is implemented.

## The claim and its limit

FP-RISC has no closures. `liftFix` lifts every lambda to a supercombinator
whose captures are leading parameters, so the only function value is the
partial application record `pap_t` (`runtime/fpr.h:37`): a code pointer, an
arity, and the arguments supplied so far. A PAP is built only when a
function escapes a known call: passed as an argument, stored in a record,
sent to an actor, kept partially applied, or returned by `Mod.find`.

The representation cannot be removed. `Mod.find` returns functions from
images attached after the program was built, and the LiveReload design
([2026-10-03-LIVERELOAD.md](2026-10-03-LIVERELOAD.md)) rebinds through
exactly those PAPs. Defunctionalizing into a closed dispatch would have to be
rebuilt on every reload. What can be done is to make more call sites
*known*, so that the PAP and the `fpr_apply` through it never exist. That is
specialization: a clone of a higher-order function per statically known
function argument.

## What already does part of this

- **`Struct.hs`** (`specialize`): surface-level cloning of a generic function
  per known `Struct` argument, `g N xs` to `g#N xs`, worklist with a seen
  set, clones re-scanned transitively, cross-unit clones placed in the root.
  The shape of the pass to copy.
- **`Inline.hs`** (`inlineWith`, base profile): Core-level inlining of small
  non-recursive callees at saturated sites, with a function-valued argument
  that is an unshadowed global substituted outright for its parameter, and
  `propagateWith` turning `x = g` into a known name. So `apply inc n` already
  loses its PAP. What it cannot do is recursive callees, and every list and
  vector loop is one: `mapGo f xs acc` keeps `f` a parameter and applies it
  through `fpr_apply` once per element, and a lambda argument with captures
  allocates a PAP at every creation.
- **Codegen vector schemes** (`emitFilterSpec` and friends) and Sol's
  `HandJIT`: the builtin `Vec.*` kernels already specialize on known
  callbacks. This plan covers FP-RISC-defined higher-order functions; the
  kernels keep their own paths.

## The pass

A Core pass, `Mono.hs`, after lifting and before `Inline`, on the merged
program with clones emitted into the caller's unit.

**Site.** A saturated call `g a₁ … aₙ` where `g` is a global, its parameter
`pᵢ` occurs in function position in `g`'s body (or is passed unchanged at
that position to a call within `g`'s recursive group), and `aᵢ` is a known
function: a global `h` with zero captures, or `h c₁ … cₖ`, a partial
application of a global to arguments in the caller's scope.

**Clone.** `g$h/k` is `g` with `pᵢ` removed and `k` new leading parameters
for the captures. In the body, `pᵢ x` becomes `h c₁ … cₖ x`, a known
saturated call; a recursive call in the group that passes `pᵢ` unchanged
becomes a call to the clone with the captures threaded through. The
caller's site becomes `g$h/k c₁ … cₖ a₁ … aₙ` without `aᵢ`. If the group
passes a *different* function at that position (`go (fn x -> f (f x))`), the
site is not specialized; cloning a function of a function is where the
worklist can run away.

**Groups.** A mutually recursive group is cloned together, as
`Safety.measureCheck` verifies measures as a group.

**Termination.** Seen set on `(g, i, h, k)`; a depth bound on nested clone
creation (a clone's own sites are rescanned, so generics calling generics
specialize transitively); a per-unit budget on total clone size, after which
sites stay dynamic. Every site left dynamic is still correct.

**Then the inliner.** `h` is usually small (`double x = x * 2`), so
`inlineWith` inlines it into the clone and the loop body of
`mapGo$double` is `x * 2 :: acc` with a known saturated self call: a tail
jump, no PAP, no `fpr_apply`, no frame.

## What it changes and what it must not

- **Semantics: nothing.** A clone is the callee with one argument fixed.
  The differential gate is the whole base suite with the pass on and off
  (`FPR_NO_SPEC=1`, as `FPR_NO_INLINE=1` exists), outputs identical.
- **Allocation: down.** A lambda with captures allocates a PAP per creation
  today; its captures become arguments instead. The heap-delta witnesses in
  `check_base` are the measure.
- **Cost equations: unchanged, and still true.** The cost pass runs on the
  unspecialized Core and already substitutes `work f` at known sites, so its
  numbers are upper bounds that specialization only tightens. A declared
  bound proven before the pass stays proven. The pass is codegen-side and
  invisible to Safety, Precond, linearity and Cost, which is why it runs
  after them.
- **Safepoints: shorter segments or equal.** `fpr_apply` is a C call and does
  not count as a safepoint (`Codegen.wcetAnnotate`); the known call that
  replaces it is one. `tools/wcet-ratchet.sh` must not move up.
- **Live modules stay dynamic by construction.** A function obtained from a
  `live` module record or `Mod.find` is not a known global, so no clone bakes
  it in. Static `use` modules are already linked.
- **Separate compilation.** A clone of a std function for a root function
  is a new global of the root unit, named with both hashes
  (`mapGo@5cc2…$double@root`), as Struct clones already live in the root.
  Cached units are untouched; `codegenRev` bumps once.
- **Sol.** `Sol/Main.hs` compiles the same Core to bytecode; running the pass
  there removes `Apply` instructions the same way and gives `HandJIT` more
  known callbacks.

## Order of work

1. **Baseline.** A `FPRC_APPLY=1` summary like `FPRC_WCET=1`: per unit, the
   number of `fpr_apply` sites and PAP creations, and the allocation ledger
   of `examples/todo.fpr` and the std list pipeline from
   `tests/cases/bound_pipeline.fpr`. Numbers to ratchet, in
   `docs/2026-09-30-NATIVE-PERF.md`'s format.
2. **Zero-capture globals, self-recursive callees, root unit.** `List.map
   double xs`, `List.filter isSource files`, `fold add 0 xs`. Differential
   gate on, `FPR_NO_SPEC` switch, clone naming, budget.
3. **Captures.** `fn x -> x + k` becomes `lam_7 k x`; the clone takes `k`.
   This is where the per-creation PAP disappears.
4. **Groups and cross-unit placement.** `sortWith` through `mergeAll`,
   `mergePairs`, `merge`; clones in the caller's unit; the Sol pipeline.
5. **Chain with the inliner, measure, document.** `mapGo$double`'s body
   inlined; the baseline numbers re-run; the perf record updated.

Steps 1 and 2 are a few days and show whether the win is what the
representation argument says it is. Step 3 is the one that removes
allocation. Steps 4 and 5 are completeness.

## Not in this plan

Specializing on *values* other than functions (a known `Int` argument), which
is partial evaluation and a different cost model; removing PAPs that escape
into records, actors or module tables, which the open world forbids;
changing `fpr_apply` itself.

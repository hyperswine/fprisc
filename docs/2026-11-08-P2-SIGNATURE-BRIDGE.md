# P2 signature bridge, slice 1: checked kinds beside KernelKinds

Date: 8 November 2026. Kind: implementation record, the first change of
Phase P2 in the [pipeline refactoring roadmap](2026-11-07-PIPELINE-REFACTORING-ROADMAP.md)
("first carry evidence alongside the existing path and check agreement").
Base: `3004f4d` (slice 1), `c31f0cd` (slice 2). Generated code: unchanged by either.

## What changed

`KernelKinds` solves raw-word signatures (`Int`, `F64`, `F32`, `Bool`) from
erased Core by unification, and `Workers.scalarWorkers` uses them to pick
private scalar workers. Typed Core already knew those types; P2 removes the
re-inference in steps. This slice carries the checked answer to the same place
and compares the two.

- `Core.Opt.ProductParameters` gains a seventh component, the checked kinds:
  for every function with a checked interface, the raw-word kind of each
  parameter and the result (`rawKind`: `Int`→`KI`, `F64`→`KD`, `F32`→`KS`,
  `Bool`→`KB`; anything else is `Nothing`). It is built from the same
  `M.Map String Interface` that the product evidence already comes from, keyed
  by parameter names like the other entries. `checkedKinds` returns only the
  entries whose parameters still match the program, so a renamed or
  re-parameterized function never reads another body's kinds. `Mono`'s
  renaming transports the kinds with the rest of the evidence. Entries are
  forced on construction, so they retain no interface.
- `Workers.workerizeWithProducts` compares every scalar worker signature
  `KernelKinds` chose with the checked kinds of its source function
  (`signatureAgreement`):
  - **agreed**: every position has a checked raw kind, and they are equal;
  - **guarded**: equal wherever the checked type is a raw word, and some
    position's checked type is not one (a type variable, say). The wrapper's
    runtime test still selects the general body, so this stays an
    optimization guard (semantic policy Rule 2);
  - **unchecked**: no checked interface with that arity (a function made by an
    earlier erased pass);
  - **a disagreement** on any checked raw position stops the compile with
    `signature bridge: KernelKinds solved ... but its checked interface says ...`.
    It is forced with the pass result, so it runs whether or not notes are printed.
- Each unit prints `# signature bridge: agreed=A guarded=G unchecked=U`
  beside `# private workers`.

Nothing else reads the checked kinds yet. `productParameterKey` (cache
identity) is unchanged, because no emitted code depends on them. The slice
that makes the checked kinds the authority must add them to cache identity.

## Evidence

| Check | Result |
|---|---|
| `make unit-tests` | 42 of 42 suites pass. `CorePipeline` adds agree, guarded, unchecked, arity mismatch and a forced disagreement that must stop the compile. |
| `tests/check_signature_bridge.py` (19 corpus entries, host and RV64) | agreed 6, guarded 0, unchecked 1, no disagreement on either target; `fib`'s `Int -> Int` worker agrees |
| Sweep: every `examples/`, `tests/bench/` and `tests/base/` program (134) | agreed 36, guarded 0, unchecked 3, no disagreement. Six do not compile with either compiler (library modules and other-target programs). |
| QOS `tests/guishell.fpr` (qos 5feea4b) | compiles; 53 units, agreed 1, no disagreement |
| `tools/pipeline-baseline.py --check` | 19 behaviour contracts hold |
| Code facts, bridge vs `3004f4d` compiler | identical assembly bytes and lines, per-function frame/spill/segment facts and preconditions on all 19 entries. The only difference is pingpong's runtime allocation count (+0.02%), which also varies between two recordings with the same compiler (actor scheduling). |

Zero guarded signatures means every scalar worker `KernelKinds` chose in this
code sits on a function whose checked type is all raw words. Its inference has
added nothing the checked types did not already say.

## Slice 2 (same day): checked kinds are the worker authority

`Workers.scalarWorkers` now takes each recursive component's signature from
its members' checked kinds, when every member's checked interface is all raw
words and matches its arity. `KernelKinds` still solves the same component
from erased Core, as an assertion. Each component is classified:

| Class | Checked kinds | `KernelKinds` | Worker signature |
|---|---|---|---|
| agreed | full and scalar | same solution | the checked one |
| (error) | full and scalar | a different solution | compile stops |
| guarded | some member has a non-raw checked position | solved | `KernelKinds`', checked positions must agree |
| unchecked | no checked interface | solved | `KernelKinds`' |
| checked_only | full and scalar | declines | none in this slice |

`checked_only` components are counted but not admitted. Admitting them would
change generated code, and the roadmap reviews representation changes
separately. The checked kinds now enter cache identity through
`productParameterKey`, since they decide what is emitted.

The unit tests drive `scalarWorkersWith` directly. They cover:
- the checked signature as the worker signature;
- guarded, unchecked and arity-mismatch cases;
- a forced disagreement that must stop the compile;
- a checked-only loop: `carry n k` returns `n` unconstrained, so `KernelKinds`
  declines it while the checked `Int` signature admits it, and it must get no
  worker.

| Check (slice 2) | Result |
|---|---|
| `make unit-tests` | 42 of 42 suites pass |
| `tests/check_signature_bridge.py` (20 corpus entries, host and RV64) | agreed 6, guarded 0, unchecked 1, checked_only 0, no disagreement |
| Code facts vs main's recorded baseline (`f594e82`) | 0 differences in behaviour, assembly bytes and lines, per-function facts or private workers, on all 20 entries |
| 134-program sweep | agreed 36, guarded 0, unchecked 3, checked_only 0, no disagreement |
| QOS `tests/guishell.fpr` | compiles; agreed 1, no disagreement |

`checked_only` is 0 everywhere, so in this code `KernelKinds` never declined
something the checked types would admit. Dropping its gate would add no
workers here. The win would come from programs it cannot solve today.

## Slice 3 (same day): field workers carry checked kinds

Slice 2 left 3 unchecked workers in the sweep and 1 in the corpus. All four
were `$worker.fields.<name>`: functions the field-worker pass creates when it
splits a tuple or record parameter into its fields. They have no checked
interface of their own. Two gaps kept their source's facts from reaching them:

- `expandProductParameter` already moved the parameter type table to each new
  worker, but `fieldWorkers` dropped the updated `ProductParameters`, and
  `workerizeWithProducts` gave the scalar pass the table from before the field
  pass. `fieldWorkers` now returns the transported facts and the scalar pass
  reads them.
- The table stored every non-product field as the opaque `$base.boxed`, so a
  field of `(Int, Int)` had no kind. `layoutType` now keeps raw-word types
  (`Int`, `F64`, `F32`, `Bool`) exact; they are small constants, so the
  memory reason for the opaque leaf does not apply to them.

`expandProductParameter` now also moves the checked kinds: the new worker keeps
the source's other positions and result, and each field takes its checked
field type's kind. A field whose type is not proven (a heuristic step, a type
variable) stays unknown, which makes the component guarded, not agreed.

The bridge note names any unchecked function (`unchecked_names=`), and
`tests/check_signature_bridge.py` now fails on any unchecked worker in the
corpus.

### Evidence

| Check | Slice 2 | Slice 3 |
|---|---|---|
| Unit suites | 42/42 | 42/42 |
| Corpus, host and RV64 | agreed 6, unchecked 1 | agreed 7, unchecked 0 |
| Code against `bench/pipeline-baseline.json` (20 entries) | identical | identical |
| Sweep, 145 programs, same cache method | agreed 16, unchecked 4 | agreed 20, unchecked 0 |
| QOS guishell | agreed 1 | agreed 1 |

Guarded and checked-only stay 0 everywhere; no disagreement. Only the three
programs holding the field workers (`tests/base/workers.fpr`,
`tests/bench/workers.fpr`, `tests/bench/unbox/tuple_loop.fpr`) change counts.
The same 6 programs fail to compile with both compilers, as before.

Counting note: a unit served from the compile cache prints no bridge note, so
sweep totals depend on cache state. Slice 2's "agreed 36" came from a
differently warmed cache and is not comparable; the slice 2 column above was
rerun from 902db56 with a fresh cache, the same way as slice 3.

## Slice 4 (same day): checked kinds admit what inference cannot

`KernelKinds` infers a kind for every position from how the body uses it. A
parameter that is only passed along (`hold i k acc`, where `k` goes back into
the recursive call unchanged) gives it nothing to infer from, so it declines
the whole loop. The checked type says `Int`. Slice 2 counted these components
as checked-only; slice 4 admits them.

The assertion survives: `KernelKinds.verifyComponent` checks each member body
under the checked signatures instead of inferring them. A position the body
never constrains is accepted; a body that contradicts its checked signature
(a Bool returned where the checked result is `Int`) stops the compile, as a
disagreement does.

Fixture: `tests/pipeline/scalar_pass_through.fpr` (corpus entry
`scalar_pass_through`). `hold` passes an `Int` along, `relay` passes a `Bool`
along and returns it; `count` and `carry` use every parameter and are
controls. `tests/check_signature_bridge.py` requires checked_only >= 2 on it;
`tests/CorePipeline.hs` covers admission, a pass-through Bool and the
unverifiable case.

### Evidence

Reference: 6e1edab (slice 3), built in a separate worktree.

| Check | Result |
|---|---|
| Unit suites | 42/42 |
| Corpus, host and RV64 (21 entries) | agreed 9, checked_only 2, unchecked 0, guarded 0 |
| Code on the 20 earlier entries vs `bench/pipeline-baseline.json` | identical |
| Fixture output | identical (`30000007 60000000 90000000 False`) |
| Overflow in `hold`'s worker | same trap, message and exit 1 |
| `hold` alone, 3e8 iterations | 0.39 s -> 0.31 s (1.30 -> 1.03 ns per iteration) |
| `relay` alone, 3e8 iterations | 0.39 s -> 0.31 s |
| Cold sweep, 145 programs, both compilers | identical counts (agreed 56, checked_only 0) and identical asm size; same 6 compile failures |
| QOS guishell | agreed 1 |
| `make pipeline-baseline-check` (re-recorded, host + RV64) | 21 behaviour contracts hold |
| Policy D1, D2 | PASS |

No existing program in the sweep has a pass-through loop, so the change shows
only on the fixture today.

Counting method, corrected: each sweep program now compiles with its own
output path and a fresh cache (`cold-one.sh` pattern: one directory per
program). The earlier shared-output sweeps reused per-output unit sidecars and
cache entries, so their totals (36, 16, 20, 44) depended on order and cache
state and are not comparable to each other or to the 56 above. Assembly
comparison was unaffected.

## Slice 5 (same day): vector callbacks take checked kinds

`Core.Opt.Vector` planned callback kinds with the lenient `KernelKinds.signature`,
which defaults every position the body never constrains to `Int`. A vector
kernel guards its inputs at run time (vector element tag, `isInt` on
arguments) and falls back to the general per-element path when the guess is
wrong. So the guess was safe but slow: an `F64` callback that only moves an
argument (`pick acc x = x`) took the fallback on every call.

Measured before the change, 200 folds over 1,000,000 `F64` elements:
`Vec.fold pick` 2.50 s against `Vec.fold add` 0.59 s, although `pick` does
less work (12.4 against 3.1 ns per element).

The checked kinds now reach the vector planner: `pipelinePlan`, `typePlan`,
`vecSpec` and the nesting step take `CheckedKinds`, supplied by
`Core.Opt.Pipeline` (fusion compatibility) and `Codegen` (kernel sites and
the decline notes) from the same `ProductParameters`. `callbackKinds` uses a
named callback's checked signature when every position is a raw word and
`KernelKinds.verifyComponent` accepts the body under it. A callback without a
complete checked interface (a lambda, a record-map field, a type variable)
keeps the lenient solution, so nothing that worked before changes. If
verification fails and strict inference finds a different full signature,
the compile stops.

The `typed-ir-kernel:` note now ends with the planned kinds
(`kinds=KD,KD->KD`), so a test can see which signature won without timing.

Fixture: `tests/pipeline/vec_callback_kinds.fpr` (corpus entry
`vec_callback_kinds`): `fold pick`, the fused `map same` + `fold keepAcc`
(`wfold_keepAcc_same`), and the `fold add` control.
`tests/check_signature_bridge.py` requires all three kernels to be planned as
`F64` on the host; `tests/CorePipeline.hs` covers the lenient guess, the
checked authority, an incomplete checked signature and a contradiction.

### Evidence

Reference: b5c218c (slice 4), built in a separate worktree.

| Check | Result |
|---|---|
| Unit suites | 42/42 |
| `fold pick`, 200 x 1,000,000 `F64` | 2.50 s -> 0.28 s; `fold add` unchanged (0.59 s) |
| Fixture | same output; 0.13 s -> 0.02 s |
| Run differential: 46 programs (all `tests/base/vec*`, all benchmarks, pipeline fixtures), both compilers | identical stdout and exit code |
| Cold sweep, 145 programs | identical asm size and bridge counts; same 6 compile failures |
| Corpus bridge, host and RV64 (22 entries) | agreed 9, checked_only 2, no disagreement; vector kernels `KD` |
| `make pipeline-baseline-check` (re-recorded, host + RV64) | 22 behaviour contracts hold |
| Policy D1, D2 | PASS |
| QOS guishell | compiles |

No existing program had a guessed callback, so only the fixture changes.

## Next slices

1. ~~The unchecked workers~~: done in slice 3.
2. ~~Admit checked-only components~~: done in slice 4.
3. ~~`Core.Opt.Vector`'s `signature` call~~: done in slice 5 for named
   callbacks. Lambdas and record-map fields still use the lenient solver;
   they need checked kinds carried for lifted lambdas.
4. **Remove `KernelKinds`** once no native path consumes it (the roadmap's P2
   deletion gate). Lowering from the typed program and the validation
   operation of semantic policy Decision 4 follow in later P2 slices.

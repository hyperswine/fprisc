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

## Next slices

1. **The three unchecked workers.** Find which erased pass makes their source
   functions (no checked interface) and give them a checked origin, or keep
   them on `KernelKinds` and record why.
2. **Admit checked-only components** as a separate, measured representation
   change: corpus fixtures where `KernelKinds` declines, plus code and timing
   evidence.
3. **`Core.Opt.Vector`'s `signature` call**, the other consumer, gets the same
   checked authority.
4. **Remove `KernelKinds`** once no native path consumes it (the roadmap's P2
   deletion gate). Lowering from the typed program and the validation
   operation of semantic policy Decision 4 follow in later P2 slices.

# Zero-overhead core: independent confirmation and the List/SIMD boundary

Date: 1 November 2026. Kind: analysis; changes no compiler behaviour.
Base: main `ab50224`. This page independently confirms the direction of
[the unboxing proposal](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md) and
[the zero-overhead follow-ups](2026-10-31-ZERO-OVERHEAD-FOLLOWUPS.md)
against the source, and adds one correction to the natural wish-list:
**fusion, not SIMD, is List's zero-overhead tool.** It is the design
companion for starting the proposal's B1 (list fusion).

## Confirmed against the source

1. **There is no dispatch overhead left to remove.** The language has no
   type classes or dictionaries; operators resolve by operand type and the
   specializer monomorphizes (`compiler/Compile.hs:391`,
   `compiler/Infer.hs:943`). Polymorphic functions compile once over
   tagged words (`compiler/Mono.hs:1-3`); specialization clones over known
   callbacks (`compiler/Core/Typed/Specialize.hs:2-4`). What remains is
   *representation* cost — tagging, boxing, the uniform word ABI at
   polymorphic boundaries — not indirection. "Monomorphise everything" is
   therefore already half-true; the missing half is type-directed
   representation, the proposal's C2.

2. **"Unbox by default, box when needed" and "monomorphise everything"
   are one feature, not two.** An unboxed `List Int` cell and an unboxed
   `List a` cell are different layouts; the latter cannot exist without
   per-type code or runtime type information. So default unboxing is
   exactly budgeted type-directed monomorphization with a uniform fallback
   (C2), not a cheaper step that can land before it. The proposal's
   ordering — representation-neutral transforms first, C2 last with its
   own ABI revision — is correct for this reason.

3. **The strict language makes this tractable.** No thunks, so no
   laziness-driven boxing; the entire problem is value representation.
   The unconnected pieces the protposal lists exist as described:
   `Representation.hs` infers representations whole-program for the
   standalone ARC ABI and rejects representation-polymorphic code;
   `Workers.hs` gives private unboxed worker conventions with one
   fixed-width constructor parameter per function.

4. **The warn-on-fallback channel already exists.** Vector fusion reports
   every declined fusion with its reason
   (`Core/Typed/Fusion.hs:22-28`, `renderNote`: "vec note: ... is NOT
   fused: ... -- the two passes run in order"), surfaced through
   `--remarks`. List fusion should emit the same notes; no new warning
   mechanism, no new user-facing surface.

5. **The measured headroom is real and fusion-shaped.** The proposal's
   benchmarks (x86-64, 15 interleaved runs,
   `bench/2026-11-01-unboxing.json`): `range |> sum` at 11.8 ns/element
   against 1.4 for the explicit loop; `map` three cells per element;
   GHC -O2 fuses the same pipelines to zero allocation. B1's ceiling is
   measured (`loop_sum`), not extrapolated.

## The correction: SIMD does not transfer to List

The wish-list item "apply the same fusion rules and auto vectorization and
SIMD to List by default, with fallback" splits into two very different
propositions:

- **Fusion: yes.** Producer/consumer fusion of the std list combinators
  is semantics-preserving, representation-neutral, and reuses the vector
  pass's effect-order evidence. This is B1.
- **Auto-vectorization/SIMD: no, not on the cons representation.** SIMD
  requires dense, contiguous, homogeneous elements. A cons cell is a
  pointer-chased heap node (48 B today: 8 B header, 2 tagged words, 32 B
  rounding, 16 B preheader — proposal, "Representation today" and
  "Evidence"). There is nothing to vectorize in place; a gather into a
  dense buffer is a full extra pass that only pays off under heavy
  per-element arithmetic, at which point the program is a Vector program
  written with lists. Making `List` chunked or array-backed to enable SIMD
  (proposal B4) breaks O(1) cons and persistent sharing — a semantics
  change to every list in every program — and the proposal already rejects
  it as a default.

The useful bridge is the proposal's B5 taken one step further: when a
*fused* pipeline is a known-length, single-consumer dense computation, its
fused body may lower onto the existing vector kernels where profitable.
That is an internal lowering choice inside B1's output, invisible to
users, and it keeps SIMD where the representation supports it.

## What is genuinely irreducible

Checked-arithmetic trap checks, fuel ticks for cooperative scheduling, and
the tagged-word ABI at actor/FFI/hot-reload boundaries are semantics, not
abstraction overhead; "zero overhead" for the core means removing
everything else. The proposal's 52-instruction fold loop shows how much of
the current cost is removable: the 17-instruction `Nil` test, the double
tick, tag/untag churn and the redundant allocations are all pure overhead.

## Consequence for B1 (started with this page)

List fusion proceeds as the proposal's phase 3 item B1, pulled forward:
fuse the std producer/consumer combinators (`range`, `map`, `filter`,
`fold`, `sum`, `length`) at typed-core level, behind `FPR_NO_LIST_FUSE`,
with `FusionSafety` effect-order evidence and per-decline remarks,
gated on zero-allocation fused pipelines (`list_sum/map/filter` allocs = 0)
and byte-identical output/trap behaviour against the unfused build, except
for `Core.FusionPolicy`'s documented Int-overflow relaxation (including the
`foldRange` endpoint edge). No representation change, no SIMD, no new
language surface.

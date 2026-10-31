# Zero and low overhead: the follow-up inventory

Date: 31 October 2026. Kind: destination framing and ranked follow-up
inventory, not an implementation or timing certificate. Base: main `1a09f01`
plus the direct-RV checked-arith change
([its record](2026-10-31-RV-CHECKED-ARITH-INLINE.md)). This complements
[the near-term plan](2026-10-31-PERFORMANCE-AND-PREDICTABILITY-NEXT.md):
that page fixes the optimization order for the current architecture; this
page states where the architecture itself is asked to move, so the language
becomes a zero or low overhead functional language. Where the two pages
overlap (loop facts, sharing, fuel batching) the near-term plan's detail
stands; the items below add the structural framing and the work past its
horizon.

## The destination: pay only for what you use

The design criterion is the C++ sense of zero-overhead abstraction applied
to a strict, statically typed functional language: an abstraction a program
does not use should cost nothing, and the abstractions it does use should
lower to what a systems programmer would have written by hand. Two kinds of
overhead count: per-operation and per-call runtime tax, and whole-program
cost that arrives whether or not the program asks for it (linked runtime,
entry obligations, representation).

What already qualifies is worth naming, because later items must not regress
it: known function values are static PAPs in rodata; saturated known calls
are direct register calls; tail calls are real jumps and self-tail-calls are
loops; vectors are flat unboxed columns with fused, SIMD-capable kernels;
proven checks are discharged by the difference-bound pass; the builtin
bare-metal profile links with `-Wl,--gc-sections` and no fuel or stack
checks. The follow-ups below are the remaining places where a program pays
for something it did not ask for.

## 1. RV checked arithmetic: landed, evidence outstanding

`OArith` on the direct RV selector now computes inline with the Int-domain
fit proof and re-enters the C primitive only on the slow path
(`compiler/Codegen/Target/RV.hs:155`, the shared `arith` helper; selection
revision 27). A64 and x86-64 already had this shape, so all three backends
now agree.

Outstanding, in order:

- Paired on/off runtime timing on workloads whose checked operations the
  interval pass cannot discharge (the byteloop and sha class). Static counts
  moved (fib 66 -> 72 segmax with the call now cold); runtime deltas are a
  hypothesis until measured, per [the change record](2026-10-31-RV-CHECKED-ARITH-INLINE.md).
- Physical-board timing on Tang Nano 20K (RV32 exercises the same path),
  including the `mulh` latency question on an in-order core.
- A code-size survey across `tests/tangnano20k_stress`: the fast path plus
  cold block adds roughly ten instructions per remaining checked site
  (lerp 58 -> 101).
- `OArithU` Mul/Div still call the primitive; reuse the fast path if the
  difference-bound pass ever widens past Add/Sub.
- The tagged-domain algebra (`(a-1) + b` makes word overflow coincide with
  Int overflow, [the fib gap record](2026-10-20-FIB-GAP-TO-C.md)) could
  shorten boundary sequences further.

## 2. Uniform representation: the zero-overhead endgame

Every value is one tagged word today: Ints are tagged at boundaries, every
non-nullary constructor is a heap node with a 16-byte preheader and tagged
fields (`runtime/fpr.h:8-16`), deep `==` is a C call, floats are boxed on
RV32. A scalar-only record costs heap words where C costs stack slots. This
is the structural distance between "competitive on vector kernels" and
"zero-overhead abstraction language".

The pieces exist but are not connected in the default profile: the typed IR
has representation types (`TInt`/`TRaw`/`TF64`/`TAddr`) and `LShape` layout
evidence; scalar workers give private unboxed conventions; and
`compiler/Representation.hs:3-4` performs whole-program representation
inference but only for the standalone ARC ABI, and "deliberately rejects
representation-polymorphic code until cloning is implemented".

Staged direction, ordered so each step is independently shippable and
cache-identity safe:

1. Unboxed scalar fields on constructors proven non-escaping (escape facts
   already exist from closure conversion).
2. Worker signatures, raw-word parameters, for public functions whose
   callers are all known at link granularity
   ([plan step 5.4](2026-10-26-PERFORMANCE-PLAN.md)).
3. Representation-aware cross-unit signatures, last, because it is an ABI
   change and must carry its own revision identity.

This is the multi-quarter item and the one that most deserves analysis
before commitment (see the open questions below).

## 3. The hosted entry tax is a policy coupling, not a cost

Stack check plus fuel tick is about ten instructions on every hosted entry,
and loop back edges additionally test region room. The policy is explicit:
"the hosted Base profile without fuel is not a supported policy"
(`compiler/Codegen/Policy.hs:81`). Measured cost on out-of-order cores is
small, but a single-actor program is structurally paying for preemptive
scheduling it cannot use. Two moves that keep the contract honest:

- Fuel batching in provably bounded loops, a register countdown charged at
  a bounded interval, preserving the documented maximum work between yields
  ([the near-term plan, section 4](2026-10-31-PERFORMANCE-AND-PREDICTABILITY-NEXT.md)).
- A first-class hosted single-actor profile where fuel checkpoints live at
  allocation and call boundaries, reusing the `Codegen.Bounds` safepoint
  machinery. This is not weaker safety; it is a different, explicit
  resource contract, in the spirit of the same plan's enforceable-contracts
  section.

## 4. Three one-off fast paths; the fourth should be a library

The guarded string scan is deliberately narrow, "one small loop per
function, one string, one unit-stride index" (`compiler/Codegen/StringScan.hs:15`);
the interval pass is difference-bounds only; `Simplify`'s sharing is
intra-block; matches on many variants compile to tag-test chains with no
jump tables; there is no cross-block GVN. The near-term plan already
targets caller-fact propagation and dominance-based sharing. The structural
addition: factor the recurring shape, establish entry facts with guards,
prove them on every back edge, keep the checked fallback, into one shared
guarded-versioning framework that string scans, vector reads, and
caller-supplied preconditions plug into. The same skeleton has now been
built three times; a fourth copy would be evidence the mechanism is missing.

## 5. The default data structures are the slow ones

A Cons cell is an `fpr_alloc` call, a preheader and two tagged fields per
node; `strcat` copies its accumulator, which is why `strJoin` exists
(`runtime/runtime.c:2959-2961`). There is vector fusion but no list fusion
at the typed-core level. Until representation work (item 2) lands:

- The inline bump-allocation fast path
  ([plan step 6](2026-10-26-PERFORMANCE-PLAN.md)), clobber-free with
  `fpr_alloc` only on refill, turns every constructor and Cons allocation
  from a call into about three instructions and helps every allocating
  loop.
- Whether list fusion at the typed-core level is worth building, versus
  steering libraries to `Vector`, is an open question (below).

## 6. Binary-level pay-for-use on hosted

Hosted builds link the full actor runtime and pthread harts for
hello-world, with no section garbage collection
(`compiler/Build.hs:186-235`); the builtin profile already links with
`-Wl,--gc-sections` (`Makefile:379`). A hosted build that strips unused
runtime sections, or a minimal single-hart hosted variant, is a cheap win
and the most visible "pay for what you use" claim for command-line tools
written in the language.

## Analysis still wanted

Each item above invites further analysis before implementation; the
highest-value questions, roughly ordered:

1. Residual checked-op density: across `std/` and the benchmark corpus,
   how many checked operations survive the interval pass per hot loop?
   This sizes item 1's remaining value and item 4's ordering.
2. Escape-analysis coverage: what fraction of constructed ADTs in real
   programs is provably non-escaping? This decides whether item 2 stage 1
   pays for itself before the harder stages.
3. Fuel and stack-check cost on in-order RV cores, where the ~2%
   out-of-order figure does not transfer; this sizes item 3.
4. List versus Vector usage in `std/` and examples: demand for list
   fusion, or evidence that steering to `Vector` suffices (item 5).
5. Code size versus speed on Tang Nano 20K: the item 1 fast path trades
   text for dynamic work; the board's BRAM budget sets the exchange rate.
6. A minimal hosted runtime's actual surface: which entries does a
   single-actor, non-networking CLI truly reach (item 6)?

## Suggested order

Item 1's evidence (paired timings, board, size survey) first, because the
change is already in the tree and unmeasured. Then item 5's allocation
fast path and item 6, both small and independently shippable. Item 3's
fuel batching follows the near-term plan's existing sequence. Item 4
should land opportunistically the next time a guarded fast path is written.
Item 2 proceeds only after its analysis questions are answered, stage by
stage, with each stage carrying its own cache identity and differential
evidence like every change in this tree.

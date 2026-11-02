# RawWord fields on a non-escaping Pair: the C2 link-tier experiment

Date: 2026-11-03. Status: experiment, no compiler change.
Check: `tests/check_pair_raw.py` (host-extra CI group, next to `check_raw.py`).

This is the second C2 prerequisite from the
[unboxing proposal](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md) (addendum C,
order item 2): force `RawWord` fields on one non-escaping type, the shape a
type specialiser would give `Pair Int Int`, through the existing
`Representation.hs` pipeline, with a differential oracle.

## Setup

`Representation.hs` only runs for `--arc` and raw units, that is the builtin
profile (`Arc.lowerArc`, `Arc.lowerRaw`), so the experiment runs there: RV64
bare-metal, QEMU, `ARC=1 ARC_CHECK=1`. Field kinds are inferred by unification
from how a constructor is used, so no compiler change is needed to force
`RawWord`: build the pair from `Word.fromInt` values and project with
`Word.toInt`/`Word.add`. Those two adapters (untag on construction, tag on
projection) are exactly what a specialiser would insert.

The oracle is the same program twice, once with Int fields and once with Word
fields, making identical observations: construct and project, a shared cell read
by two consumers, 50 pairs escaping into a `List`, `==` both ways, a 1000-step
loop returning a new pair every iteration, and `Mem.liveAllocations` unchanged
at the end (`tests/check_pair_raw.py` holds the template).

## Results

1. **The plumbing works end to end.** Output is byte-identical to the Int pair
   and nothing leaks (construction, sharing, escape into a list, structural
   equality, the ARC layout and release walkers).
2. **Raw fields are not owned.** Across `total`, `swap`, `build`, `tot`, `step`
   and `loop` the Word program has 100 retain/release call sites against 133.
   `step` alone: 123 -> 91 values, 51 -> 28 copies, frame 112 -> 96 bytes.
3. **The speed-up is small, because the cell is still allocated.**
   Instructions retired for 200 000 pair steps (`instret` under
   `-icount shift=0`, deterministic):

   | variant | instructions | per step |
   |---|---:|---:|
   | Int fields (control; mod written with `/`) | 1 580 307 075 | 7 902 |
   | Word fields behind `Word.fromInt`/`toInt` adapters | 1 547 506 946 | 7 737 |
   | all-Word step, counter and arithmetic (masked add, not like-for-like) | 1 523 506 917 | 7 617 |

   That is -2.1% for the adapter version. An isolated loop that only allocates
   and drops one two-field cell per iteration costs 3 670 instructions per cell
   (862.8 M against 128.2 M for the same loop without it); a plain Int loop is
   717-824 per iteration. I did not investigate why the builtin allocator
   (`machine/builtin/heap.fpr`) costs that much.
4. **Representation is global per type, and polymorphic use is refused.** A
   program that builds both an Int pair and a Word pair into one `List` stops
   with `automatic ARC: incompatible representations ... specialize the
   function or data type for each representation`. A shared polymorphic
   container can have one element representation only. This is the existing,
   deliberate refusal; it confirms that C2 needs cloning per instantiation and
   the deterministic per-definition choice of Decision 3, not more inference.
5. **Only the builtin tier has raw kinds.** In the hosted profiles
   `Word.fromInt` is not a lowered primitive (`fpr run` on a one-line Word
   program fails to link `fpr_g_Word.fromInt_call1`), so the hosted typed IR has
   no `RawWord` path. This matches the decision to start C2 on `builtin`.
6. Minor: `%` (`Int.mod`) is not a builtin ARC primitive, and printing an
   unknown ADT renders `<typeid.variant>`, with the type id depending on the
   program text, so the oracle compares projected values, not printed cells.

## What this tells the plan

Representation plumbing is not the risk. The kinds, layouts, ARC walkers and
refusal behaviour are sound. But raw fields alone buy 2-4%, since the dominant
cost is the allocation and release of the cell. The gain C2 is after (register
tuples, unboxed list cells) comes from not allocating the pair at all, which is
the other prerequisite: multi-register returns under `.abirev`. That should go
next, and the allocator's per-cell cost on `builtin` deserves its own look
before C2 on `builtin` is sized.

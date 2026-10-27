# Parked receive roots and shared post-linked analysis

Date: 2026-10-27. Code generation revision: 135.

## Receive-loop boundaries

The per-slab receive region could retain the messages processed since its
last cycle while its actor was parked. The old `autodrop3` assertion had
been relaxed to allow that retention. The assertion is now exactly zero
again, on one and four harts.

A checked receive-loop boundary now observes whether the next receive can
proceed. When it cannot, and the current scope owns received roots, the
existing cold region cycle copies the next live state and releases the
previous turn's roots before entering the receive. The slab threshold
still handles a busy mailbox. This uses the existing region/ARC protocol;
it adds no independent collector or runtime layout change.

`Core.Region.Receive` records the readiness evidence in the typed region
control structure. The verifier checks that evidence against the checked
body, including the physical parameter slot for a selective sender. The
ordinary runtime call `$receiveReady` uses the same mailbox predicates as
the receive operations. It does not take messages or evaluate a source
sender expression. Selective and Result receives consider matching work,
not merely whether any message is queued. A nonblocking poll does not
cause a park cycle. An effectful or unrecognized prefix conservatively
ends the previous turn at the checked boundary.

After a cycle there are no roots above the scope's receive mark, so the
boundary proceeds rather than cycling indefinitely. A receive in the
middle of an activation does not acquire a new boundary: values needed
later in that activation remain live. QOS process images keep their
existing receive trampoline and do not emit this helper.

The new `check_parked_receive.py` instruments a temporary copy of the
scheduler immediately before a blocked actor becomes available to other
harts. This observes an actual park without a sleep or a production test
hook. It resets its observation before each new message, exercises a
second same-slab message, and checks copied dynamic string state. The
baseline compiler fails with one retained root; the fixed compiler passes
72 executions: ordinary/selective/death-aware/Result receives, effectful
senders and a live mid-activation receive, with inlining on/off and one/four
harts. Seven target emission checks cover A64, x64, RV32, RV64 and the three
QOS targets.

Seven alternating paired million-message pingpong runs are recorded in
[the raw benchmark](../bench/2026-10-27-parked-receive.json). Under variable
heavy host load, same-hart medians were 244.3 to 247.8 ms, and cross-hart
medians were 586.7 to 614.3 ms. These samples establish no performance gain
or isolated regression; a quiet-machine performance comparison remains
separate from this retention fix.

## One cost snapshot after linking

Previously each artifact compared its optimized body with the earlier
whole-program context. A mismatch rebuilt the whole cost-equation map.
This happened before the assembly cache lookup, so warm builds repeated
the analysis too.

`Compiler.Native.Regions.placePrograms` now accepts the complete map of
post-linked artifact inputs. It checks their namespace/layout authority,
qualifies private compatibility auxiliaries once per artifact, rejects
conflicting visible definitions, and derives one shared cost snapshot.
All artifact placements consume that snapshot. Standalone/report callers
retain the existing changed-body fallback and cannot borrow stale costs
or interfaces. The analysis is scoped to one invocation; there is no
persistent analysis cache to invalidate.

The emitted, region-placed program still determines the assembly cache
key, together with calling arities, reset effects and the codegen revision.
A regression changes a root-provided callee from bounded arithmetic to
allocating recursion and back while leaving its imported caller unchanged.
It checks native results, the pending call-region decision, a new caller
cache entry, and reuse of the original entry on reversal. Contract tests
also compare the shared equations with an independent solve, distinguish
private helpers, and reject foreign authority or conflicting bodies.

The QOS shell (`programs/main.fpr`, QOS `d1a11db`) was compiled with the
before/after compilers, separate cold caches, and a fixed FP-RISC
`core/`/`std/` snapshot. Each warm run reused all 49 emitted dependency and
prelude artifacts. The figures below are one cold/warm pair per compiler,
with GHC 9.8.2 on Apple Silicon macOS; wall time is descriptive under host
load. CPU and allocation figures come from `+RTS -s`.

| Mode | Compiler CPU, before → after | Allocated, before → after | Peak residency, before → after |
| --- | --- | --- | --- |
| Cold | 42.51 → 39.07 s | 68.69 → 58.67 GB | 1,126 → 642 MB |
| Warm | 34.24 → 29.01 s | 54.05 → 44.03 GB | 1,126 → 290 MB |

Warm CPU fell 15.3%, allocation 18.5%, and peak residency 74.2% in this
sample. Root assembly size remained 1,017,337 bytes. The raw measurements,
compiler hashes and reproduction command are in
[the compile benchmark](../bench/2026-10-27-postlinked-analysis.json).
Substantial checking, linking and region placement work still precedes
warm emission cache hits; this change removes the repeated solve rather
than making the whole build incremental.

## Validation

Focused local checks cover `RegionInterfaces`, native unit/context/arity
and cost transitions, the resource-bound suite, the full automatic
receive-turn suite, reset/reuse barriers, strict `autodrop3`, retained
5,000-key state, Vector keeper state and nested call/loop regions. The
park regression is registered in Base. The compiler allocation budget also
passes for hello, std/live and POS1; POS1 peak residency fell 52.4% against
its existing baseline. Target emission is not a physical
ESP/RISC-V or QOS execution claim. Hosted CI was not run as part of this
change.

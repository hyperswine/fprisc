# Typed TRMC: the executed loops now lose their reverse pass

Date: 3 November 2026. Implementation based on `9ffd4d2`, codegen revision
150. This completes the hosted placement work in the
[typed TRMC design](2026-11-03-TYPED-IR-TRMC.md); builtin/ARC remains gated off.
No runtime ABI revision or source-language mutation operation is introduced.

## Implementation

`Core.Typed.Trmc` runs at the end of the linked typed pipeline, after List
fusion, both callback specialization rounds, inlining, normalization and vector
fusion. It sees the specialized private bodies that actually execute. The old
`Core.Opt.Trmc` module and its Core pipeline stage have been removed.
`FPR_NO_TRMC=1` still disables the feature; textual `--remarks=all` retains
`# trmc: loops=<n> appends=<n>` before cache reuse.

The pass recognizes accumulator/reverse loops and two-reverse append through
structurally verified checked helpers. A function named `reverse` or `revOnto`
is not authority. It handles parameter aliases, typed entry-tick sequences,
and the new-accumulator temporary introduced by specialization. That temporary
can sink into a call only across already evaluated local/literal arguments,
with exactly one use and no capture. Other shapes conservatively decline.

Arguments and callback work execute once, in their original order. An empty
accumulator starts a fresh forward-building chain; a nonempty accumulator keeps
the original reverse-based path. The first output cell enters a private worker
as both root and cursor. Each step allocates one fresh Cons/Nil, links the
cursor's tail to it, and tail-calls the same worker. Finishing attaches the
final tail, if any, and returns the root. Append uses the same protocol.

## Freshness is separate from payload ownership

The design's suggested `LShape` test was insufficient: `List Int` is
unrestricted and may be shared, while a list containing owned payloads does
not establish uniqueness of the list cells. The implementation instead adds
an internal `ListBuilder` marker and `SetField` node, checked by
`Core.Typed.TrmcProof`, the ordinary typed verifier, and the closed-graph
verifier before erasure:

- A builder is a private, capture-free entry; it cannot be imported or turned
  into a closure/global/join reference.
- Every external entry supplies the same freshly allocated Cons/Nil as root
  and cursor. Other arguments cannot contain that cell.
- Root/cursor cannot be inspected, aliased through an ordinary binding,
  passed to callbacks, or exposed through other recursive arguments.
- A step must allocate a fresh cell, store to field 1 of the cursor and
  immediately tail-call the same worker with the old root and new cursor.
- Self calls are allowed only at verified tail transitions; a nested call
  cannot grant mutation authority over another shared root/cursor pair.
- A finishing store must immediately return the root. Returning the cursor,
  mutating another field, using a shared argument as a cursor, or storing
  outside the protocol is rejected.

The store erases to the existing `$trmc.setTail` / `OSetField 1` backend form.
The worker retains the normal stack check and fuel safepoint on its loop entry.
There is no assumption that a faster traversal preserves the old total fuel
consumption or total time to finish.

Region interfaces give builders an explicit provenance. They cannot acquire
an independent loop/call region: root and cursor alias the unfinished chain,
so copying them as separate loop state would destroy the link invariant.
Ordinary calls and surrounding source functions retain their region planning.
Loops reaching known receive or explicit-region operations are declined,
including indirect calls and referenced callback bodies, so TRMC cannot remove
their existing per-turn reclamation. Opaque callbacks remain opaque to both
this check and region planning.
Builtin/ARC needs a separate retain/release and ownership-transfer proof before
this pass can run there; RV32 remains outside this 64-bit slice.

## Allocation gates

List fusion and automatic loop/call regions are disabled for these isolated
allocation measurements, using 1,000 input elements. All three compiler
configurations (default, `FPR_NO_INLINE=1`, `FPR_NO_SPEC=1`) must meet the exact
ratchets in `tests/check_trmc.py`:

| Workload | TRMC disabled | Typed TRMC |
| --- | ---: | ---: |
| map | 3,000 | 2,000 |
| filter retaining half | 2,000 | 1,500 |
| append 1,000 + 500 elements | 3,500 | 2,500 |

The captured-callback case retains one additional PAP in both variants when
specialization is disabled; the saving remains exactly 1,000 cells.
`check_list_fusion.py` now accepts only the intended exact baselines, rather
than allowing either the optimized or missed-specialization allocation count.
Fused scalar pipelines must still allocate zero.

## Validation and remaining qualification

The accompanying tests cover original and specialized worker creation,
fresh/shared entry, pointer escape, invalid stores, helper identity, erasure,
argument order, printing before division/overflow, nonempty/shared accumulators,
and opt-out behavior. Region-interface tests require builder bodies to survive
region planning unchanged. A native differential repeats 1,000 materialized
maps of 1,000 elements under a 16 MiB heap on one/four harts, with fusion off
and ordinary regions enabled. `TypedTrmc` is included in the Base typed-core driver.
The native differential checks compile for A64, x64 and RV64; assembly emission
on those targets is distinct from executing on each target.

The reproducible timing driver is `tests/bench/trmc/measure.py`. It validates
every output, alternates TRMC on/off runs, records every sample and binary size,
and separates cold/warm compilation from execution. List fusion is off to keep
materialized-list costs visible; region planning otherwise uses its defaults.
These throughput measurements do not qualify scheduling latency or QOS boards.

The initial [200,000-element paired run](../bench/2026-11-03-typed-trmc.json)
used 11 samples per variant and includes process startup:

| Workload | Default speedup | No specialization | No inlining |
| --- | ---: | ---: | ---: |
| map | 1.177x | 1.206x | 1.292x |
| filter | 1.048x | 1.136x | 1.047x |
| append | 1.243x | 1.185x | 1.227x |

These are ratios of medians from this local macOS arm64 run, not timing
thresholds. Executables grow by 17.7–18.3 KB (about 3.2%); private workers
coexist with general entries and their nonempty-accumulator fallback.
Cold/warm build times and every runtime sample are retained in the JSON.

The Base attempts exposed existing failures in `check_mvu_reload.py`
(`tests/base/mvuportmemory.fpr`) and `check_receive_turns.py`
(`tests/base/mvueventports.fpr`): `send: target is not an actor`, followed by
deadlock or an event-port panic. Both fixtures fail with typed TRMC enabled,
with `FPR_NO_TRMC=1`, and in fresh detached builds of unchanged `9ffd4d2`,
using separate caches. Reproduction: build either fixture with `--harts 4`,
then run with `FPR_HARTS=1 FPR_HEAP_MB=64`. These prevent claiming a fully
green Base run; they are separate actor/MVU follow-ups.

Other unchanged-HEAD failures found during that run:

- `check_reuse.py` and `check_consuming_reuse.py` expect 20,000 allocations
  with reuse disabled but observe 10,000, with correct values. Both failures
  reproduce with TRMC disabled and on `9ffd4d2`. Both complete suites pass
  with `FPR_NO_PAIR_RETURNS=1`: their allocation probes need to isolate reuse
  from the separately enabled pair-return optimization.
- `panic_actors_std` expects `deliberate` on stdout; unchanged HEAD and
  TRMC-disabled builds exit 1 and report it on stderr.
- `vecpeek` expects 96,096 bytes in its vector-read rollback case but observes
  96,048, with identical values. This also reproduces with TRMC disabled and
  on unchanged HEAD.

Across [resumed Base runs](../bench/2026-11-03-typed-trmc-validation.json),
164 of 170 registered jobs pass; the six failures above remain. The sections
after the failing MVU/receive fixtures pass separately, as do the panic test's
remaining actor/std cases with the diagnostic checked on stderr. These local
results are not a green CI or release claim. Focused TRMC, strict List fusion,
typed freshness/erasure/region units, raw and pair-raw checks pass.

The [final compiler-cost measurements](../bench/2026-11-03-typed-trmc-compile.json)
use fresh caches and GHC RTS statistics. Enabling the pass costs 1.7%, 3.7%
and 4.0% additional compiler allocation on hello, std-live and pos1. Including
the verification changes common to on/off builds, allocations are 5.0%, 6.7%
and 7.0% above the repository's recorded baselines; all allocation and peak-live
budgets pass. Wall times in that artifact are informational and were collected
alongside regression jobs. `check_compile_budget.py --tracked` also passes its
report-only vecwide frontend probe (36,521,312 bytes allocated; 4.7 seconds);
that frontend-only probe does not measure TRMC itself.

The final [1,000,000-element run](../bench/2026-11-03-typed-trmc-million.json)
uses the same 11 alternating pairs, with regression jobs stopped during the
measurement. It confirms improvements in all nine medians:

| Workload | Default speedup | No specialization | No inlining |
| --- | ---: | ---: | ---: |
| map | 1.312x | 1.325x | 1.440x |
| filter | 1.239x | 1.186x | 1.258x |
| append | 1.296x | 1.279x | 1.414x |

These comparisons enable/disable TRMC in the new compiler. The migration's
new gain is reaching default specialized map/filter loops; append already
benefited from the old pass and retains that benefit. This is selective
removal of a reverse traversal and its allocation, not a claim that returned
lists need no allocation. Builtin/ARC ownership transfer, RV32 execution,
board qualification, scheduling latency and reducing private-worker code
growth remain separate work.

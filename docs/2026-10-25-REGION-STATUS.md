# Cost-sized region status and remaining work

Date: 2026-10-25. Kind: source audit and next-step register. Applies to `97d6ad7`
and the accompanying Core pipeline refactor. The runtime is unchanged by that
refactor. This checks [the cost-sized regions proposal](2026-10-23-COST-SIZED-REGIONS.md)
against current source; it does not claim that proposal has shipped.

## Sync update: main at `0f6df38`

The audit below was made at `97d6ad7`. Main advanced during the cleanup;
its conclusions are historical and are superseded here where noted.

- [Stage 0](2026-10-24-REGIONS-STAGE0.md) now records state-copy and turn
  allocation measurements, including logbook/store scaling.
- [Stage 1](2026-10-24-REGIONS-STAGE1.md) retires compiler `autoDrop` and
  attaches received roots to runtime scope boundaries and actor cleanup.
  The service/task paths no longer need their previous manual keeps.
- [Stage 2](2026-10-24-REGIONS-STAGE2.md) adds self-tail boundaries and
  invariant/function-state handling. Owned Vectors now cross compiler regions
  by handle; their storage belongs to the actor base pool.
- [Loop/call regions](2026-10-25-REGIONS-LOOPS-CALLS.md) are on by default,
  with an inline `ORegionRoom` allocation-clock check and lazy pending call
  regions. Large-result regions can hand over memory. The Tang Nano
  conservative collector is removed; its heap now supports regions.

The remaining model work is generational state copy-out and Dynamic
shrink/compaction policies, proof-sized Static admission, frozen sharing,
and the documented nested-scope case: loops that explicitly manage their own
arenas currently decline loop-region placement. Precise ownership/type evidence
and non-tail live-stack cases still require explicit treatment.

The older QOS inventory below is also a pre-sync snapshot. Its before/after
comparison proves the first cleanup did not change that old compiler's
behavior; it does not establish coverage for the newly integrated region passes.
The reporter's stdout/stderr interleaving defect is independent of those passes.

## Historical audit at `97d6ad7`

Actor pools, explicit `Sys.arena`, `Sys.loop`/`loopWith`, recognized receive-turn
regions and constructor reuse already exist. The unified cost-sized region
model remains proposed. The gaps below concern that migration, rather than a
claim that every existing program leaks or has unsafe ownership.

| Outstanding work | Current evidence and consequence | Acceptance needed |
|---|---|---|
| Baseline measurements (proposal stage 0) | No recorded unified-model scaling result yet. Existing transfer-copy code sizes and copies the complete value. Large persistent state may dominate a turn even when scratch reclamation is cheap. | Dated copy cost/model size and state/scratch allocation results for logbook, swarm and representative Base/QOS actors. |
| General boundary placement | `ReceiveTurns.transform` recognizes checked tail-recursive receive SCCs; it refuses explicit-region groups, missing state type evidence, mutable/functional/polymorphic state and non-tail/escaping recursion. Pure tail loops and alloc-heavy calls do not have general cost-chosen regions. QOS Main still skips published generic awaitReply, serve, endpoint callbacks and compatibility groups for lack of checked ownership evidence. | Report boundary decisions/refusals, then flat resident memory over 10,000 swarm ticks and the RV32 dtree case under 8 MiB without conservative GC. |
| Message lifetime integration | `autoDrop` and explicit `keep`/`drop` still implement existing ownership. `examples/service.fpr` and `std/task.fpr` retain copied message values explicitly. | Deadmail/autodrop/receive-turn regressions with `arc_live = 0`, identical service/task results after removing the relevant manual operations. |
| Generational state and dynamic policies | `runtime.c:transfer_copy` calls `dc_size` then `dc_dup` into a transfer slab. There is no stop-at-existing-state copy-out with shrink/compaction policies. | Copy work proportional to changed state; service Put scaling from 1,000 to 100,000 keys and large-model frame scaling. Bound/report compaction pauses and high-water storage. |
| Proven region sizes and admission | `CostEq.ceLive` remains conservative allocation except at known arena/loop boundaries. Explicit `spawnHeap` exists, but `arena_open` refuses scratch arenas for fixed-heap actors because they require separate admission. This is not proof-derived admission for nested regions. | Region live/result-size proofs, total peak accounting across mailbox/state/scratch/copy/compaction, proven Static ponger and named strict-build refusal of unbounded regions. |
| Linear resources across boundaries | `has_vec`/`no_vec_out` and the transfer copier preserve current Vector escape restrictions. The proposed general move-out contract has not replaced these checks. | Explicit owners/moves for vectors and other linear resources, including failure/actor-exit cleanup and cross-hart execution; keep current rejection until replacement semantics are checked. |
| Frozen shared regions | `sendArc` still uses the existing ARC ownership machinery. Frozen-region sharing has not replaced the per-value table. | Freeze without unnecessary recopying, last-release cleanup and four-hart sharing benchmarks against the existing ARC baseline. |

The hard design questions remain those in the proposal: receives with live stack
frames, when call-local scratch saves more than its bookkeeping/copy overhead,
how dynamic state compacts, and how much static admission can prove. A copy-based
value contract simplifies lifetime safety but does not settle those performance
and admission questions.

## Fresh QOS Main inventory

A qa64 emission of current QOS `c507991` with `FPR_RECEIVE_NOTES=1` reports
**11 automatic, 44 explicit-region and 12 skipped groups**. These are static
recursive groups in the dependency closure, not actor counts or a residency
measurement. They match the saved pre-refactor compiler at `97d6ad7` exactly.
Main's assembly and all 49 dependent unit assemblies also match byte for byte.
This check uses the working compiler, rather than QOS's pinned compiler.

One required coverage expectation is genuinely unmet: `fileServe`'s group
contains `fileMsg`/`fileTimed` state parameters of opaque endpoint type
`Ep@c66ad65e68dd97f5`; the pass does not have checked ownership evidence to
permit that state. Generic awaitReply/awaitReplyUntil, serve, endpoint callbacks,
namespace/directory and other state/result groups also remain skipped.
This is an existing gap, not a consequence of splitting the Core modules.

There is a separate reporting defect: `tools/receive-coverage.py` merges stdout
and stderr, then recognizes only lines beginning `receive-turns:`. Backend
stdout and diagnostic stderr can interleave within a line; the stock check
then falsely reports `openAwait`, `trLoop` and `meshes` as missing, and undercounts
other groups. The counts above were parsed from separately captured stderr and
compared before/after. Fix the inventory's channel capture before using its
counts as a promotion gate; do not relax the real `fileServe` expectation.
Raw local evidence is in `/private/tmp/fpr-region-audit/{before,after}-separate/`.
No QOS source, compiler pin or runtime was changed, and no app was launched.

## Recommended order

Start with the stage-0 measurements and an analysis-only region plan. Preserve
source types and binder identity through the compiler first, then attach costs,
state ownership and boundary decisions to explicit stage results. Report why a
boundary is selected or declined before introducing new runtime allocation.

Implement lifetime integration and generational state in separate measured
steps, then proof-sized admission and frozen sharing. `autoDrop`, manual
`keep`/`drop`, the ARC table and the conservative RV32 collector must remain
until their replacement acceptance checks pass. There is no evidence here to
justify deleting them as an architectural cleanup.

The separate QOS checkout is `c507991` and was not modified. Its current
[receive-turn coverage register](https://github.com/hyperswine/qos/blob/c507991/docs/2026-10-12-RECEIVE-TURN-COVERAGE.md)
still lists those generic groups.

Sources checked: `compiler/ReceiveTurns.hs`, `compiler/Cost.hs`,
`runtime/runtime.c` (arena, Vector escape and transfer-copy paths),
`runtime/actors.c` (`spawnHeap`), `examples/service.fpr`, `std/task.fpr`,
[resource bounds](2026-10-02-RESOURCE-BOUNDS.md) and the cost-sized-region
proposal's open problems and staged acceptance table.

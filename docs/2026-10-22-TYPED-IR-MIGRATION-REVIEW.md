# Review of the typed-IR migration branch before merge

Date: 2026-10-22. Kind: review and merge record.
Reviewed: `codex/typed-ir-migration-20261022` at `4148636` against main
`0c9c8b7`; record of the branch's work:
[TYPED-IR-MIGRATION](2026-10-22-TYPED-IR-MIGRATION.md).

The last merge in this project produced an allocator defect that neither
branch showed alone ([MERGE-REGRESSIONS](2026-10-22-MERGE-REGRESSIONS.md)),
so the review looked for that class first.

## Findings

- **No defect found.** Each item below was checked against the code.
- **RISC-V spill-cell store.** `store.spill` reads the hart pointer into
  `t3` before it reads the value it stores, the early-write shape behind
  the merge's A64 and x86-64 fault. It is safe here: the RISC-V pools are
  `s1..s11`, `a0..a7` and the scratch `t0..t2`; `t3`, `t4` and `t6` are in
  none, so the stored value can never be in them. `acEarlyDef = const
  False` is therefore correct for this target.
- **RISC-V callee-saved budget.** `s1..s11` is the budget. Every RISC-V
  context switch preserves `s0..s11`: `machine/unix/ctx_rv64.S`,
  `machine/virt/ctx.S`, `machine/esp-idf/ctx.S`.
- **Aggregates.** Constructor selection is the legacy sequence (size,
  `fpr_alloc`, the two header words, the fields in order). Field values
  live across the allocation call under the allocator's call-crossing
  rule; Base objects do not move.
- **Vector-kernel decline.** The scan in `nativeSelect` uses the legacy
  generator's own gate (`vecSpec` with the same fusion, word-size and
  float conditions) over every expression form that can contain a site,
  per emitted unit, so imported units are covered.
- **Fresh-constructor reuse.** The legacy emitter's in-place reuse
  (`$reuse.fresh`) is not lowered; functions that use it are declined by
  name (`the primitive $reuse.fresh`) and keep the legacy reuse.
  `tests/check_reuse.py` with `FPR_TYPED_IR_BACKEND=mixed` still counts
  10,000 allocations with reuse on and 20,000 with it off. Lowering reuse
  is a coverage item, not a regression.

## Legacy emission unchanged

With every typed-IR switch off, the branch compiler's output was compared
with main's (`0c9c8b7`): 75 root assemblies (the 12 bench programs,
`freshreuse`, `intovf`; targets a64, a64mac, x64, rv64, rv32) and 45 cached
unit assemblies (`sha` and `pingpong` on a64, x64, rv64, rv32). All are
byte-identical. `codegenRev` stays 67.

## Validation at `4148636` (this Mac, arm64)

| Check | Result |
|---|---|
| `check_typed_ir.py` | PASS (22/22 on a64/x64/rv64) |
| `check_typed_ir_a64.py` | PASS |
| `check_typed_ir_aggregates.py` | PASS (legacy, typed, entry; 1 and 4 harts) |
| `check_typed_ir_coverage.py` | PASS (floats, vector-kernel decline) |
| `check_typed_ir_rv.py` | PASS (4,724 results each loop mode) |
| `check_registers.py`, `check_self_loops.py`, `check_workers.py` | PASS |
| `check_x64_local.py --require-execution` (Rosetta) | PASS |
| `check_base.py` | 105 jobs, exit 0 |
| `check_reuse.py` with the backend on | PASS |
| Branch CI [39643980140](https://github.com/hyperswine/fprisc/actions/runs/39643980140) | success |

Not run here: native Linux (CI's leg), physical boards, QOS. QOS needs no
re-pin for this merge: legacy emission and the runtime are unchanged.

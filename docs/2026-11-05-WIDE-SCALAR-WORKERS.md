# Wide scalar workers in hosted Base

An eligible scalar loop can now use the complete native argument frame. Codegen 196 uses `Codegen.IR.arityCeiling` for scalar admission and field-worker expansion. That is the same 64-word limit enforced during lowering and verification. Previously the scalar pass declined every source above eight arguments. This also prevented an otherwise eligible flattened tuple loop from acquiring a raw scalar worker.

The worker uses the existing private convention. ARM64 and RV64 take the first eight words in argument registers. x86-64 takes six in registers and two in its dedicated argument cells. Positions 9–64 use the hart's 56 spill cells. The entry must move these incoming words into its own frame before a fuel reset permits another actor to reuse the cells. Public calls retain ordinary tagged arguments, validate integer and Boolean representations, and use the original body when the guard declines.

## Boundary and fuel checks

The native regression rotates mixed raw integers and Booleans through argument positions at widths 6, 7, 8, 9, 16, 63 and 64. Independent weighted sums expose lost or reordered lanes. Direct calls, opaque function values, a malformed declared integer on an unused path, a foreign noncanonical Boolean, and the print effects before overflow all agree with the scalar rollback. Three actors keep distinct values across actual fuel exhaustion. ARM64 and x86-64 execute on one and four workers. Separately built modules and callers with opposite optimization settings use the tagged 64-argument public entry. A Core regression verifies refusal at argument 65. The saved codegen-195 compiler emits scalar workers only for widths 6–8 on this fixture.

The independent RV64 QEMU executable links the real narrow caller, public entry, private worker and emitted fuel-save wrapper for all seven widths. It computes 3,591 expected results in C. At each fuel reset the shim overwrites all 56 argument spill cells and all volatile argument and temporary registers. Each result and both hart guard words survive. Unexpected generic arithmetic slow paths fail the oracle.

## Tuple accumulator benchmark

One million iterations rotate mixed integer and Boolean tuple fields and increment every integer lane. The explicit source passes the same fields as separate arguments. A weighted sum checks every lane. The benchmark inspects each plain executable's retained compiler output to verify the actual private worker selection. All four forms made **zero allocation requests**. The existing field worker already removed the tuple allocations. Codegen 196 additionally carries the scalar arguments through that worker's loop.

| Total arguments | Saved codegen 195 | Codegen 196 | Explicit arguments | Scalar rollback |
| ---: | ---: | ---: | ---: | ---: |
| 9 | 6.55 ms | 6.22 ms | 5.88 ms | 6.46 ms |
| 16 | 8.56 ms | 7.69 ms | 7.74 ms | 8.58 ms |
| 64 | 35.36 ms | 26.20 ms | 26.71 ms | 35.59 ms |

The new tuple form won 13/13 paired native ARM64 samples against the saved compiler at each width. At 64 arguments the additional guarded and raw worker code increased root RV64 text **33,584 → 53,312 bytes**. The explicit form occupied 37,244 bytes. Cold compiler allocation for the tuple form increased **2.14 → 2.93 GB**. These costs and the uninstrumented sample series are in the [benchmark record](../bench/2026-11-05-wide-scalar-throughput.json).

All 41 Haskell suites and the unchanged absolute compiler gates passed. The [host scheduling matrix](../bench/2026-11-05-wide-scalar-scheduling.json) covers 225 configurations and 172,800 ordinary replies. It records 115 replies above 1 ms overall and a maximum of 2.380 ms. The 64-argument scalar workload recorded zero above 1 ms with the worker enabled and one on rollback. The physical Pi matrix remains the separately recorded codegen-193 run. The [validation manifest](../bench/2026-11-05-wide-scalar-validation.json) links the exact compiler, backend evidence and regression checks.

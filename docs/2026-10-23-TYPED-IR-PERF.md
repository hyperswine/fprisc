# Typed IR performance pass: float trees

Date: 2026-10-23. Kind: implementation and measurement record.
Base: main after [typed QOS RISC-V apps](2026-10-23-TYPED-QRV64.md). Branch `typed-ir-retire`.

With every hosted path on the typed backend, the first performance pass
goes after the one thing the kernel pages left measured as a cost: F64
values travel as bits in integer registers, so every inline F64 operation
moved its operands into the floating-point unit and its result back out
(`fmov d16, x; fmov d17, y; fadd d16, d16, d17; fmov x, d16`): four
instructions for one. nbody's `step` is eleven such operations per
iteration.

## Float trees

A new simplifier pass, `fuse-float-trees`, runs after
`share-pure-in-block`. Within a block it folds a chain of F64 operations
whose intermediate results are used exactly once into one operation,
`OFloatTree`, over a tree (`FloatTree`: leaves are the chain's inputs, nodes
its operations). The target evaluates the tree in its scratch
floating-point registers with one move in per leaf and one move out:

| Target | Scratch | A node |
|---|---|---|
| A64 | `d16..d23` | `fadd dn, dn, dn+1` |
| x86-64 | `%xmm8..%xmm15` | `addsd %xmm(n+1), %xmm(n)` |
| RV64 | `ft0..ft7` | `fadd.d ftn, ftn, ftn+1` |

A node computes its left subtree in register n and its right in n+1, so a
tree needs `ftreeRegisters` of the eight (`max (regs left) (1 + regs
right)`); the verifier refuses a bigger tree and the pass never builds one
(the chain stays apart at that point). A result used twice, or used in
another block, keeps its own definition: only single uses in the same
block fold. The operations are pure and the leaves are defined before the
chain's first operation, so folding a definition into its later consumer
changes no value and no order; the evaluator-equivalence check in
`TypedIR.hs` covers the pass like the others (floats are opaque to the
evaluator, so the check is that nothing else changes), and the C-reference
checks (`check_float_inline.py`: 400 edge pairs on A64, 1,280 under
Rosetta; `check_typed_ir_coverage.py`'s float V ABI) cover the values.

nbody's `step` has six trees, among them
`v3 + ((v16 - (v1 / v15)) * v22)`; its `fmov` count fell from 57 to 33.
Comparisons (`OFloatCmp`) do not take tree operands yet, so floatcmp's
chains of compare-after-arithmetic are unchanged.

## Measurement

The driver gained `--against`: a second compiler binary measured in the
same rounds as the variant `baseline`, so a change to the compiler is
measured the way the legacy comparisons were. Apple M4, one hart, 31
alternating paired rounds, every output checked; the baseline is the
compiler before this pass, `typed-ir` the compiler with it
([summary](evidence/2026-10-23-typed-ir-perf/paired-summary.md),
[raw](evidence/2026-10-23-typed-ir-perf/paired-results.json)):

| Workload | Timer | Baseline ms | Float trees ms | Median paired ratio | 95% interval | Faster pairs |
|---|---|---:|---:|---:|---|---:|
| nbody | wall | 396.5 | 259.1 | **0.6547** | 0.6532..0.6555 | 31/31 |
| sha | wall | 125.3 | 124.7 | 0.9899 | 0.9788..0.9995 | 21/31 |
| floatcmp | wall | 42.2 | 41.7 | 0.9940 | 0.9724..1.0008 | 20/31 |
| pipeline | internal | 2.584 | 2.605 | 0.9977 | 0.9783..1.0140 | 16/31 |
| records | internal | 8.995 | 8.965 | 0.9994 | 0.9915..1.0052 | 16/31 |
| sum | internal | 10.394 | 10.395 | 1.0009 | 0.9956..1.0026 | 14/31 |
| helpers | wall | 106.9 | 106.9 | 1.0003 | 0.9976..1.0048 | 14/31 |
| fib | internal | 54.27 | 54.41 | 1.0108 | 0.9862..1.0176 | 13/31 |

nbody runs in two thirds of the time; nothing else moved outside its
interval (fib's interval includes 1; an earlier unpaired comparison of two
separate sessions had shown fib 5% slower, which is why the paired form was
added to the driver rather than trusted). The legacy generator's nbody was
0.896 of legacy-best before this pass (the kernels page); against that
historical number the typed backend is now at about 0.59.

This is one host and one hart; x86-64 and RISC-V trees are checked for
values (Rosetta's 1,280 pairs, the kernel oracles' mixed Int/F64 records
under QEMU) but not timed.

## What else was looked at

- The record filter's compaction loop reloads a column's directory entry
  and base for every column of every moved row, as the legacy loop did,
  and carries a safepoint per column copy that the legacy loop did not
  (the width is dynamic, so the typed loop keeps every cycle bounded). The
  `records` benchmark keeps 99.96% of its rows in place, so neither cost
  is on its path; a workload that drops most rows would measure it.
- The earlier pipeline gap against legacy-best closed when the kernels
  went typed (the kernel pages); nothing to chase there.

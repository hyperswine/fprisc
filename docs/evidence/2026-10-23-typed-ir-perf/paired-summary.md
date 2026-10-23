# M3 paired measurements

revision d20d5972ddf155745417e814ebd6b83bdbfffc93, compiler sha256 a97de3131832, macOS-27.0.1-arm64-arm-64bit-Mach-O
31 rounds; internal timers: fib, sum, pipeline, records; process wall: helpers, sha, floatcmp, nbody

## typed-ir against baseline

| workload | timer | baseline median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 54.274 | 54.409 | 1.0108 | 0.9862..1.0176 | 13/31 |
| fib | wall | 59.853 | 60.325 | 1.0099 | 0.9883..1.0148 | 12/31 |
| sum | internal | 10.394 | 10.395 | 1.0009 | 0.9956..1.0026 | 14/31 |
| sum | wall | 15.555 | 15.598 | 1.0046 | 0.9909..1.0166 | 15/31 |
| pipeline | internal | 2.584 | 2.605 | 0.9977 | 0.9783..1.0140 | 16/31 |
| pipeline | wall | 11.239 | 11.265 | 0.9941 | 0.9705..1.0148 | 17/31 |
| records | internal | 8.995 | 8.965 | 0.9994 | 0.9915..1.0052 | 16/31 |
| records | wall | 17.888 | 17.894 | 0.9897 | 0.9785..1.0176 | 17/31 |
| helpers | wall | 106.907 | 106.928 | 1.0003 | 0.9976..1.0048 | 14/31 |
| sha | wall | 125.251 | 124.685 | 0.9899 | 0.9788..0.9995 | 21/31 |
| floatcmp | wall | 42.183 | 41.697 | 0.9940 | 0.9724..1.0008 | 20/31 |
| nbody | wall | 396.491 | 259.052 | 0.6547 | 0.6532..0.6555 | 31/31 |

## Builds

| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |
|---|---:|---:|---:|---:|---:|---:|
| fib-baseline | 0.54 | 89.2 | 450848 | 294912 | 3 | 0 |
| sum-baseline | 0.53 | 89.2 | 450848 | 294912 | 3 | 0 |
| pipeline-baseline | 0.52 | 90.3 | 451840 | 294912 | 8 | 0 |
| records-baseline | 0.63 | 90.3 | 470640 | 311296 | 36 | 0 |
| helpers-baseline | 0.52 | 89.2 | 451008 | 294912 | 7 | 0 |
| sha-baseline | 2.83 | 146.6 | 749344 | 442368 | 1 | 0 |
| floatcmp-baseline | 0.52 | 89.3 | 450464 | 294912 | 2 | 0 |
| nbody-baseline | 0.52 | 89.3 | 450464 | 294912 | 2 | 0 |
| fib-typed-ir | 0.53 | 89.2 | 450848 | 294912 | 3 | 0 |
| sum-typed-ir | 0.55 | 89.2 | 450848 | 294912 | 3 | 0 |
| pipeline-typed-ir | 0.54 | 90.3 | 451840 | 294912 | 8 | 0 |
| records-typed-ir | 0.64 | 94.3 | 470640 | 311296 | 36 | 0 |
| helpers-typed-ir | 0.52 | 89.2 | 451008 | 294912 | 7 | 0 |
| sha-typed-ir | 2.85 | 147.5 | 749344 | 442368 | 1 | 0 |
| floatcmp-typed-ir | 0.53 | 89.3 | 450464 | 294912 | 2 | 0 |
| nbody-typed-ir | 0.53 | 89.3 | 450464 | 294912 | 2 | 0 |

## Coverage under the backend (root unit)

- fib-baseline: $worker.scalar.fib, fib, main
- sum-baseline: $worker.scalar.loop, loop, main
- pipeline-baseline: above, inc, main, weighted, $vkernel:fpr_tkfn_above, $vkernel:fpr_tkfn_inc, $vkernel:fpr_tkfn_weighted, $vkernel:fpr_vspec_pipeline_x40PipePlan_x20_x7bpipeStages_x20_x3d_x20_x5b_x28_x22map_x22_x2c_x22inc_x22_x2c_x5b_x5d_x29_x2c_x28_x22filter_x22_x2c_x22above_x22_x2c_x5b_x5d_x29_x2c_x28_x22fold_x22_x2c_x22weighted_x22_x2c_x5b_x5d_x29_x5d_x2c_x20pipeElement_x20_x3d_x20KI_x2c_x20pipeAccumulator_x20_x3d_x20Just_x20_x280_x2cKI_x29_x7d_inc
- records-baseline: capture, fill, keepRecord, main, probeRecordCaptured, probeRecordFilter, probeRecordFold, probeRecordMap, rotate, sampleRow, step, total, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5ffold_x5fstep, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f0, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f1, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f2, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f3, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f4, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f5, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f6, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f7, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f8, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f0, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f1, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f2, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f3, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f4, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f5, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f6, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f7, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f8, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5frfilter_x5fkeepRecord, $vkernel:fpr_vspec_fold_step, $vkernel:fpr_vspec_mvmap_capture, $vkernel:fpr_vspec_mvmap_rotate, $vkernel:fpr_vspec_rfilter_keepRecord
- helpers-baseline: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-baseline: main
- floatcmp-baseline: loop, main
- nbody-baseline: main, step
- fib-typed-ir: $worker.scalar.fib, fib, main
- sum-typed-ir: $worker.scalar.loop, loop, main
- pipeline-typed-ir: above, inc, main, weighted, $vkernel:fpr_tkfn_above, $vkernel:fpr_tkfn_inc, $vkernel:fpr_tkfn_weighted, $vkernel:fpr_vspec_pipeline_x40PipePlan_x20_x7bpipeStages_x20_x3d_x20_x5b_x28_x22map_x22_x2c_x22inc_x22_x2c_x5b_x5d_x29_x2c_x28_x22filter_x22_x2c_x22above_x22_x2c_x5b_x5d_x29_x2c_x28_x22fold_x22_x2c_x22weighted_x22_x2c_x5b_x5d_x29_x5d_x2c_x20pipeElement_x20_x3d_x20KI_x2c_x20pipeAccumulator_x20_x3d_x20Just_x20_x280_x2cKI_x29_x7d_inc
- records-typed-ir: capture, fill, keepRecord, main, probeRecordCaptured, probeRecordFilter, probeRecordFold, probeRecordMap, rotate, sampleRow, step, total, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5ffold_x5fstep, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f0, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f1, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f2, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f3, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f4, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f5, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f6, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f7, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f8, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f0, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f1, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f2, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f3, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f4, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f5, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f6, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f7, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f8, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5frfilter_x5fkeepRecord, $vkernel:fpr_vspec_fold_step, $vkernel:fpr_vspec_mvmap_capture, $vkernel:fpr_vspec_mvmap_rotate, $vkernel:fpr_vspec_rfilter_keepRecord
- helpers-typed-ir: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-typed-ir: main
- floatcmp-typed-ir: loop, main
- nbody-typed-ir: main, step

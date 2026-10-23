# M3 paired measurements

revision 98abc0c7d790ae1e90faa6a6a6639739d702a0d1, compiler sha256 bc354a9b7442, macOS-27.0.1-arm64-arm-64bit-Mach-O
31 rounds; internal timers: fib, sum, pipeline, records, cmpchain64, f32trees, simdintmap, simdf64map; process wall: helpers, sha, floatcmp, nbody

## typed-ir against baseline

| workload | timer | baseline median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| simdintmap | internal | 1.538 | 0.660 | 0.4284 | 0.4274..0.4305 | 31/31 |
| simdintmap | wall | 11.166 | 10.237 | 0.9162 | 0.9005..0.9263 | 31/31 |
| simdf64map | internal | 1.617 | 0.649 | 0.4010 | 0.3973..0.4050 | 31/31 |
| simdf64map | wall | 13.886 | 12.891 | 0.9304 | 0.9237..0.9381 | 29/31 |
| pipeline | internal | 2.572 | 2.571 | 1.0004 | 0.9957..1.0031 | 14/31 |
| pipeline | wall | 10.469 | 10.495 | 0.9990 | 0.9872..1.0060 | 16/31 |
| records | internal | 8.771 | 8.800 | 0.9980 | 0.9964..1.0019 | 19/31 |
| records | wall | 16.704 | 16.684 | 1.0021 | 0.9946..1.0139 | 13/31 |
| nbody | wall | 230.326 | 230.452 | 0.9996 | 0.9975..1.0007 | 16/31 |

## Builds

| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |
|---|---:|---:|---:|---:|---:|---:|
| simdintmap-baseline | 0.51 | 89.3 | 451408 | 294912 | 7 | 0 |
| simdf64map-baseline | 0.52 | 89.3 | 451600 | 294912 | 9 | 0 |
| pipeline-baseline | 0.51 | 90.2 | 452096 | 294912 | 8 | 0 |
| records-baseline | 0.64 | 90.3 | 470928 | 311296 | 36 | 0 |
| nbody-baseline | 0.49 | 89.2 | 450720 | 294912 | 2 | 0 |
| simdintmap-typed-ir | 0.52 | 89.4 | 451408 | 294912 | 7 | 0 |
| simdf64map-typed-ir | 0.56 | 89.4 | 451600 | 294912 | 9 | 0 |
| pipeline-typed-ir | 0.52 | 90.4 | 452096 | 294912 | 8 | 0 |
| records-typed-ir | 0.64 | 90.4 | 470928 | 311296 | 36 | 0 |
| nbody-typed-ir | 0.49 | 89.3 | 450720 | 294912 | 2 | 0 |

## Coverage under the backend (root unit)

- simdintmap-baseline: inc, main, sumInt, $vkernel:fpr_tkfn_inc, $vkernel:fpr_tkfn_sumInt, $vkernel:fpr_vspec_fold_sumInt, $vkernel:fpr_vspec_map_inc
- simdf64map-baseline: affine, fill, lifted_13, main, sumFloat, $vkernel:fpr_tkfn_affine, $vkernel:fpr_tkfn_sumFloat, $vkernel:fpr_vspec_fold_sumFloat, $vkernel:fpr_vspec_map_affine
- pipeline-baseline: above, inc, main, weighted, $vkernel:fpr_tkfn_above, $vkernel:fpr_tkfn_inc, $vkernel:fpr_tkfn_weighted, $vkernel:fpr_vspec_pipeline_x40PipePlan_x20_x7bpipeStages_x20_x3d_x20_x5b_x28_x22map_x22_x2c_x22inc_x22_x2c_x5b_x5d_x29_x2c_x28_x22filter_x22_x2c_x22above_x22_x2c_x5b_x5d_x29_x2c_x28_x22fold_x22_x2c_x22weighted_x22_x2c_x5b_x5d_x29_x5d_x2c_x20pipeElement_x20_x3d_x20KI_x2c_x20pipeAccumulator_x20_x3d_x20Just_x20_x280_x2cKI_x29_x7d_inc
- records-baseline: capture, fill, keepRecord, main, probeRecordCaptured, probeRecordFilter, probeRecordFold, probeRecordMap, rotate, sampleRow, step, total, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5ffold_x5fstep, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f0, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f1, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f2, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f3, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f4, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f5, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f6, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f7, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f8, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f0, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f1, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f2, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f3, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f4, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f5, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f6, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f7, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f8, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5frfilter_x5fkeepRecord, $vkernel:fpr_vspec_fold_step, $vkernel:fpr_vspec_mvmap_capture, $vkernel:fpr_vspec_mvmap_rotate, $vkernel:fpr_vspec_rfilter_keepRecord
- nbody-baseline: main, step
- simdintmap-typed-ir: inc, main, sumInt, $vkernel:fpr_tkfn_inc, $vkernel:fpr_tkfn_sumInt, $vkernel:fpr_vspec_fold_sumInt, $vkernel:fpr_vspec_map_inc
- simdf64map-typed-ir: affine, fill, lifted_13, main, sumFloat, $vkernel:fpr_tkfn_affine, $vkernel:fpr_tkfn_sumFloat, $vkernel:fpr_vspec_fold_sumFloat, $vkernel:fpr_vspec_map_affine
- pipeline-typed-ir: above, inc, main, weighted, $vkernel:fpr_tkfn_above, $vkernel:fpr_tkfn_inc, $vkernel:fpr_tkfn_weighted, $vkernel:fpr_vspec_pipeline_x40PipePlan_x20_x7bpipeStages_x20_x3d_x20_x5b_x28_x22map_x22_x2c_x22inc_x22_x2c_x5b_x5d_x29_x2c_x28_x22filter_x22_x2c_x22above_x22_x2c_x5b_x5d_x29_x2c_x28_x22fold_x22_x2c_x22weighted_x22_x2c_x5b_x5d_x29_x5d_x2c_x20pipeElement_x20_x3d_x20KI_x2c_x20pipeAccumulator_x20_x3d_x20Just_x20_x280_x2cKI_x29_x7d_inc
- records-typed-ir: capture, fill, keepRecord, main, probeRecordCaptured, probeRecordFilter, probeRecordFold, probeRecordMap, rotate, sampleRow, step, total, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5ffold_x5fstep, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f0, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f1, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f2, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f3, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f4, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f5, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f6, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f7, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f8, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f0, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f1, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f2, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f3, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f4, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f5, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f6, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f7, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f8, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5frfilter_x5fkeepRecord, $vkernel:fpr_vspec_fold_step, $vkernel:fpr_vspec_mvmap_capture, $vkernel:fpr_vspec_mvmap_rotate, $vkernel:fpr_vspec_rfilter_keepRecord
- nbody-typed-ir: main, step

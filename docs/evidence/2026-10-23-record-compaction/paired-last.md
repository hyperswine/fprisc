# M3 paired measurements

revision bcd523d7130370f02498b45ce023bfef174ed5cc, compiler sha256 88f8b2e55718, macOS-27.0.1-arm64-arm-64bit-Mach-O
31 rounds; internal timers: recordcompactlast; process wall:

## typed-ir against baseline

| workload | timer | baseline median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| recordcompactlast | internal | 6.058 | 4.038 | 0.6709 | 0.6573..0.7005 | 31/31 |
| recordcompactlast | wall | 47.083 | 45.237 | 0.9616 | 0.9550..0.9712 | 28/31 |

## Builds

| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |
|---|---:|---:|---:|---:|---:|---:|
| recordcompactlast-baseline | 0.98 | 133.5 | 471288 | 311296 | 36 | 0 |
| recordcompactlast-typed-ir | 0.98 | 133.5 | 471288 | 311296 | 36 | 0 |

## Coverage under the backend (root unit)

- recordcompactlast-baseline: capture, fill, keepRecord, main, probeRecordCaptured, probeRecordFilter, probeRecordFold, probeRecordMap, rotate, sampleRow, step, total, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5ffold_x5fstep, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f0, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f1, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f2, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f3, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f4, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f5, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f6, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f7, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f8, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f0, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f1, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f2, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f3, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f4, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f5, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f6, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f7, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f8, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5frfilter_x5fkeepRecord, $vkernel:fpr_vspec_fold_step, $vkernel:fpr_vspec_mvmap_capture, $vkernel:fpr_vspec_mvmap_rotate, $vkernel:fpr_vspec_rfilter_keepRecord
- recordcompactlast-typed-ir: capture, fill, keepRecord, main, probeRecordCaptured, probeRecordFilter, probeRecordFold, probeRecordMap, rotate, sampleRow, step, total, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5ffold_x5fstep, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f0, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f1, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f2, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f3, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f4, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f5, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f6, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f7, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f8, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f0, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f1, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f2, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f3, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f4, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f5, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f6, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f7, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f8, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5frfilter_x5fkeepRecord, $vkernel:fpr_vspec_fold_step, $vkernel:fpr_vspec_mvmap_capture, $vkernel:fpr_vspec_mvmap_rotate, $vkernel:fpr_vspec_rfilter_keepRecord

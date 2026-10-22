# M3 paired measurements

revision 69516537e274de7d483e679f10834734b09b88a1, compiler sha256 5f21063ec55a, macOS-27.0.1-arm64-arm-64bit-Mach-O
31 rounds; internal timers: fib, sum, pipeline, records; process wall: helpers, sha, floatcmp, nbody

## typed-ir against legacy

| workload | timer | legacy median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| records | internal | 10.007 | 8.724 | 0.8700 | 0.8681..0.8873 | 30/31 |
| records | wall | 18.616 | 16.755 | 0.9047 | 0.8995..0.9200 | 29/31 |

## typed-ir against legacy-best

| workload | timer | legacy-best median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| records | internal | 10.511 | 8.724 | 0.8315 | 0.8132..0.8402 | 31/31 |
| records | wall | 19.265 | 16.755 | 0.8800 | 0.8630..0.8938 | 30/31 |

## Builds

| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |
|---|---:|---:|---:|---:|---:|---:|
| records-legacy | 0.45 | 90.1 | 468960 | 311296 | 0 | 12 |
| records-legacy-best | 0.50 | 90.1 | 470448 | 311296 | 0 | 12 |
| records-typed-ir | 0.63 | 90.3 | 470240 | 311296 | 36 | 0 |

## Coverage under the backend (root unit)

- records-typed-ir: capture, fill, keepRecord, main, probeRecordCaptured, probeRecordFilter, probeRecordFold, probeRecordMap, rotate, sampleRow, step, total, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5ffold_x5fstep, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f0, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f1, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f2, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f3, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f4, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f5, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f6, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f7, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5fcapture_x5f8, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f0, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f1, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f2, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f3, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f4, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f5, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f6, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f7, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5fmvmap_x5frotate_x5f8, $vkernel:fpr_tkfn__x24record_x3afpr_x5fvspec_x5frfilter_x5fkeepRecord, $vkernel:fpr_vspec_fold_step, $vkernel:fpr_vspec_mvmap_capture, $vkernel:fpr_vspec_mvmap_rotate, $vkernel:fpr_vspec_rfilter_keepRecord

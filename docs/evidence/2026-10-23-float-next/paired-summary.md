# M3 paired measurements

revision ae507dc58fda0073b6e95445dc6211d802f7ca9e, compiler sha256 b6e4bc69e5a5, macOS-27.0.1-arm64-arm-64bit-Mach-O
31 rounds; internal timers: fib, sum, pipeline, records, cmpchain64, f32trees; process wall: helpers, sha, floatcmp, nbody

## typed-ir-trees against baseline

| workload | timer | baseline median ms | typed-ir-trees median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| cmpchain64 | internal | 10.363 | 10.367 | 1.0009 | 0.9991..1.0026 | 12/31 |
| cmpchain64 | wall | 15.111 | 15.095 | 0.9957 | 0.9887..1.0008 | 20/31 |
| f32trees | internal | 10.440 | 10.345 | 0.9916 | 0.9895..0.9928 | 29/31 |
| f32trees | wall | 14.784 | 14.728 | 0.9953 | 0.9888..1.0004 | 19/31 |
| nbody | wall | 255.560 | 255.581 | 1.0010 | 0.9998..1.0017 | 11/31 |
| floatcmp | wall | 40.384 | 40.474 | 1.0031 | 1.0004..1.0046 | 9/31 |
| fib | internal | 53.510 | 55.019 | 1.0065 | 0.9850..1.0551 | 14/31 |
| fib | wall | 57.982 | 60.038 | 1.0062 | 0.9963..1.0463 | 13/31 |
| sum | internal | 10.275 | 10.267 | 0.9994 | 0.9978..1.0005 | 19/31 |
| sum | wall | 14.699 | 14.725 | 1.0089 | 0.9910..1.0195 | 13/31 |
| pipeline | internal | 2.569 | 2.567 | 1.0004 | 0.9930..1.0031 | 13/31 |
| pipeline | wall | 10.295 | 10.291 | 1.0036 | 0.9831..1.0104 | 14/31 |
| helpers | wall | 104.748 | 104.653 | 0.9992 | 0.9967..1.0011 | 17/31 |
| sha | wall | 120.141 | 119.446 | 0.9970 | 0.9867..1.0048 | 18/31 |

## typed-ir against baseline

| workload | timer | baseline median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| cmpchain64 | internal | 10.363 | 10.367 | 1.0003 | 0.9987..1.0023 | 13/31 |
| cmpchain64 | wall | 15.111 | 15.113 | 0.9999 | 0.9857..1.0067 | 16/31 |
| f32trees | internal | 10.440 | 10.341 | 0.9892 | 0.9887..0.9916 | 27/31 |
| f32trees | wall | 14.784 | 14.789 | 1.0012 | 0.9909..1.0050 | 14/31 |
| nbody | wall | 255.560 | 230.285 | 0.9009 | 0.9002..0.9022 | 30/31 |
| floatcmp | wall | 40.384 | 40.467 | 1.0022 | 0.9995..1.0050 | 11/31 |
| fib | internal | 53.510 | 55.144 | 1.0237 | 0.9967..1.0531 | 13/31 |
| fib | wall | 57.982 | 59.596 | 1.0239 | 0.9921..1.0505 | 11/31 |
| sum | internal | 10.275 | 10.268 | 0.9993 | 0.9977..1.0005 | 18/31 |
| sum | wall | 14.699 | 14.737 | 0.9973 | 0.9901..1.0096 | 16/31 |
| pipeline | internal | 2.569 | 2.572 | 1.0023 | 0.9984..1.0051 | 12/31 |
| pipeline | wall | 10.295 | 10.319 | 0.9990 | 0.9873..1.0139 | 16/31 |
| helpers | wall | 104.748 | 104.665 | 0.9991 | 0.9938..1.0025 | 16/31 |
| sha | wall | 120.141 | 119.718 | 0.9964 | 0.9911..0.9998 | 21/31 |

## typed-ir-trees against typed-ir

| workload | timer | typed-ir median ms | typed-ir-trees median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| cmpchain64 | internal | 10.367 | 10.367 | 1.0001 | 0.9987..1.0020 | 15/31 |
| cmpchain64 | wall | 15.113 | 15.095 | 0.9974 | 0.9951..1.0032 | 16/31 |
| f32trees | internal | 10.341 | 10.345 | 1.0002 | 0.9982..1.0012 | 14/31 |
| f32trees | wall | 14.789 | 14.728 | 1.0036 | 0.9883..1.0069 | 15/31 |
| nbody | wall | 230.285 | 255.581 | 1.1102 | 1.1095..1.1115 | 3/31 |
| floatcmp | wall | 40.467 | 40.474 | 0.9988 | 0.9950..1.0057 | 17/31 |
| fib | internal | 55.144 | 55.019 | 1.0018 | 0.9681..1.0263 | 14/31 |
| fib | wall | 59.596 | 60.038 | 1.0030 | 0.9957..1.0249 | 13/31 |
| sum | internal | 10.268 | 10.267 | 0.9994 | 0.9984..1.0009 | 18/31 |
| sum | wall | 14.737 | 14.725 | 1.0038 | 0.9971..1.0102 | 13/31 |
| pipeline | internal | 2.572 | 2.567 | 0.9977 | 0.9930..1.0008 | 19/31 |
| pipeline | wall | 10.319 | 10.291 | 0.9991 | 0.9874..1.0063 | 16/31 |
| helpers | wall | 104.665 | 104.653 | 1.0004 | 0.9975..1.0019 | 15/31 |
| sha | wall | 119.718 | 119.446 | 0.9985 | 0.9916..1.0033 | 17/31 |

## Builds

| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |
|---|---:|---:|---:|---:|---:|---:|
| cmpchain64-baseline | 0.50 | 89.2 | 450832 | 294912 | 2 | 0 |
| f32trees-baseline | 0.49 | 89.2 | 450832 | 294912 | 2 | 0 |
| nbody-baseline | 0.48 | 89.2 | 450464 | 294912 | 2 | 0 |
| floatcmp-baseline | 0.48 | 89.2 | 450464 | 294912 | 2 | 0 |
| fib-baseline | 0.49 | 89.2 | 450848 | 294912 | 3 | 0 |
| sum-baseline | 0.50 | 89.2 | 450848 | 294912 | 3 | 0 |
| pipeline-baseline | 0.51 | 90.2 | 451840 | 294912 | 8 | 0 |
| helpers-baseline | 0.50 | 89.2 | 451008 | 294912 | 7 | 0 |
| sha-baseline | 2.65 | 147.5 | 749344 | 442368 | 1 | 0 |
| cmpchain64-typed-ir-trees | 0.50 | 89.2 | 450840 | 294912 | 2 | 0 |
| f32trees-typed-ir-trees | 0.49 | 89.2 | 450840 | 294912 | 2 | 0 |
| nbody-typed-ir-trees | 0.49 | 89.2 | 450472 | 294912 | 2 | 0 |
| floatcmp-typed-ir-trees | 0.49 | 89.2 | 450472 | 294912 | 2 | 0 |
| fib-typed-ir-trees | 0.51 | 89.2 | 450848 | 294912 | 3 | 0 |
| sum-typed-ir-trees | 0.50 | 89.2 | 450848 | 294912 | 3 | 0 |
| pipeline-typed-ir-trees | 0.51 | 90.2 | 451848 | 294912 | 8 | 0 |
| helpers-typed-ir-trees | 0.51 | 89.2 | 451016 | 294912 | 7 | 0 |
| sha-typed-ir-trees | 2.84 | 148.5 | 749344 | 442368 | 1 | 0 |
| cmpchain64-typed-ir | 0.54 | 89.2 | 451088 | 294912 | 2 | 0 |
| f32trees-typed-ir | 0.50 | 89.2 | 451088 | 294912 | 2 | 0 |
| nbody-typed-ir | 0.50 | 89.2 | 450720 | 294912 | 2 | 0 |
| floatcmp-typed-ir | 0.53 | 89.2 | 450736 | 294912 | 2 | 0 |
| fib-typed-ir | 0.50 | 89.2 | 451104 | 294912 | 3 | 0 |
| sum-typed-ir | 0.50 | 89.2 | 451104 | 294912 | 3 | 0 |
| pipeline-typed-ir | 0.51 | 90.2 | 452096 | 294912 | 8 | 0 |
| helpers-typed-ir | 0.51 | 89.2 | 451264 | 294912 | 7 | 0 |
| sha-typed-ir | 2.86 | 148.5 | 749872 | 442368 | 1 | 0 |

## Coverage under the backend (root unit)

- cmpchain64-baseline: loopFloat64, main
- f32trees-baseline: loopFloat32, main
- nbody-baseline: main, step
- floatcmp-baseline: loop, main
- fib-baseline: $worker.scalar.fib, fib, main
- sum-baseline: $worker.scalar.loop, loop, main
- pipeline-baseline: above, inc, main, weighted, $vkernel:fpr_tkfn_above, $vkernel:fpr_tkfn_inc, $vkernel:fpr_tkfn_weighted, $vkernel:fpr_vspec_pipeline_x40PipePlan_x20_x7bpipeStages_x20_x3d_x20_x5b_x28_x22map_x22_x2c_x22inc_x22_x2c_x5b_x5d_x29_x2c_x28_x22filter_x22_x2c_x22above_x22_x2c_x5b_x5d_x29_x2c_x28_x22fold_x22_x2c_x22weighted_x22_x2c_x5b_x5d_x29_x5d_x2c_x20pipeElement_x20_x3d_x20KI_x2c_x20pipeAccumulator_x20_x3d_x20Just_x20_x280_x2cKI_x29_x7d_inc
- helpers-baseline: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-baseline: main
- cmpchain64-typed-ir-trees: loopFloat64, main
- f32trees-typed-ir-trees: loopFloat32, main
- nbody-typed-ir-trees: main, step
- floatcmp-typed-ir-trees: loop, main
- fib-typed-ir-trees: $worker.scalar.fib, fib, main
- sum-typed-ir-trees: $worker.scalar.loop, loop, main
- pipeline-typed-ir-trees: above, inc, main, weighted, $vkernel:fpr_tkfn_above, $vkernel:fpr_tkfn_inc, $vkernel:fpr_tkfn_weighted, $vkernel:fpr_vspec_pipeline_x40PipePlan_x20_x7bpipeStages_x20_x3d_x20_x5b_x28_x22map_x22_x2c_x22inc_x22_x2c_x5b_x5d_x29_x2c_x28_x22filter_x22_x2c_x22above_x22_x2c_x5b_x5d_x29_x2c_x28_x22fold_x22_x2c_x22weighted_x22_x2c_x5b_x5d_x29_x5d_x2c_x20pipeElement_x20_x3d_x20KI_x2c_x20pipeAccumulator_x20_x3d_x20Just_x20_x280_x2cKI_x29_x7d_inc
- helpers-typed-ir-trees: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-typed-ir-trees: main
- cmpchain64-typed-ir: loopFloat64, main
- f32trees-typed-ir: loopFloat32, main
- nbody-typed-ir: main, step
- floatcmp-typed-ir: loop, main
- fib-typed-ir: $worker.scalar.fib, fib, main
- sum-typed-ir: $worker.scalar.loop, loop, main
- pipeline-typed-ir: above, inc, main, weighted, $vkernel:fpr_tkfn_above, $vkernel:fpr_tkfn_inc, $vkernel:fpr_tkfn_weighted, $vkernel:fpr_vspec_pipeline_x40PipePlan_x20_x7bpipeStages_x20_x3d_x20_x5b_x28_x22map_x22_x2c_x22inc_x22_x2c_x5b_x5d_x29_x2c_x28_x22filter_x22_x2c_x22above_x22_x2c_x5b_x5d_x29_x2c_x28_x22fold_x22_x2c_x22weighted_x22_x2c_x5b_x5d_x29_x5d_x2c_x20pipeElement_x20_x3d_x20KI_x2c_x20pipeAccumulator_x20_x3d_x20Just_x20_x280_x2cKI_x29_x7d_inc
- helpers-typed-ir: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-typed-ir: main

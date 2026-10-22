# M3 paired measurements

revision 8a5de33ddf7b8ee5901b85c5f173f37957f9f7aa, compiler sha256 2c0b4e862440, macOS-27.0.1-arm64-arm-64bit-Mach-O
31 rounds; internal timers: fib, sum, pipeline; process wall: helpers, sha, floatcmp, nbody

## typed-ir against legacy

| workload | timer | legacy median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| pipeline | internal | 3.090 | 2.641 | 0.8567 | 0.8213..0.8971 | 28/31 |
| pipeline | wall | 13.333 | 12.605 | 0.9560 | 0.9311..0.9620 | 29/31 |

## typed-ir against legacy-best

| workload | timer | legacy-best median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| pipeline | internal | 3.007 | 2.641 | 0.8968 | 0.8485..0.9180 | 28/31 |
| pipeline | wall | 13.185 | 12.605 | 0.9621 | 0.9472..0.9861 | 25/31 |

## Builds

| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |
|---|---:|---:|---:|---:|---:|---:|
| pipeline-legacy | 0.44 | 90.1 | 450992 | 294912 | 0 | 4 |
| pipeline-legacy-best | 0.45 | 90.1 | 452504 | 294912 | 0 | 4 |
| pipeline-typed-ir | 0.55 | 90.2 | 451456 | 294912 | 8 | 0 |

## Coverage under the backend (root unit)

- pipeline-typed-ir: above, inc, main, weighted, $vkernel:fpr_tkfn_above, $vkernel:fpr_tkfn_inc, $vkernel:fpr_tkfn_weighted, $vkernel:fpr_vspec_pipeline_x40PipePlan_x20_x7bpipeStages_x20_x3d_x20_x5b_x28_x22map_x22_x2c_x22inc_x22_x2c_x5b_x5d_x29_x2c_x28_x22filter_x22_x2c_x22above_x22_x2c_x5b_x5d_x29_x2c_x28_x22fold_x22_x2c_x22weighted_x22_x2c_x5b_x5d_x29_x5d_x2c_x20pipeElement_x20_x3d_x20KI_x2c_x20pipeAccumulator_x20_x3d_x20Just_x20_x280_x2cKI_x29_x7d_inc

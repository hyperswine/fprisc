# M3 paired measurements

revision 258511250a097c6ed36b77ace30e7e11b5572890, compiler sha256 7b670766ccf5, macOS-27.0.1-arm64-arm-64bit-Mach-O
31 rounds; internal timers: fib, sum, pipeline; process wall: helpers, sha, floatcmp, nbody

## typed-ir against legacy

| workload | timer | legacy median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| pipeline | internal | 3.030 | 3.199 | 1.0555 | 1.0274..1.0728 | 8/31 |
| pipeline | wall | 9.948 | 10.060 | 1.0100 | 0.9950..1.0155 | 11/31 |

## typed-ir against legacy-best

| workload | timer | legacy-best median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| pipeline | internal | 3.024 | 3.199 | 1.0437 | 0.9993..1.0684 | 10/31 |
| pipeline | wall | 9.952 | 10.060 | 1.0026 | 0.9936..1.0071 | 13/31 |

## Builds

| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |
|---|---:|---:|---:|---:|---:|---:|
| pipeline-legacy | 0.37 | 89.9 | 450992 | 294912 | 0 | 4 |
| pipeline-legacy-best | 0.38 | 89.9 | 452504 | 294912 | 0 | 4 |
| pipeline-typed-ir | 0.45 | 90.2 | 451456 | 294912 | 4 | 0 |

## Coverage under the backend (root unit)

- pipeline-typed-ir: above, inc, main, weighted

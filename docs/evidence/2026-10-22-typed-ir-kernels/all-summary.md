# M3 paired measurements

revision 258511250a097c6ed36b77ace30e7e11b5572890, compiler sha256 7b670766ccf5, macOS-27.0.1-arm64-arm-64bit-Mach-O
31 rounds; internal timers: fib, sum, pipeline; process wall: helpers, sha, floatcmp, nbody

## typed-ir against legacy-best

| workload | timer | legacy-best median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 49.305 | 51.259 | 1.0306 | 1.0083..1.0482 | 8/31 |
| fib | wall | 53.530 | 55.474 | 1.0284 | 1.0011..1.0430 | 10/31 |
| sum | internal | 14.601 | 9.241 | 0.6336 | 0.6294..0.6392 | 31/31 |
| sum | wall | 18.406 | 13.035 | 0.7075 | 0.6997..0.7151 | 31/31 |
| pipeline | internal | 3.081 | 3.294 | 1.0661 | 1.0514..1.0792 | 5/31 |
| pipeline | wall | 10.300 | 10.319 | 1.0035 | 0.9909..1.0134 | 14/31 |
| helpers | wall | 163.312 | 96.504 | 0.5945 | 0.5848..0.6188 | 31/31 |
| sha | wall | 124.053 | 113.399 | 0.9102 | 0.9084..0.9166 | 31/31 |
| floatcmp | wall | 63.408 | 37.535 | 0.5918 | 0.5883..0.5952 | 31/31 |
| nbody | wall | 391.612 | 350.891 | 0.8958 | 0.8954..0.8968 | 31/31 |

## Builds

| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |
|---|---:|---:|---:|---:|---:|---:|
| fib-legacy-best | 0.37 | 88.8 | 451488 | 294912 | 0 | 3 |
| sum-legacy-best | 0.38 | 88.8 | 451504 | 294912 | 0 | 3 |
| pipeline-legacy-best | 0.37 | 89.9 | 452504 | 294912 | 0 | 4 |
| helpers-legacy-best | 0.37 | 88.8 | 451648 | 294912 | 0 | 7 |
| sha-legacy-best | 2.78 | 153.1 | 767360 | 458752 | 0 | 1 |
| floatcmp-legacy-best | 0.36 | 88.8 | 451144 | 294912 | 0 | 2 |
| nbody-legacy-best | 0.36 | 88.8 | 451136 | 294912 | 0 | 2 |
| fib-typed-ir | 0.46 | 89.1 | 450448 | 294912 | 3 | 0 |
| sum-typed-ir | 0.45 | 89.1 | 450464 | 294912 | 3 | 0 |
| pipeline-typed-ir | 0.45 | 90.2 | 451456 | 294912 | 4 | 0 |
| helpers-typed-ir | 0.45 | 89.1 | 450592 | 294912 | 7 | 0 |
| sha-typed-ir | 2.45 | 152.4 | 748640 | 442368 | 1 | 0 |
| floatcmp-typed-ir | 0.44 | 89.1 | 450032 | 294912 | 2 | 0 |
| nbody-typed-ir | 0.44 | 89.1 | 450032 | 294912 | 2 | 0 |

## Coverage under the backend (root unit)

- fib-typed-ir: $worker.scalar.fib, fib, main
- sum-typed-ir: $worker.scalar.loop, loop, main
- pipeline-typed-ir: above, inc, main, weighted
- helpers-typed-ir: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-typed-ir: main
- floatcmp-typed-ir: loop, main
- nbody-typed-ir: main, step

# M3 paired measurements

revision 5990e285452ce6729f450e6fc3e82250336b3ebf, compiler sha256 4916e8e3d3bb, macOS-27.0.1-arm64-arm-64bit
31 rounds; internal timers: fib, sum, pipeline; process wall: helpers, sha

## typed-ir against legacy

| workload | timer | legacy median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 74.566 | 74.567 | 1.0000 | 0.9995..1.0011 | 13/31 |
| fib | wall | 81.211 | 81.222 | 0.9993 | 0.9979..1.0019 | 17/31 |
| sum | internal | 22.999 | 20.957 | 0.9116 | 0.9103..0.9120 | 31/31 |
| sum | wall | 29.125 | 27.210 | 0.9316 | 0.9287..0.9369 | 31/31 |
| pipeline | internal | 5.298 | 5.308 | 1.0000 | 0.9985..1.0032 | 15/31 |
| pipeline | wall | 17.415 | 17.448 | 1.0015 | 0.9906..1.0159 | 15/31 |
| helpers | wall | 227.896 | 157.805 | 0.6925 | 0.6922..0.6929 | 31/31 |
| sha | wall | 200.102 | 199.849 | 1.0000 | 0.9988..1.0032 | 16/31 |

## typed-ir-noloop against legacy

| workload | timer | legacy median ms | typed-ir-noloop median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 74.566 | 74.569 | 0.9999 | 0.9995..1.0009 | 16/31 |
| fib | wall | 81.211 | 81.218 | 0.9996 | 0.9979..1.0012 | 16/31 |
| sum | internal | 22.999 | 21.280 | 0.9245 | 0.9222..0.9249 | 31/31 |
| sum | wall | 29.125 | 27.315 | 0.9419 | 0.9347..0.9454 | 31/31 |
| pipeline | internal | 5.298 | 5.304 | 1.0004 | 0.9996..1.0026 | 13/31 |
| pipeline | wall | 17.415 | 16.831 | 0.9684 | 0.9631..0.9745 | 29/31 |
| helpers | wall | 227.896 | 157.743 | 0.6920 | 0.6912..0.6925 | 31/31 |
| sha | wall | 200.102 | 200.093 | 1.0006 | 0.9971..1.0056 | 14/31 |

## typed-ir-best against legacy

| workload | timer | legacy median ms | typed-ir-best median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 74.566 | 74.591 | 1.0002 | 0.9997..1.0010 | 14/31 |
| fib | wall | 81.211 | 81.223 | 1.0014 | 1.0002..1.0027 | 9/31 |
| sum | internal | 22.999 | 20.957 | 0.9113 | 0.9096..0.9129 | 31/31 |
| sum | wall | 29.125 | 27.084 | 0.9317 | 0.9297..0.9339 | 31/31 |
| pipeline | internal | 5.298 | 5.302 | 1.0004 | 0.9992..1.0042 | 15/31 |
| pipeline | wall | 17.415 | 16.709 | 0.9579 | 0.9546..0.9692 | 29/31 |
| helpers | wall | 227.896 | 158.235 | 0.6941 | 0.6933..0.6947 | 31/31 |
| sha | wall | 200.102 | 193.627 | 0.9679 | 0.9641..0.9709 | 31/31 |

## typed-ir against legacy-best

| workload | timer | legacy-best median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 74.605 | 74.567 | 0.9998 | 0.9994..1.0006 | 17/31 |
| fib | wall | 81.284 | 81.222 | 0.9996 | 0.9984..1.0013 | 17/31 |
| sum | internal | 20.975 | 20.957 | 0.9989 | 0.9985..1.0002 | 20/31 |
| sum | wall | 27.245 | 27.210 | 0.9986 | 0.9957..1.0014 | 17/31 |
| pipeline | internal | 5.304 | 5.308 | 1.0002 | 0.9979..1.0019 | 15/31 |
| pipeline | wall | 17.439 | 17.448 | 1.0012 | 0.9920..1.0137 | 15/31 |
| helpers | wall | 219.908 | 157.805 | 0.7173 | 0.7168..0.7178 | 31/31 |
| sha | wall | 187.323 | 199.849 | 1.0682 | 1.0633..1.0720 | 0/31 |

## typed-ir-noloop against legacy-best

| workload | timer | legacy-best median ms | typed-ir-noloop median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 74.605 | 74.569 | 0.9996 | 0.9991..1.0005 | 18/31 |
| fib | wall | 81.284 | 81.218 | 0.9997 | 0.9981..1.0024 | 16/31 |
| sum | internal | 20.975 | 21.280 | 1.0136 | 1.0116..1.0145 | 0/31 |
| sum | wall | 27.245 | 27.315 | 1.0049 | 1.0010..1.0124 | 10/31 |
| pipeline | internal | 5.304 | 5.304 | 0.9991 | 0.9972..1.0032 | 16/31 |
| pipeline | wall | 17.439 | 16.831 | 0.9642 | 0.9582..0.9738 | 29/31 |
| helpers | wall | 219.908 | 157.743 | 0.7170 | 0.7166..0.7175 | 31/31 |
| sha | wall | 187.323 | 200.093 | 1.0675 | 1.0630..1.0696 | 0/31 |

## typed-ir-best against legacy-best

| workload | timer | legacy-best median ms | typed-ir-best median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 74.605 | 74.591 | 0.9998 | 0.9995..1.0004 | 18/31 |
| fib | wall | 81.284 | 81.223 | 1.0000 | 0.9969..1.0031 | 15/31 |
| sum | internal | 20.975 | 20.957 | 0.9989 | 0.9970..0.9996 | 21/31 |
| sum | wall | 27.245 | 27.084 | 0.9999 | 0.9944..1.0036 | 16/31 |
| pipeline | internal | 5.304 | 5.302 | 0.9991 | 0.9981..1.0019 | 17/31 |
| pipeline | wall | 17.439 | 16.709 | 0.9593 | 0.9516..0.9641 | 27/31 |
| helpers | wall | 219.908 | 158.235 | 0.7193 | 0.7186..0.7198 | 31/31 |
| sha | wall | 187.323 | 193.627 | 1.0340 | 1.0306..1.0372 | 2/31 |

## Builds

| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |
|---|---:|---:|---:|---:|---:|---:|
| fib-legacy | 0.55 | 88.2 | 449912 | 294912 | 0 | 3 |
| sum-legacy | 0.54 | 88.2 | 449928 | 294912 | 0 | 3 |
| pipeline-legacy | 0.55 | 89.3 | 450944 | 294912 | 0 | 4 |
| helpers-legacy | 0.55 | 89.2 | 450064 | 294912 | 0 | 7 |
| sha-legacy | 3.65 | 147.5 | 764184 | 458752 | 0 | 1 |
| fib-legacy-best | 0.54 | 88.2 | 451440 | 294912 | 0 | 3 |
| sum-legacy-best | 0.55 | 88.2 | 451456 | 294912 | 0 | 3 |
| pipeline-legacy-best | 0.55 | 89.2 | 452456 | 294912 | 0 | 4 |
| helpers-legacy-best | 0.55 | 89.2 | 451600 | 294912 | 0 | 7 |
| sha-legacy-best | 4.20 | 154.5 | 767312 | 458752 | 0 | 1 |
| fib-typed-ir | 0.60 | 88.5 | 466896 | 311296 | 2 | 1 |
| sum-typed-ir | 0.60 | 88.5 | 466912 | 311296 | 2 | 1 |
| pipeline-typed-ir | 0.60 | 89.6 | 467888 | 311296 | 3 | 1 |
| helpers-typed-ir | 0.60 | 89.5 | 467040 | 311296 | 4 | 3 |
| sha-typed-ir | 3.74 | 156.8 | 781584 | 475136 | 0 | 1 |
| fib-typed-ir-noloop | 0.60 | 88.5 | 467184 | 311296 | 2 | 1 |
| sum-typed-ir-noloop | 0.60 | 88.5 | 467200 | 311296 | 2 | 1 |
| pipeline-typed-ir-noloop | 0.60 | 89.6 | 468184 | 311296 | 3 | 1 |
| helpers-typed-ir-noloop | 0.60 | 89.5 | 467336 | 311296 | 4 | 3 |
| sha-typed-ir-noloop | 3.74 | 144.8 | 782176 | 475136 | 0 | 1 |
| fib-typed-ir-best | 0.61 | 88.5 | 468400 | 311296 | 2 | 1 |
| sum-typed-ir-best | 0.60 | 88.5 | 468416 | 311296 | 2 | 1 |
| pipeline-typed-ir-best | 0.61 | 89.6 | 469416 | 311296 | 3 | 1 |
| helpers-typed-ir-best | 0.60 | 89.5 | 468552 | 311296 | 4 | 3 |
| sha-typed-ir-best | 4.28 | 169.8 | 768240 | 458752 | 0 | 1 |

## Coverage under the backend (root unit)

- fib-typed-ir: $worker.scalar.fib, fib
- sum-typed-ir: $worker.scalar.loop, loop
- pipeline-typed-ir: above, inc, weighted
- helpers-typed-ir: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, mix
- fib-typed-ir-noloop: $worker.scalar.fib, fib
- sum-typed-ir-noloop: $worker.scalar.loop, loop
- pipeline-typed-ir-noloop: above, inc, weighted
- helpers-typed-ir-noloop: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, mix
- fib-typed-ir-best: $worker.scalar.fib, fib
- sum-typed-ir-best: $worker.scalar.loop, loop
- pipeline-typed-ir-best: above, inc, weighted
- helpers-typed-ir-best: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, mix

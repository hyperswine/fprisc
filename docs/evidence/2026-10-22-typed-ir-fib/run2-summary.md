# M3 paired measurements

revision 6864b0d75ea0566bcf665d9acc07211467790873, compiler sha256 c7e5ec7447a2, macOS-27.0.1-arm64-arm-64bit-Mach-O
31 rounds; internal timers: fib, sum, pipeline; process wall: helpers, sha

## typed-ir against legacy-best

| workload | timer | legacy-best median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 49.678 | 55.692 | 1.1130 | 1.1013..1.1259 | 0/31 |
| fib | wall | 53.789 | 59.748 | 1.1037 | 1.0937..1.1175 | 0/31 |
| sum | internal | 14.552 | 9.203 | 0.6348 | 0.6290..0.6419 | 31/31 |
| sum | wall | 18.337 | 12.981 | 0.7090 | 0.7059..0.7142 | 31/31 |
| pipeline | internal | 3.097 | 3.269 | 1.0558 | 1.0449..1.0766 | 3/31 |
| pipeline | wall | 10.068 | 10.236 | 1.0099 | 0.9993..1.0285 | 11/31 |
| helpers | wall | 160.174 | 95.835 | 0.6008 | 0.5953..0.6088 | 31/31 |
| sha | wall | 123.022 | 111.783 | 0.9084 | 0.9033..0.9133 | 31/31 |

## typed-ir-pairs against legacy-best

| workload | timer | legacy-best median ms | typed-ir-pairs median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 49.678 | 50.609 | 1.0167 | 0.9934..1.0287 | 13/31 |
| fib | wall | 53.789 | 54.478 | 1.0145 | 0.9914..1.0275 | 13/31 |
| sum | internal | 14.552 | 9.177 | 0.6324 | 0.6267..0.6390 | 31/31 |
| sum | wall | 18.337 | 12.960 | 0.7057 | 0.7025..0.7115 | 31/31 |
| pipeline | internal | 3.097 | 3.244 | 1.0343 | 1.0251..1.0491 | 1/31 |
| pipeline | wall | 10.068 | 10.216 | 1.0098 | 0.9986..1.0190 | 11/31 |
| helpers | wall | 160.174 | 96.145 | 0.6010 | 0.5944..0.6121 | 31/31 |
| sha | wall | 123.022 | 112.015 | 0.9137 | 0.9083..0.9168 | 31/31 |

## typed-ir-args-split-wrap against legacy-best

| workload | timer | legacy-best median ms | typed-ir-args-split-wrap median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 49.678 | 49.550 | 0.9966 | 0.9894..1.0118 | 17/31 |
| fib | wall | 53.789 | 53.788 | 0.9976 | 0.9880..1.0068 | 17/31 |
| sum | internal | 14.552 | 9.239 | 0.6402 | 0.6313..0.6445 | 31/31 |
| sum | wall | 18.337 | 12.978 | 0.7123 | 0.7066..0.7169 | 31/31 |
| pipeline | internal | 3.097 | 3.257 | 1.0506 | 1.0368..1.0675 | 2/31 |
| pipeline | wall | 10.068 | 10.190 | 1.0103 | 0.9953..1.0178 | 12/31 |
| helpers | wall | 160.174 | 98.178 | 0.6105 | 0.6078..0.6277 | 31/31 |
| sha | wall | 123.022 | 115.899 | 0.9400 | 0.9335..0.9465 | 31/31 |

## typed-ir-all against legacy-best

| workload | timer | legacy-best median ms | typed-ir-all median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 49.678 | 49.070 | 0.9856 | 0.9433..1.0097 | 18/31 |
| fib | wall | 53.789 | 53.333 | 0.9875 | 0.9482..1.0064 | 18/31 |
| sum | internal | 14.552 | 9.366 | 0.6543 | 0.6415..0.6582 | 31/31 |
| sum | wall | 18.337 | 13.182 | 0.7254 | 0.7163..0.7290 | 31/31 |
| pipeline | internal | 3.097 | 3.297 | 1.0628 | 1.0365..1.0748 | 4/31 |
| pipeline | wall | 10.068 | 10.187 | 1.0092 | 1.0013..1.0188 | 10/31 |
| helpers | wall | 160.174 | 97.730 | 0.6143 | 0.6055..0.6210 | 31/31 |
| sha | wall | 123.022 | 109.413 | 0.8875 | 0.8813..0.8985 | 31/31 |

## typed-ir-pairs against typed-ir

| workload | timer | typed-ir median ms | typed-ir-pairs median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 55.692 | 50.609 | 0.9020 | 0.8852..0.9181 | 31/31 |
| fib | wall | 59.748 | 54.478 | 0.9068 | 0.8906..0.9244 | 31/31 |
| sum | internal | 9.203 | 9.177 | 0.9997 | 0.9960..1.0009 | 16/31 |
| sum | wall | 12.981 | 12.960 | 0.9970 | 0.9933..1.0033 | 20/31 |
| pipeline | internal | 3.269 | 3.244 | 0.9899 | 0.9745..1.0018 | 18/31 |
| pipeline | wall | 10.236 | 10.216 | 0.9980 | 0.9896..1.0077 | 18/31 |
| helpers | wall | 95.835 | 96.145 | 1.0009 | 0.9981..1.0027 | 13/31 |
| sha | wall | 111.783 | 112.015 | 1.0026 | 0.9988..1.0084 | 12/31 |

## typed-ir-args-split-wrap against typed-ir

| workload | timer | typed-ir median ms | typed-ir-args-split-wrap median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 55.692 | 49.550 | 0.8887 | 0.8832..0.9001 | 31/31 |
| fib | wall | 59.748 | 53.788 | 0.8962 | 0.8911..0.9088 | 31/31 |
| sum | internal | 9.203 | 9.239 | 1.0045 | 0.9999..1.0104 | 11/31 |
| sum | wall | 12.981 | 12.978 | 1.0044 | 0.9998..1.0070 | 11/31 |
| pipeline | internal | 3.269 | 3.257 | 0.9963 | 0.9820..1.0064 | 16/31 |
| pipeline | wall | 10.236 | 10.190 | 0.9966 | 0.9915..1.0078 | 16/31 |
| helpers | wall | 95.835 | 98.178 | 1.0244 | 1.0205..1.0287 | 2/31 |
| sha | wall | 111.783 | 115.899 | 1.0389 | 1.0301..1.0422 | 0/31 |

## typed-ir-all against typed-ir

| workload | timer | typed-ir median ms | typed-ir-all median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 55.692 | 49.070 | 0.8757 | 0.8546..0.9021 | 30/31 |
| fib | wall | 59.748 | 53.333 | 0.8835 | 0.8654..0.9089 | 30/31 |
| sum | internal | 9.203 | 9.366 | 1.0151 | 1.0108..1.0333 | 6/31 |
| sum | wall | 12.981 | 13.182 | 1.0166 | 1.0075..1.0266 | 7/31 |
| pipeline | internal | 3.269 | 3.297 | 1.0054 | 0.9938..1.0178 | 13/31 |
| pipeline | wall | 10.236 | 10.187 | 1.0007 | 0.9908..1.0094 | 15/31 |
| helpers | wall | 95.835 | 97.730 | 1.0174 | 1.0141..1.0213 | 3/31 |
| sha | wall | 111.783 | 109.413 | 0.9807 | 0.9742..0.9849 | 29/31 |

## Builds

| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |
|---|---:|---:|---:|---:|---:|---:|
| fib-legacy-best | 0.37 | 88.7 | 451488 | 294912 | 0 | 3 |
| sum-legacy-best | 0.37 | 88.6 | 451504 | 294912 | 0 | 3 |
| pipeline-legacy-best | 0.37 | 89.8 | 452504 | 294912 | 0 | 4 |
| helpers-legacy-best | 0.37 | 88.7 | 451648 | 294912 | 0 | 7 |
| sha-legacy-best | 2.76 | 152.9 | 767360 | 458752 | 0 | 1 |
| fib-typed-ir | 0.45 | 88.9 | 450464 | 294912 | 3 | 0 |
| sum-typed-ir | 0.45 | 88.9 | 450480 | 294912 | 3 | 0 |
| pipeline-typed-ir | 0.45 | 90.1 | 451472 | 294912 | 3 | 1 |
| helpers-typed-ir | 0.45 | 88.9 | 450624 | 294912 | 7 | 0 |
| sha-typed-ir | 2.42 | 152.2 | 748688 | 442368 | 1 | 0 |
| fib-typed-ir-pairs | 0.46 | 88.9 | 450784 | 294912 | 3 | 0 |
| sum-typed-ir-pairs | 0.46 | 88.9 | 450800 | 294912 | 3 | 0 |
| pipeline-typed-ir-pairs | 0.45 | 90.1 | 451800 | 294912 | 3 | 1 |
| helpers-typed-ir-pairs | 0.44 | 88.9 | 450936 | 294912 | 7 | 0 |
| sha-typed-ir-pairs | 2.44 | 155.2 | 749344 | 442368 | 1 | 0 |
| fib-typed-ir-args-split-wrap | 0.48 | 88.9 | 467792 | 311296 | 3 | 0 |
| sum-typed-ir-args-split-wrap | 0.50 | 88.9 | 467808 | 311296 | 3 | 0 |
| pipeline-typed-ir-args-split-wrap | 0.49 | 90.1 | 468800 | 311296 | 3 | 1 |
| helpers-typed-ir-args-split-wrap | 0.49 | 88.9 | 467952 | 311296 | 7 | 0 |
| sha-typed-ir-args-split-wrap | 2.56 | 156.2 | 783360 | 475136 | 1 | 0 |
| fib-typed-ir-all | 0.48 | 88.9 | 468112 | 311296 | 3 | 0 |
| sum-typed-ir-all | 0.49 | 88.9 | 468128 | 311296 | 3 | 0 |
| pipeline-typed-ir-all | 0.49 | 90.1 | 469112 | 311296 | 3 | 1 |
| helpers-typed-ir-all | 0.49 | 88.9 | 468280 | 311296 | 7 | 0 |
| sha-typed-ir-all | 2.63 | 157.2 | 767536 | 458752 | 1 | 0 |

## Coverage under the backend (root unit)

- fib-typed-ir: $worker.scalar.fib, fib, main
- sum-typed-ir: $worker.scalar.loop, loop, main
- pipeline-typed-ir: above, inc, weighted
- helpers-typed-ir: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-typed-ir: main
- fib-typed-ir-pairs: $worker.scalar.fib, fib, main
- sum-typed-ir-pairs: $worker.scalar.loop, loop, main
- pipeline-typed-ir-pairs: above, inc, weighted
- helpers-typed-ir-pairs: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-typed-ir-pairs: main
- fib-typed-ir-args-split-wrap: $worker.scalar.fib, fib, main
- sum-typed-ir-args-split-wrap: $worker.scalar.loop, loop, main
- pipeline-typed-ir-args-split-wrap: above, inc, weighted
- helpers-typed-ir-args-split-wrap: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-typed-ir-args-split-wrap: main
- fib-typed-ir-all: $worker.scalar.fib, fib, main
- sum-typed-ir-all: $worker.scalar.loop, loop, main
- pipeline-typed-ir-all: above, inc, weighted
- helpers-typed-ir-all: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-typed-ir-all: main

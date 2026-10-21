# M3 paired measurements

revision 0c9c8b73eceece62e17992da006a5995abebfd6c, compiler sha256 056ac615da7c, macOS-27.0.1-arm64-arm-64bit-Mach-O
31 rounds; internal timers: fib, sum, pipeline; process wall: helpers, sha

## typed-ir against legacy

| workload | timer | legacy median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 64.272 | 65.192 | 1.0286 | 0.9841..1.0380 | 11/31 |
| fib | wall | 72.034 | 71.943 | 1.0207 | 1.0054..1.0294 | 10/31 |
| sum | internal | 27.485 | 11.138 | 0.4065 | 0.3986..0.4125 | 31/31 |
| sum | wall | 34.259 | 17.752 | 0.5208 | 0.5119..0.5348 | 31/31 |
| pipeline | internal | 3.214 | 3.364 | 1.0467 | 0.9643..1.0751 | 13/31 |
| pipeline | wall | 14.655 | 14.324 | 1.0072 | 0.9738..1.0349 | 15/31 |
| helpers | wall | 215.580 | 114.218 | 0.5416 | 0.5250..0.5524 | 30/31 |
| sha | wall | 173.161 | 162.099 | 0.9134 | 0.9078..0.9409 | 23/31 |

## typed-ir-noloop against legacy

| workload | timer | legacy median ms | typed-ir-noloop median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 64.272 | 64.709 | 1.0100 | 0.9921..1.0379 | 12/31 |
| fib | wall | 72.034 | 71.711 | 1.0099 | 0.9866..1.0227 | 13/31 |
| sum | internal | 27.485 | 18.745 | 0.6828 | 0.6715..0.7020 | 30/31 |
| sum | wall | 34.259 | 25.805 | 0.7538 | 0.7340..0.7713 | 30/31 |
| pipeline | internal | 3.214 | 3.490 | 1.0857 | 1.0277..1.1274 | 8/31 |
| pipeline | wall | 14.655 | 14.704 | 1.0119 | 0.9901..1.0410 | 12/31 |
| helpers | wall | 215.580 | 113.522 | 0.5421 | 0.5283..0.5516 | 31/31 |
| sha | wall | 173.161 | 162.199 | 0.9367 | 0.9163..0.9529 | 24/31 |

## typed-ir-best against legacy

| workload | timer | legacy median ms | typed-ir-best median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 64.272 | 61.306 | 0.9842 | 0.9708..0.9993 | 22/31 |
| fib | wall | 72.034 | 68.353 | 0.9816 | 0.9577..0.9978 | 21/31 |
| sum | internal | 27.485 | 11.409 | 0.4065 | 0.3993..0.4191 | 31/31 |
| sum | wall | 34.259 | 18.194 | 0.5201 | 0.5114..0.5428 | 31/31 |
| pipeline | internal | 3.214 | 3.452 | 1.0789 | 1.0224..1.1482 | 8/31 |
| pipeline | wall | 14.655 | 14.358 | 1.0083 | 0.9989..1.0429 | 12/31 |
| helpers | wall | 215.580 | 117.249 | 0.5463 | 0.5363..0.5642 | 31/31 |
| sha | wall | 173.161 | 140.252 | 0.8111 | 0.8035..0.8407 | 30/31 |

## typed-ir against legacy-best

| workload | timer | legacy-best median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 57.550 | 65.192 | 1.1395 | 1.1092..1.1607 | 3/31 |
| fib | wall | 64.335 | 71.943 | 1.1319 | 1.0955..1.1460 | 4/31 |
| sum | internal | 16.952 | 11.138 | 0.6611 | 0.6532..0.6687 | 30/31 |
| sum | wall | 23.507 | 17.752 | 0.7474 | 0.7336..0.7660 | 28/31 |
| pipeline | internal | 3.194 | 3.364 | 1.0686 | 0.9937..1.1239 | 11/31 |
| pipeline | wall | 13.967 | 14.324 | 1.0176 | 1.0021..1.0408 | 10/31 |
| helpers | wall | 191.654 | 114.218 | 0.6006 | 0.5885..0.6224 | 30/31 |
| sha | wall | 150.981 | 162.099 | 1.0735 | 1.0402..1.0878 | 7/31 |

## typed-ir-noloop against legacy-best

| workload | timer | legacy-best median ms | typed-ir-noloop median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 57.550 | 64.709 | 1.1278 | 1.1059..1.1518 | 3/31 |
| fib | wall | 64.335 | 71.711 | 1.1121 | 1.0984..1.1396 | 4/31 |
| sum | internal | 16.952 | 18.745 | 1.1132 | 1.1041..1.1313 | 4/31 |
| sum | wall | 23.507 | 25.805 | 1.0752 | 1.0611..1.1201 | 5/31 |
| pipeline | internal | 3.194 | 3.490 | 1.0806 | 1.0430..1.1746 | 5/31 |
| pipeline | wall | 13.967 | 14.704 | 1.0364 | 0.9984..1.0699 | 12/31 |
| helpers | wall | 191.654 | 113.522 | 0.5952 | 0.5808..0.6070 | 31/31 |
| sha | wall | 150.981 | 162.199 | 1.0718 | 1.0454..1.0946 | 5/31 |

## typed-ir-best against legacy-best

| workload | timer | legacy-best median ms | typed-ir-best median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 57.550 | 61.306 | 1.0923 | 1.0694..1.1047 | 4/31 |
| fib | wall | 64.335 | 68.353 | 1.0838 | 1.0655..1.0938 | 5/31 |
| sum | internal | 16.952 | 11.409 | 0.6616 | 0.6566..0.6659 | 31/31 |
| sum | wall | 23.507 | 18.194 | 0.7449 | 0.7353..0.7936 | 30/31 |
| pipeline | internal | 3.194 | 3.452 | 1.0962 | 1.0401..1.1716 | 6/31 |
| pipeline | wall | 13.967 | 14.358 | 1.0578 | 1.0171..1.0749 | 6/31 |
| helpers | wall | 191.654 | 117.249 | 0.6106 | 0.6040..0.6266 | 31/31 |
| sha | wall | 150.981 | 140.252 | 0.9402 | 0.9078..0.9541 | 24/31 |

## Builds

| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |
|---|---:|---:|---:|---:|---:|---:|
| fib-legacy | 0.54 | 88.5 | 449960 | 294912 | 0 | 3 |
| sum-legacy | 0.56 | 88.5 | 449976 | 294912 | 0 | 3 |
| pipeline-legacy | 0.56 | 89.6 | 450992 | 294912 | 0 | 4 |
| helpers-legacy | 0.57 | 88.5 | 466672 | 311296 | 0 | 7 |
| sha-legacy | 4.39 | 145.5 | 764232 | 458752 | 0 | 1 |
| fib-legacy-best | 0.51 | 88.5 | 451488 | 294912 | 0 | 3 |
| sum-legacy-best | 0.56 | 88.5 | 451504 | 294912 | 0 | 3 |
| pipeline-legacy-best | 0.52 | 89.6 | 452504 | 294912 | 0 | 4 |
| helpers-legacy-best | 0.64 | 88.5 | 451648 | 294912 | 0 | 7 |
| sha-legacy-best | 5.31 | 151.0 | 767360 | 458752 | 0 | 1 |
| fib-typed-ir | 0.57 | 88.8 | 466944 | 311296 | 2 | 1 |
| sum-typed-ir | 0.61 | 88.8 | 466960 | 311296 | 2 | 1 |
| pipeline-typed-ir | 0.72 | 89.9 | 467936 | 311296 | 3 | 1 |
| helpers-typed-ir | 1.46 | 88.8 | 467088 | 311296 | 6 | 1 |
| sha-typed-ir | 4.19 | 148.4 | 781632 | 475136 | 0 | 1 |
| fib-typed-ir-noloop | 0.56 | 88.8 | 467232 | 311296 | 2 | 1 |
| sum-typed-ir-noloop | 0.70 | 88.8 | 467248 | 311296 | 2 | 1 |
| pipeline-typed-ir-noloop | 0.58 | 89.9 | 468232 | 311296 | 3 | 1 |
| helpers-typed-ir-noloop | 0.65 | 88.8 | 467384 | 311296 | 6 | 1 |
| sha-typed-ir-noloop | 3.87 | 151.1 | 782224 | 475136 | 0 | 1 |
| fib-typed-ir-best | 0.63 | 88.8 | 468448 | 311296 | 2 | 1 |
| sum-typed-ir-best | 0.56 | 88.8 | 468464 | 311296 | 2 | 1 |
| pipeline-typed-ir-best | 0.63 | 89.9 | 469464 | 311296 | 3 | 1 |
| helpers-typed-ir-best | 0.65 | 88.8 | 468600 | 311296 | 6 | 1 |
| sha-typed-ir-best | 4.34 | 159.4 | 768288 | 458752 | 0 | 1 |

## Coverage under the backend (root unit)

- fib-typed-ir: $worker.scalar.fib, fib
- sum-typed-ir: $worker.scalar.loop, loop
- pipeline-typed-ir: above, inc, weighted
- helpers-typed-ir: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, mix, twice
- fib-typed-ir-noloop: $worker.scalar.fib, fib
- sum-typed-ir-noloop: $worker.scalar.loop, loop
- pipeline-typed-ir-noloop: above, inc, weighted
- helpers-typed-ir-noloop: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, mix, twice
- fib-typed-ir-best: $worker.scalar.fib, fib
- sum-typed-ir-best: $worker.scalar.loop, loop
- pipeline-typed-ir-best: above, inc, weighted
- helpers-typed-ir-best: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, mix, twice

# M3 paired measurements

revision 9a601786d8f17ddba5ede49ccb7e0e2e55d5d12c, compiler sha256 94ea3852c8ef, macOS-27.0.1-arm64-arm-64bit-Mach-O
31 rounds; internal timers: fib, sum, pipeline; process wall: helpers, sha

## typed-ir against legacy

| workload | timer | legacy median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 61.305 | 63.014 | 1.0272 | 1.0197..1.0436 | 6/31 |
| fib | wall | 67.943 | 69.524 | 1.0302 | 1.0138..1.0443 | 7/31 |
| sum | internal | 26.537 | 10.725 | 0.4045 | 0.4003..0.4080 | 31/31 |
| sum | wall | 33.388 | 17.298 | 0.5189 | 0.5066..0.5292 | 31/31 |
| pipeline | internal | 3.153 | 3.238 | 1.0267 | 1.0032..1.0498 | 10/31 |
| pipeline | wall | 13.743 | 14.061 | 1.0037 | 0.9619..1.0699 | 14/31 |
| helpers | wall | 206.164 | 111.063 | 0.5410 | 0.5354..0.5487 | 31/31 |
| sha | wall | 169.752 | 135.694 | 0.7946 | 0.7838..0.8037 | 31/31 |

## typed-ir-best against legacy

| workload | timer | legacy median ms | typed-ir-best median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 61.305 | 63.702 | 1.0362 | 1.0152..1.0575 | 6/31 |
| fib | wall | 67.943 | 70.027 | 1.0251 | 1.0137..1.0461 | 6/31 |
| sum | internal | 26.537 | 10.669 | 0.4014 | 0.3975..0.4041 | 31/31 |
| sum | wall | 33.388 | 17.201 | 0.5222 | 0.5159..0.5292 | 31/31 |
| pipeline | internal | 3.153 | 3.237 | 1.0130 | 0.9787..1.0726 | 12/31 |
| pipeline | wall | 13.743 | 13.824 | 1.0104 | 0.9890..1.0431 | 14/31 |
| helpers | wall | 206.164 | 111.395 | 0.5457 | 0.5376..0.5498 | 31/31 |
| sha | wall | 169.752 | 135.293 | 0.7937 | 0.7796..0.8119 | 30/31 |

## typed-ir-entry against legacy

| workload | timer | legacy median ms | typed-ir-entry median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 61.305 | 63.836 | 1.0440 | 1.0283..1.0501 | 2/31 |
| fib | wall | 67.943 | 70.570 | 1.0381 | 1.0255..1.0497 | 3/31 |
| sum | internal | 26.537 | 10.725 | 0.4032 | 0.3999..0.4057 | 31/31 |
| sum | wall | 33.388 | 17.137 | 0.5192 | 0.5105..0.5305 | 31/31 |
| pipeline | internal | 3.153 | 3.279 | 1.0262 | 1.0056..1.1189 | 9/31 |
| pipeline | wall | 13.743 | 13.828 | 1.0090 | 0.9844..1.0260 | 14/31 |
| helpers | wall | 206.164 | 111.340 | 0.5484 | 0.5440..0.5523 | 31/31 |
| sha | wall | 169.752 | 131.934 | 0.7759 | 0.7655..0.7844 | 30/31 |

## typed-ir against legacy-best

| workload | timer | legacy-best median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 55.854 | 63.014 | 1.1236 | 1.1091..1.1328 | 3/31 |
| fib | wall | 62.433 | 69.524 | 1.1129 | 1.0935..1.1219 | 3/31 |
| sum | internal | 16.189 | 10.725 | 0.6654 | 0.6585..0.6715 | 31/31 |
| sum | wall | 22.792 | 17.298 | 0.7639 | 0.7410..0.7682 | 31/31 |
| pipeline | internal | 3.167 | 3.238 | 1.0221 | 0.9505..1.0600 | 14/31 |
| pipeline | wall | 13.677 | 14.061 | 0.9975 | 0.9876..1.0401 | 16/31 |
| helpers | wall | 190.234 | 111.063 | 0.5874 | 0.5802..0.5941 | 31/31 |
| sha | wall | 143.702 | 135.694 | 0.9375 | 0.9212..0.9590 | 29/31 |

## typed-ir-best against legacy-best

| workload | timer | legacy-best median ms | typed-ir-best median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 55.854 | 63.702 | 1.1286 | 1.1087..1.1415 | 2/31 |
| fib | wall | 62.433 | 70.027 | 1.1083 | 1.0942..1.1224 | 3/31 |
| sum | internal | 16.189 | 10.669 | 0.6631 | 0.6553..0.6691 | 31/31 |
| sum | wall | 22.792 | 17.201 | 0.7567 | 0.7518..0.7682 | 31/31 |
| pipeline | internal | 3.167 | 3.237 | 0.9933 | 0.9656..1.0749 | 17/31 |
| pipeline | wall | 13.677 | 13.824 | 1.0029 | 0.9876..1.0388 | 15/31 |
| helpers | wall | 190.234 | 111.395 | 0.5878 | 0.5812..0.5944 | 31/31 |
| sha | wall | 143.702 | 135.293 | 0.9500 | 0.9157..0.9574 | 29/31 |

## typed-ir-entry against legacy-best

| workload | timer | legacy-best median ms | typed-ir-entry median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 55.854 | 63.836 | 1.1311 | 1.1274..1.1552 | 3/31 |
| fib | wall | 62.433 | 70.570 | 1.1225 | 1.1109..1.1306 | 3/31 |
| sum | internal | 16.189 | 10.725 | 0.6610 | 0.6556..0.6732 | 29/31 |
| sum | wall | 22.792 | 17.137 | 0.7632 | 0.7446..0.7756 | 29/31 |
| pipeline | internal | 3.167 | 3.279 | 1.0129 | 0.9839..1.0682 | 14/31 |
| pipeline | wall | 13.677 | 13.828 | 1.0079 | 0.9801..1.0495 | 14/31 |
| helpers | wall | 190.234 | 111.340 | 0.5871 | 0.5792..0.6022 | 31/31 |
| sha | wall | 143.702 | 131.934 | 0.9053 | 0.8921..0.9303 | 28/31 |

## typed-ir-best against typed-ir

| workload | timer | typed-ir median ms | typed-ir-best median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 63.014 | 63.702 | 1.0083 | 0.9916..1.0201 | 13/31 |
| fib | wall | 69.524 | 70.027 | 1.0084 | 0.9961..1.0111 | 13/31 |
| sum | internal | 10.725 | 10.669 | 0.9938 | 0.9820..1.0071 | 18/31 |
| sum | wall | 17.298 | 17.201 | 1.0039 | 0.9911..1.0251 | 13/31 |
| pipeline | internal | 3.238 | 3.237 | 0.9810 | 0.9593..1.0408 | 17/31 |
| pipeline | wall | 14.061 | 13.824 | 0.9999 | 0.9656..1.0332 | 16/31 |
| helpers | wall | 111.063 | 111.395 | 0.9995 | 0.9919..1.0068 | 16/31 |
| sha | wall | 135.694 | 135.293 | 0.9999 | 0.9820..1.0057 | 16/31 |

## typed-ir-entry against typed-ir

| workload | timer | typed-ir median ms | typed-ir-entry median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 63.014 | 63.836 | 1.0082 | 0.9975..1.0202 | 12/31 |
| fib | wall | 69.524 | 70.570 | 1.0114 | 0.9995..1.0245 | 11/31 |
| sum | internal | 10.725 | 10.725 | 0.9930 | 0.9850..1.0047 | 18/31 |
| sum | wall | 17.298 | 17.137 | 0.9994 | 0.9789..1.0249 | 16/31 |
| pipeline | internal | 3.238 | 3.279 | 1.0167 | 0.9775..1.0745 | 13/31 |
| pipeline | wall | 14.061 | 13.828 | 0.9988 | 0.9786..1.0319 | 16/31 |
| helpers | wall | 111.063 | 111.340 | 1.0040 | 0.9987..1.0131 | 12/31 |
| sha | wall | 135.694 | 131.934 | 0.9765 | 0.9663..0.9801 | 24/31 |

## Builds

| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |
|---|---:|---:|---:|---:|---:|---:|
| fib-legacy | 0.49 | 88.5 | 449960 | 294912 | 0 | 3 |
| sum-legacy | 0.48 | 88.6 | 449976 | 294912 | 0 | 3 |
| pipeline-legacy | 0.50 | 89.6 | 450992 | 294912 | 0 | 4 |
| helpers-legacy | 0.52 | 88.5 | 466672 | 311296 | 0 | 7 |
| sha-legacy | 3.38 | 145.1 | 764232 | 458752 | 0 | 1 |
| fib-legacy-best | 0.71 | 88.5 | 451488 | 294912 | 0 | 3 |
| sum-legacy-best | 0.53 | 88.5 | 451504 | 294912 | 0 | 3 |
| pipeline-legacy-best | 0.59 | 89.6 | 452504 | 294912 | 0 | 4 |
| helpers-legacy-best | 0.53 | 88.5 | 451648 | 294912 | 0 | 7 |
| sha-legacy-best | 3.93 | 151.1 | 767360 | 458752 | 0 | 1 |
| fib-typed-ir | 0.65 | 88.8 | 450464 | 294912 | 3 | 0 |
| sum-typed-ir | 0.66 | 88.8 | 450480 | 294912 | 3 | 0 |
| pipeline-typed-ir | 0.63 | 90.0 | 451472 | 294912 | 3 | 1 |
| helpers-typed-ir | 0.58 | 88.8 | 450624 | 294912 | 7 | 0 |
| sha-typed-ir | 4.28 | 151.1 | 748688 | 442368 | 1 | 0 |
| fib-typed-ir-best | 0.69 | 88.9 | 451968 | 294912 | 3 | 0 |
| sum-typed-ir-best | 0.72 | 88.8 | 451984 | 294912 | 3 | 0 |
| pipeline-typed-ir-best | 0.78 | 90.0 | 452984 | 294912 | 3 | 1 |
| helpers-typed-ir-best | 0.68 | 88.8 | 452152 | 294912 | 7 | 0 |
| sha-typed-ir-best | 3.48 | 151.4 | 751856 | 442368 | 1 | 0 |
| fib-typed-ir-entry | 0.58 | 88.8 | 450976 | 294912 | 3 | 0 |
| sum-typed-ir-entry | 0.57 | 88.8 | 450976 | 294912 | 3 | 0 |
| pipeline-typed-ir-entry | 0.57 | 90.0 | 451976 | 294912 | 3 | 1 |
| helpers-typed-ir-entry | 0.61 | 88.8 | 451144 | 294912 | 7 | 0 |
| sha-typed-ir-entry | 2.93 | 156.1 | 733248 | 425984 | 1 | 0 |

## Coverage under the backend (root unit)

- fib-typed-ir: $worker.scalar.fib, fib, main
- sum-typed-ir: $worker.scalar.loop, loop, main
- pipeline-typed-ir: above, inc, weighted
- helpers-typed-ir: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-typed-ir: main
- fib-typed-ir-best: $worker.scalar.fib, fib, main
- sum-typed-ir-best: $worker.scalar.loop, loop, main
- pipeline-typed-ir-best: above, inc, weighted
- helpers-typed-ir-best: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-typed-ir-best: main
- fib-typed-ir-entry: $worker.scalar.fib, fib, main
- sum-typed-ir-entry: $worker.scalar.loop, loop, main
- pipeline-typed-ir-entry: above, inc, weighted
- helpers-typed-ir-entry: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-typed-ir-entry: main

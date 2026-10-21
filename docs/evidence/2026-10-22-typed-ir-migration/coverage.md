# M3 paired measurements

revision 7c6f8aff25b7c50c3b284b0ba8b2a708b1f346ea, compiler sha256 da2b0e38af3d, macOS-27.0.1-arm64-arm-64bit-Mach-O
31 rounds; internal timers: fib, sum, pipeline; process wall: helpers, sha

## typed-ir against legacy

| workload | timer | legacy median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 63.977 | 65.753 | 1.0211 | 1.0082..1.0487 | 10/31 |
| fib | wall | 71.020 | 73.013 | 1.0244 | 1.0152..1.0434 | 10/31 |
| sum | internal | 28.026 | 11.465 | 0.4035 | 0.3829..0.4181 | 31/31 |
| sum | wall | 34.851 | 18.606 | 0.5273 | 0.4944..0.5441 | 31/31 |
| pipeline | internal | 3.359 | 18.460 | 5.6453 | 5.2641..5.9952 | 0/31 |
| pipeline | wall | 14.857 | 30.154 | 2.0418 | 1.8790..2.1177 | 2/31 |
| helpers | wall | 215.904 | 118.261 | 0.5292 | 0.5156..0.5589 | 31/31 |
| sha | wall | 190.672 | 148.472 | 0.7632 | 0.6701..0.8275 | 28/31 |

## typed-ir-best against legacy

| workload | timer | legacy median ms | typed-ir-best median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 63.977 | 67.844 | 1.0480 | 1.0099..1.0921 | 9/31 |
| fib | wall | 71.020 | 75.084 | 1.0506 | 1.0168..1.0702 | 9/31 |
| sum | internal | 28.026 | 11.546 | 0.4125 | 0.3980..0.4301 | 31/31 |
| sum | wall | 34.851 | 18.748 | 0.5272 | 0.5111..0.5433 | 31/31 |
| pipeline | internal | 3.359 | 18.769 | 5.5585 | 5.2633..5.7937 | 0/31 |
| pipeline | wall | 14.857 | 30.578 | 2.0552 | 1.9322..2.1167 | 1/31 |
| helpers | wall | 215.904 | 118.275 | 0.5425 | 0.5256..0.5526 | 30/31 |
| sha | wall | 190.672 | 142.503 | 0.7661 | 0.7013..0.8010 | 27/31 |

## typed-ir-entry against legacy

| workload | timer | legacy median ms | typed-ir-entry median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 63.977 | 66.247 | 1.0339 | 1.0065..1.0536 | 8/31 |
| fib | wall | 71.020 | 73.259 | 1.0272 | 1.0131..1.0429 | 9/31 |
| sum | internal | 28.026 | 11.519 | 0.4099 | 0.3957..0.4176 | 30/31 |
| sum | wall | 34.851 | 18.375 | 0.5217 | 0.5111..0.5465 | 28/31 |
| pipeline | internal | 3.359 | 18.086 | 5.4039 | 5.2052..5.6752 | 0/31 |
| pipeline | wall | 14.857 | 29.520 | 1.9773 | 1.8543..2.1633 | 2/31 |
| helpers | wall | 215.904 | 118.395 | 0.5573 | 0.5336..0.5871 | 31/31 |
| sha | wall | 190.672 | 144.074 | 0.7668 | 0.7138..0.8049 | 30/31 |

## typed-ir against legacy-best

| workload | timer | legacy-best median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 58.638 | 65.753 | 1.1053 | 1.0850..1.1390 | 6/31 |
| fib | wall | 66.648 | 73.013 | 1.0897 | 1.0600..1.1262 | 6/31 |
| sum | internal | 17.431 | 11.465 | 0.6449 | 0.6221..0.6734 | 31/31 |
| sum | wall | 24.438 | 18.606 | 0.7537 | 0.7148..0.7641 | 30/31 |
| pipeline | internal | 3.445 | 18.460 | 5.4597 | 5.2859..5.7664 | 0/31 |
| pipeline | wall | 15.291 | 30.154 | 2.0060 | 1.9351..2.0702 | 0/31 |
| helpers | wall | 202.420 | 118.261 | 0.5770 | 0.5547..0.6091 | 31/31 |
| sha | wall | 160.541 | 148.472 | 0.8759 | 0.8365..0.9252 | 24/31 |

## typed-ir-best against legacy-best

| workload | timer | legacy-best median ms | typed-ir-best median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 58.638 | 67.844 | 1.1192 | 1.0887..1.1768 | 4/31 |
| fib | wall | 66.648 | 75.084 | 1.1036 | 1.0704..1.1596 | 4/31 |
| sum | internal | 17.431 | 11.546 | 0.6560 | 0.6167..0.6911 | 29/31 |
| sum | wall | 24.438 | 18.748 | 0.7434 | 0.7088..0.7771 | 29/31 |
| pipeline | internal | 3.445 | 18.769 | 5.5301 | 5.2014..5.8548 | 0/31 |
| pipeline | wall | 15.291 | 30.578 | 2.0239 | 1.8804..2.0846 | 0/31 |
| helpers | wall | 202.420 | 118.275 | 0.5824 | 0.5745..0.5952 | 30/31 |
| sha | wall | 160.541 | 142.503 | 0.8870 | 0.8591..0.9235 | 25/31 |

## typed-ir-entry against legacy-best

| workload | timer | legacy-best median ms | typed-ir-entry median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 58.638 | 66.247 | 1.1362 | 1.0740..1.1624 | 4/31 |
| fib | wall | 66.648 | 73.259 | 1.1081 | 1.0579..1.1749 | 4/31 |
| sum | internal | 17.431 | 11.519 | 0.6573 | 0.6427..0.6713 | 29/31 |
| sum | wall | 24.438 | 18.375 | 0.7537 | 0.7243..0.7778 | 27/31 |
| pipeline | internal | 3.445 | 18.086 | 5.4164 | 5.2471..5.6926 | 0/31 |
| pipeline | wall | 15.291 | 29.520 | 1.9902 | 1.8958..2.0421 | 0/31 |
| helpers | wall | 202.420 | 118.395 | 0.5869 | 0.5738..0.6090 | 31/31 |
| sha | wall | 160.541 | 144.074 | 0.8932 | 0.8684..0.9192 | 25/31 |

## typed-ir-best against typed-ir

| workload | timer | typed-ir median ms | typed-ir-best median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 65.753 | 67.844 | 1.0302 | 0.9861..1.0537 | 12/31 |
| fib | wall | 73.013 | 75.084 | 1.0291 | 0.9964..1.0642 | 11/31 |
| sum | internal | 11.465 | 11.546 | 1.0336 | 0.9767..1.0689 | 13/31 |
| sum | wall | 18.606 | 18.748 | 0.9896 | 0.9729..1.0408 | 17/31 |
| pipeline | internal | 18.460 | 18.769 | 1.0004 | 0.9746..1.0429 | 15/31 |
| pipeline | wall | 30.154 | 30.578 | 1.0150 | 0.9790..1.0358 | 13/31 |
| helpers | wall | 118.261 | 118.275 | 1.0008 | 0.9601..1.0351 | 15/31 |
| sha | wall | 148.472 | 142.503 | 1.0124 | 0.9678..1.0431 | 12/31 |

## typed-ir-entry against typed-ir

| workload | timer | typed-ir median ms | typed-ir-entry median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 65.753 | 66.247 | 1.0015 | 0.9877..1.0388 | 15/31 |
| fib | wall | 73.013 | 73.259 | 1.0026 | 0.9782..1.0255 | 15/31 |
| sum | internal | 11.465 | 11.519 | 1.0204 | 0.9804..1.0333 | 13/31 |
| sum | wall | 18.606 | 18.375 | 0.9897 | 0.9666..1.0158 | 17/31 |
| pipeline | internal | 18.460 | 18.086 | 0.9743 | 0.9630..0.9915 | 22/31 |
| pipeline | wall | 30.154 | 29.520 | 0.9759 | 0.9652..1.0180 | 19/31 |
| helpers | wall | 118.261 | 118.395 | 1.0022 | 0.9924..1.0362 | 15/31 |
| sha | wall | 148.472 | 144.074 | 0.9891 | 0.9396..1.0678 | 16/31 |

## Builds

| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |
|---|---:|---:|---:|---:|---:|---:|
| fib-legacy | 0.56 | 88.5 | 449960 | 294912 | 0 | 3 |
| sum-legacy | 0.55 | 88.5 | 449976 | 294912 | 0 | 3 |
| pipeline-legacy | 0.45 | 89.6 | 450992 | 294912 | 0 | 4 |
| helpers-legacy | 0.47 | 88.5 | 466672 | 311296 | 0 | 7 |
| sha-legacy | 3.50 | 145.2 | 764232 | 458752 | 0 | 1 |
| fib-legacy-best | 0.53 | 88.5 | 451488 | 294912 | 0 | 3 |
| sum-legacy-best | 0.51 | 88.6 | 451504 | 294912 | 0 | 3 |
| pipeline-legacy-best | 0.46 | 89.6 | 452504 | 294912 | 0 | 4 |
| helpers-legacy-best | 0.45 | 88.6 | 451648 | 294912 | 0 | 7 |
| sha-legacy-best | 3.88 | 153.0 | 767360 | 458752 | 0 | 1 |
| fib-typed-ir | 0.57 | 88.8 | 450432 | 294912 | 3 | 0 |
| sum-typed-ir | 0.60 | 88.8 | 450464 | 294912 | 3 | 0 |
| pipeline-typed-ir | 0.62 | 89.9 | 450608 | 294912 | 4 | 0 |
| helpers-typed-ir | 0.59 | 88.8 | 450608 | 294912 | 7 | 0 |
| sha-typed-ir | 3.11 | 152.6 | 748640 | 442368 | 1 | 0 |
| fib-typed-ir-best | 1.02 | 88.8 | 451952 | 294912 | 3 | 0 |
| sum-typed-ir-best | 0.86 | 88.9 | 451968 | 294912 | 3 | 0 |
| pipeline-typed-ir-best | 0.61 | 89.9 | 452120 | 294912 | 4 | 0 |
| helpers-typed-ir-best | 0.65 | 88.8 | 452120 | 294912 | 7 | 0 |
| sha-typed-ir-best | 3.46 | 163.2 | 751792 | 442368 | 1 | 0 |
| fib-typed-ir-entry | 0.55 | 88.8 | 450944 | 294912 | 3 | 0 |
| sum-typed-ir-entry | 0.74 | 88.8 | 450960 | 294912 | 3 | 0 |
| pipeline-typed-ir-entry | 0.84 | 89.8 | 451112 | 294912 | 4 | 0 |
| helpers-typed-ir-entry | 0.85 | 88.8 | 451112 | 294912 | 7 | 0 |
| sha-typed-ir-entry | 5.01 | 146.4 | 733184 | 425984 | 1 | 0 |

## Coverage under the backend (root unit)

- fib-typed-ir: $worker.scalar.fib, fib, main
- sum-typed-ir: $worker.scalar.loop, loop, main
- pipeline-typed-ir: above, inc, main, weighted
- helpers-typed-ir: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-typed-ir: main
- fib-typed-ir-best: $worker.scalar.fib, fib, main
- sum-typed-ir-best: $worker.scalar.loop, loop, main
- pipeline-typed-ir-best: above, inc, main, weighted
- helpers-typed-ir-best: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-typed-ir-best: main
- fib-typed-ir-entry: $worker.scalar.fib, fib, main
- sum-typed-ir-entry: $worker.scalar.loop, loop, main
- pipeline-typed-ir-entry: above, inc, main, weighted
- helpers-typed-ir-entry: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-typed-ir-entry: main

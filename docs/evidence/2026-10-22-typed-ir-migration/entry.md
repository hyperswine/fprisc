# M3 paired measurements

revision 0c9c8b73eceece62e17992da006a5995abebfd6c, compiler sha256 3092dce37495, macOS-27.0.1-arm64-arm-64bit-Mach-O
31 rounds; internal timers: fib, sum, pipeline; process wall: helpers, sha

## typed-ir against legacy-best

| workload | timer | legacy-best median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 60.258 | 67.848 | 1.1128 | 1.0987..1.1341 | 3/31 |
| fib | wall | 67.275 | 75.089 | 1.0988 | 1.0764..1.1207 | 3/31 |
| sum | internal | 17.772 | 11.821 | 0.6666 | 0.6363..0.6753 | 30/31 |
| sum | wall | 24.748 | 19.061 | 0.7682 | 0.7371..0.7953 | 30/31 |
| pipeline | internal | 3.362 | 3.480 | 1.0121 | 0.9557..1.0587 | 13/31 |
| pipeline | wall | 15.125 | 15.318 | 0.9885 | 0.9418..1.0519 | 16/31 |
| helpers | wall | 205.059 | 120.784 | 0.5839 | 0.5622..0.5972 | 30/31 |
| sha | wall | 161.183 | 176.054 | 1.0852 | 1.0659..1.1078 | 4/31 |

## typed-ir-shallow against legacy-best

| workload | timer | legacy-best median ms | typed-ir-shallow median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 60.258 | 67.824 | 1.1208 | 1.0999..1.1491 | 5/31 |
| fib | wall | 67.275 | 74.616 | 1.1121 | 1.0877..1.1230 | 5/31 |
| sum | internal | 17.772 | 11.797 | 0.6596 | 0.6426..0.6727 | 30/31 |
| sum | wall | 24.748 | 18.979 | 0.7633 | 0.7230..0.7996 | 30/31 |
| pipeline | internal | 3.362 | 3.512 | 1.0757 | 1.0151..1.0995 | 10/31 |
| pipeline | wall | 15.125 | 16.453 | 1.0431 | 0.9966..1.1154 | 10/31 |
| helpers | wall | 205.059 | 120.016 | 0.5878 | 0.5826..0.6037 | 30/31 |
| sha | wall | 161.183 | 171.788 | 1.0658 | 0.9929..1.0796 | 11/31 |

## typed-ir-forward against legacy-best

| workload | timer | legacy-best median ms | typed-ir-forward median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 60.258 | 67.558 | 1.1324 | 1.0881..1.1584 | 3/31 |
| fib | wall | 67.275 | 74.687 | 1.1150 | 1.0766..1.1359 | 4/31 |
| sum | internal | 17.772 | 11.672 | 0.6524 | 0.6179..0.6690 | 30/31 |
| sum | wall | 24.748 | 18.927 | 0.7558 | 0.7040..0.7770 | 29/31 |
| pipeline | internal | 3.362 | 3.518 | 1.0547 | 0.9633..1.1071 | 11/31 |
| pipeline | wall | 15.125 | 15.385 | 0.9777 | 0.9269..1.0559 | 18/31 |
| helpers | wall | 205.059 | 120.417 | 0.5990 | 0.5726..0.6225 | 31/31 |
| sha | wall | 161.183 | 170.839 | 1.0779 | 1.0565..1.0911 | 6/31 |

## typed-ir-entry against legacy-best

| workload | timer | legacy-best median ms | typed-ir-entry median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 60.258 | 66.795 | 1.1251 | 1.1066..1.1379 | 2/31 |
| fib | wall | 67.275 | 73.522 | 1.1008 | 1.0771..1.1206 | 3/31 |
| sum | internal | 17.772 | 11.623 | 0.6432 | 0.6308..0.6683 | 29/31 |
| sum | wall | 24.748 | 18.730 | 0.7400 | 0.7201..0.7626 | 29/31 |
| pipeline | internal | 3.362 | 3.660 | 1.0415 | 1.0238..1.0942 | 9/31 |
| pipeline | wall | 15.125 | 14.737 | 0.9769 | 0.9507..1.0029 | 20/31 |
| helpers | wall | 205.059 | 118.529 | 0.5905 | 0.5724..0.6064 | 31/31 |
| sha | wall | 161.183 | 171.308 | 1.0541 | 1.0401..1.0896 | 7/31 |

## typed-ir-shallow against typed-ir

| workload | timer | typed-ir median ms | typed-ir-shallow median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 67.848 | 67.824 | 0.9995 | 0.9788..1.0195 | 16/31 |
| fib | wall | 75.089 | 74.616 | 0.9965 | 0.9844..1.0233 | 16/31 |
| sum | internal | 11.821 | 11.797 | 1.0045 | 0.9588..1.0415 | 15/31 |
| sum | wall | 19.061 | 18.979 | 1.0165 | 0.9622..1.0448 | 14/31 |
| pipeline | internal | 3.480 | 3.512 | 1.0096 | 0.9707..1.0719 | 15/31 |
| pipeline | wall | 15.318 | 16.453 | 1.0903 | 1.0500..1.1169 | 7/31 |
| helpers | wall | 120.784 | 120.016 | 0.9969 | 0.9924..1.0073 | 18/31 |
| sha | wall | 176.054 | 171.788 | 0.9816 | 0.9539..0.9978 | 23/31 |

## typed-ir-forward against typed-ir

| workload | timer | typed-ir median ms | typed-ir-forward median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 67.848 | 67.558 | 1.0034 | 0.9836..1.0241 | 14/31 |
| fib | wall | 75.089 | 74.687 | 1.0055 | 0.9815..1.0148 | 13/31 |
| sum | internal | 11.821 | 11.672 | 0.9848 | 0.9478..1.0215 | 18/31 |
| sum | wall | 19.061 | 18.927 | 0.9974 | 0.9415..1.0206 | 16/31 |
| pipeline | internal | 3.480 | 3.518 | 1.0046 | 0.9607..1.0486 | 15/31 |
| pipeline | wall | 15.318 | 15.385 | 0.9918 | 0.9516..1.0343 | 18/31 |
| helpers | wall | 120.784 | 120.417 | 1.0039 | 0.9904..1.0357 | 15/31 |
| sha | wall | 176.054 | 170.839 | 0.9866 | 0.9678..1.0005 | 20/31 |

## typed-ir-entry against typed-ir

| workload | timer | typed-ir median ms | typed-ir-entry median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 67.848 | 66.795 | 0.9971 | 0.9716..1.0189 | 17/31 |
| fib | wall | 75.089 | 73.522 | 0.9814 | 0.9773..1.0256 | 20/31 |
| sum | internal | 11.821 | 11.623 | 0.9939 | 0.9622..1.0301 | 16/31 |
| sum | wall | 19.061 | 18.730 | 0.9804 | 0.9456..1.0062 | 19/31 |
| pipeline | internal | 3.480 | 3.660 | 1.0066 | 0.9752..1.0713 | 14/31 |
| pipeline | wall | 15.318 | 14.737 | 0.9656 | 0.9348..1.0251 | 19/31 |
| helpers | wall | 120.784 | 118.529 | 0.9988 | 0.9891..1.0069 | 18/31 |
| sha | wall | 176.054 | 171.308 | 0.9718 | 0.9615..1.0060 | 19/31 |

## Builds

| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |
|---|---:|---:|---:|---:|---:|---:|
| fib-legacy-best | 0.77 | 88.4 | 451488 | 294912 | 0 | 3 |
| sum-legacy-best | 0.70 | 88.4 | 451504 | 294912 | 0 | 3 |
| pipeline-legacy-best | 0.57 | 89.5 | 452504 | 294912 | 0 | 4 |
| helpers-legacy-best | 0.49 | 88.4 | 451648 | 294912 | 0 | 7 |
| sha-legacy-best | 4.00 | 150.9 | 767360 | 458752 | 0 | 1 |
| fib-typed-ir | 0.61 | 88.8 | 466944 | 311296 | 2 | 1 |
| sum-typed-ir | 0.54 | 88.8 | 466960 | 311296 | 2 | 1 |
| pipeline-typed-ir | 0.55 | 89.8 | 467936 | 311296 | 3 | 1 |
| helpers-typed-ir | 0.56 | 88.8 | 467088 | 311296 | 6 | 1 |
| sha-typed-ir | 3.59 | 148.9 | 781632 | 475136 | 0 | 1 |
| fib-typed-ir-shallow | 0.84 | 88.8 | 450696 | 294912 | 2 | 1 |
| sum-typed-ir-shallow | 0.73 | 88.8 | 450712 | 294912 | 2 | 1 |
| pipeline-typed-ir-shallow | 1.14 | 89.8 | 468200 | 311296 | 3 | 1 |
| helpers-typed-ir-shallow | 0.69 | 88.8 | 467352 | 311296 | 6 | 1 |
| sha-typed-ir-shallow | 4.78 | 149.2 | 765672 | 458752 | 0 | 1 |
| fib-typed-ir-forward | 0.56 | 88.8 | 467240 | 311296 | 2 | 1 |
| sum-typed-ir-forward | 0.58 | 88.8 | 467256 | 311296 | 2 | 1 |
| pipeline-typed-ir-forward | 0.56 | 89.8 | 468232 | 311296 | 3 | 1 |
| helpers-typed-ir-forward | 0.58 | 88.8 | 467384 | 311296 | 6 | 1 |
| sha-typed-ir-forward | 3.49 | 151.1 | 782232 | 475136 | 0 | 1 |
| fib-typed-ir-entry | 0.58 | 88.8 | 450976 | 294912 | 2 | 1 |
| sum-typed-ir-entry | 0.96 | 88.8 | 450992 | 294912 | 2 | 1 |
| pipeline-typed-ir-entry | 1.12 | 89.9 | 451976 | 294912 | 3 | 1 |
| helpers-typed-ir-entry | 0.81 | 88.8 | 467640 | 311296 | 6 | 1 |
| sha-typed-ir-entry | 4.04 | 151.3 | 766256 | 458752 | 0 | 1 |

## Coverage under the backend (root unit)

- fib-typed-ir: $worker.scalar.fib, fib
- sum-typed-ir: $worker.scalar.loop, loop
- pipeline-typed-ir: above, inc, weighted
- helpers-typed-ir: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, mix, twice
- fib-typed-ir-shallow: $worker.scalar.fib, fib
- sum-typed-ir-shallow: $worker.scalar.loop, loop
- pipeline-typed-ir-shallow: above, inc, weighted
- helpers-typed-ir-shallow: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, mix, twice
- fib-typed-ir-forward: $worker.scalar.fib, fib
- sum-typed-ir-forward: $worker.scalar.loop, loop
- pipeline-typed-ir-forward: above, inc, weighted
- helpers-typed-ir-forward: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, mix, twice
- fib-typed-ir-entry: $worker.scalar.fib, fib
- sum-typed-ir-entry: $worker.scalar.loop, loop
- pipeline-typed-ir-entry: above, inc, weighted
- helpers-typed-ir-entry: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, mix, twice

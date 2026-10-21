# M3 paired measurements

revision 760f5eb9d09b64c51696b36e9134987fa3039e72, compiler sha256 46af9822386b, macOS-27.0.1-arm64-arm-64bit-Mach-O
31 rounds; internal timers: fib, sum, pipeline; process wall: helpers, sha

## typed-ir against legacy-best

| workload | timer | legacy-best median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 49.358 | 55.268 | 1.1193 | 1.1056..1.1405 | 0/31 |
| fib | wall | 53.516 | 59.617 | 1.1138 | 1.0937..1.1313 | 0/31 |
| sum | internal | 14.514 | 9.204 | 0.6387 | 0.6337..0.6427 | 31/31 |
| sum | wall | 18.368 | 12.985 | 0.7094 | 0.7024..0.7128 | 31/31 |
| pipeline | internal | 3.114 | 3.270 | 1.0527 | 1.0369..1.0666 | 5/31 |
| pipeline | wall | 10.026 | 10.242 | 1.0155 | 1.0106..1.0234 | 4/31 |
| helpers | wall | 164.262 | 95.391 | 0.5832 | 0.5771..0.6003 | 31/31 |
| sha | wall | 122.304 | 111.242 | 0.9126 | 0.9048..0.9146 | 31/31 |

## typed-ir-pairs against legacy-best

| workload | timer | legacy-best median ms | typed-ir-pairs median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 49.358 | 50.966 | 1.0237 | 0.9913..1.0341 | 11/31 |
| fib | wall | 53.516 | 55.212 | 1.0229 | 0.9921..1.0290 | 11/31 |
| sum | internal | 14.514 | 9.163 | 0.6341 | 0.6260..0.6382 | 31/31 |
| sum | wall | 18.368 | 12.977 | 0.7060 | 0.7008..0.7125 | 31/31 |
| pipeline | internal | 3.114 | 3.272 | 1.0540 | 1.0311..1.0703 | 4/31 |
| pipeline | wall | 10.026 | 10.186 | 1.0126 | 1.0064..1.0263 | 9/31 |
| helpers | wall | 164.262 | 95.574 | 0.5887 | 0.5774..0.5975 | 31/31 |
| sha | wall | 122.304 | 111.921 | 0.9142 | 0.9092..0.9178 | 31/31 |

## typed-ir-args against legacy-best

| workload | timer | legacy-best median ms | typed-ir-args median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 49.358 | 53.107 | 1.0589 | 1.0429..1.0814 | 0/31 |
| fib | wall | 53.516 | 57.357 | 1.0538 | 1.0390..1.0771 | 1/31 |
| sum | internal | 14.514 | 9.276 | 0.6353 | 0.6339..0.6453 | 31/31 |
| sum | wall | 18.368 | 13.006 | 0.7095 | 0.7067..0.7156 | 31/31 |
| pipeline | internal | 3.114 | 3.253 | 1.0429 | 1.0366..1.0842 | 4/31 |
| pipeline | wall | 10.026 | 10.238 | 1.0226 | 1.0139..1.0295 | 6/31 |
| helpers | wall | 164.262 | 98.151 | 0.6026 | 0.5948..0.6163 | 31/31 |
| sha | wall | 122.304 | 111.392 | 0.9145 | 0.9092..0.9177 | 30/31 |

## typed-ir-args-split against legacy-best

| workload | timer | legacy-best median ms | typed-ir-args-split median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 49.358 | 50.923 | 1.0286 | 1.0205..1.0352 | 2/31 |
| fib | wall | 53.516 | 55.096 | 1.0279 | 1.0197..1.0313 | 2/31 |
| sum | internal | 14.514 | 11.424 | 0.7877 | 0.7793..0.7934 | 31/31 |
| sum | wall | 18.368 | 15.168 | 0.8254 | 0.8174..0.8324 | 31/31 |
| pipeline | internal | 3.114 | 3.255 | 1.0578 | 1.0140..1.0660 | 6/31 |
| pipeline | wall | 10.026 | 10.173 | 1.0147 | 1.0087..1.0279 | 6/31 |
| helpers | wall | 164.262 | 97.289 | 0.6042 | 0.5898..0.6142 | 31/31 |
| sha | wall | 122.304 | 115.359 | 0.9443 | 0.9378..0.9493 | 31/31 |

## typed-ir-args-split-wrap against legacy-best

| workload | timer | legacy-best median ms | typed-ir-args-split-wrap median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 49.358 | 49.674 | 1.0038 | 0.9927..1.0192 | 14/31 |
| fib | wall | 53.516 | 53.841 | 1.0005 | 0.9922..1.0195 | 15/31 |
| sum | internal | 14.514 | 11.403 | 0.7858 | 0.7801..0.7933 | 31/31 |
| sum | wall | 18.368 | 15.162 | 0.8267 | 0.8179..0.8355 | 30/31 |
| pipeline | internal | 3.114 | 3.301 | 1.0635 | 1.0462..1.0738 | 5/31 |
| pipeline | wall | 10.026 | 10.307 | 1.0250 | 1.0098..1.0347 | 6/31 |
| helpers | wall | 164.262 | 97.370 | 0.5989 | 0.5912..0.6169 | 31/31 |
| sha | wall | 122.304 | 121.450 | 0.9946 | 0.9921..0.9971 | 23/31 |

## typed-ir-all against legacy-best

| workload | timer | legacy-best median ms | typed-ir-all median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 49.358 | 49.610 | 1.0048 | 0.9773..1.0207 | 14/31 |
| fib | wall | 53.516 | 53.791 | 1.0030 | 0.9831..1.0197 | 13/31 |
| sum | internal | 14.514 | 11.413 | 0.7877 | 0.7803..0.7920 | 31/31 |
| sum | wall | 18.368 | 15.222 | 0.8292 | 0.8220..0.8336 | 31/31 |
| pipeline | internal | 3.114 | 3.283 | 1.0526 | 1.0279..1.0685 | 4/31 |
| pipeline | wall | 10.026 | 10.224 | 1.0153 | 1.0023..1.0285 | 9/31 |
| helpers | wall | 164.262 | 97.441 | 0.5966 | 0.5879..0.6132 | 31/31 |
| sha | wall | 122.304 | 114.799 | 0.9388 | 0.9356..0.9424 | 31/31 |

## typed-ir-pairs against typed-ir

| workload | timer | typed-ir median ms | typed-ir-pairs median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 55.268 | 50.966 | 0.9073 | 0.8822..0.9307 | 31/31 |
| fib | wall | 59.617 | 55.212 | 0.9108 | 0.8902..0.9352 | 31/31 |
| sum | internal | 9.204 | 9.163 | 0.9955 | 0.9909..0.9992 | 21/31 |
| sum | wall | 12.985 | 12.977 | 0.9987 | 0.9930..1.0031 | 17/31 |
| pipeline | internal | 3.270 | 3.272 | 0.9997 | 0.9850..1.0120 | 16/31 |
| pipeline | wall | 10.242 | 10.186 | 1.0001 | 0.9868..1.0065 | 15/31 |
| helpers | wall | 95.391 | 95.574 | 1.0010 | 0.9982..1.0032 | 14/31 |
| sha | wall | 111.242 | 111.921 | 1.0042 | 0.9990..1.0076 | 12/31 |

## typed-ir-args against typed-ir

| workload | timer | typed-ir median ms | typed-ir-args median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 55.268 | 53.107 | 0.9500 | 0.9298..0.9625 | 29/31 |
| fib | wall | 59.617 | 57.357 | 0.9543 | 0.9359..0.9691 | 29/31 |
| sum | internal | 9.204 | 9.276 | 0.9993 | 0.9960..1.0020 | 18/31 |
| sum | wall | 12.985 | 13.006 | 1.0025 | 0.9953..1.0078 | 13/31 |
| pipeline | internal | 3.270 | 3.253 | 1.0006 | 0.9780..1.0204 | 15/31 |
| pipeline | wall | 10.242 | 10.238 | 1.0004 | 0.9938..1.0109 | 13/31 |
| helpers | wall | 95.391 | 98.151 | 1.0223 | 1.0199..1.0357 | 2/31 |
| sha | wall | 111.242 | 111.392 | 1.0038 | 0.9935..1.0137 | 13/31 |

## typed-ir-args-split against typed-ir

| workload | timer | typed-ir median ms | typed-ir-args-split median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 55.268 | 50.923 | 0.9206 | 0.9072..0.9277 | 31/31 |
| fib | wall | 59.617 | 55.096 | 0.9257 | 0.9070..0.9371 | 31/31 |
| sum | internal | 9.204 | 11.424 | 1.2400 | 1.2303..1.2447 | 0/31 |
| sum | wall | 12.985 | 15.168 | 1.1695 | 1.1596..1.1795 | 0/31 |
| pipeline | internal | 3.270 | 3.255 | 1.0021 | 0.9791..1.0081 | 15/31 |
| pipeline | wall | 10.242 | 10.173 | 0.9942 | 0.9922..1.0050 | 17/31 |
| helpers | wall | 95.391 | 97.289 | 1.0215 | 1.0162..1.0253 | 3/31 |
| sha | wall | 111.242 | 115.359 | 1.0370 | 1.0288..1.0446 | 1/31 |

## typed-ir-args-split-wrap against typed-ir

| workload | timer | typed-ir median ms | typed-ir-args-split-wrap median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 55.268 | 49.674 | 0.8914 | 0.8815..0.9106 | 31/31 |
| fib | wall | 59.617 | 53.841 | 0.9016 | 0.8922..0.9174 | 30/31 |
| sum | internal | 9.204 | 11.403 | 1.2392 | 1.2302..1.2419 | 0/31 |
| sum | wall | 12.985 | 15.162 | 1.1668 | 1.1587..1.1760 | 0/31 |
| pipeline | internal | 3.270 | 3.301 | 1.0072 | 0.9936..1.0145 | 13/31 |
| pipeline | wall | 10.242 | 10.307 | 1.0009 | 0.9904..1.0129 | 15/31 |
| helpers | wall | 95.391 | 97.370 | 1.0218 | 1.0183..1.0256 | 1/31 |
| sha | wall | 111.242 | 121.450 | 1.0934 | 1.0856..1.0996 | 0/31 |

## typed-ir-all against typed-ir

| workload | timer | typed-ir median ms | typed-ir-all median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 55.268 | 49.610 | 0.8936 | 0.8740..0.9024 | 31/31 |
| fib | wall | 59.617 | 53.791 | 0.9010 | 0.8868..0.9157 | 31/31 |
| sum | internal | 9.204 | 11.413 | 1.2384 | 1.2297..1.2422 | 0/31 |
| sum | wall | 12.985 | 15.222 | 1.1694 | 1.1630..1.1769 | 0/31 |
| pipeline | internal | 3.270 | 3.283 | 0.9946 | 0.9733..1.0126 | 18/31 |
| pipeline | wall | 10.242 | 10.224 | 0.9906 | 0.9856..0.9986 | 22/31 |
| helpers | wall | 95.391 | 97.441 | 1.0215 | 1.0161..1.0246 | 2/31 |
| sha | wall | 111.242 | 114.799 | 1.0340 | 1.0289..1.0379 | 1/31 |

## Builds

| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |
|---|---:|---:|---:|---:|---:|---:|
| fib-legacy-best | 0.37 | 88.7 | 451488 | 294912 | 0 | 3 |
| sum-legacy-best | 0.37 | 88.7 | 451504 | 294912 | 0 | 3 |
| pipeline-legacy-best | 0.37 | 89.8 | 452504 | 294912 | 0 | 4 |
| helpers-legacy-best | 0.37 | 88.7 | 451648 | 294912 | 0 | 7 |
| sha-legacy-best | 2.74 | 153.0 | 767360 | 458752 | 0 | 1 |
| fib-typed-ir | 0.45 | 89.0 | 450464 | 294912 | 3 | 0 |
| sum-typed-ir | 0.44 | 89.0 | 450480 | 294912 | 3 | 0 |
| pipeline-typed-ir | 0.45 | 90.2 | 451472 | 294912 | 3 | 1 |
| helpers-typed-ir | 0.46 | 89.0 | 450624 | 294912 | 7 | 0 |
| sha-typed-ir | 2.44 | 152.2 | 748688 | 442368 | 1 | 0 |
| fib-typed-ir-pairs | 0.45 | 89.0 | 450784 | 294912 | 3 | 0 |
| sum-typed-ir-pairs | 0.45 | 89.0 | 450800 | 294912 | 3 | 0 |
| pipeline-typed-ir-pairs | 0.46 | 90.2 | 451800 | 294912 | 3 | 1 |
| helpers-typed-ir-pairs | 0.44 | 89.0 | 450936 | 294912 | 7 | 0 |
| sha-typed-ir-pairs | 2.44 | 155.2 | 749344 | 442368 | 1 | 0 |
| fib-typed-ir-args | 0.49 | 89.0 | 467344 | 311296 | 3 | 0 |
| sum-typed-ir-args | 0.49 | 89.0 | 467360 | 311296 | 3 | 0 |
| pipeline-typed-ir-args | 0.50 | 90.2 | 468344 | 311296 | 3 | 1 |
| helpers-typed-ir-args | 0.49 | 89.0 | 467496 | 311296 | 7 | 0 |
| sha-typed-ir-args | 2.55 | 152.2 | 782416 | 475136 | 1 | 0 |
| fib-typed-ir-args-split | 0.50 | 89.0 | 467576 | 311296 | 3 | 0 |
| sum-typed-ir-args-split | 0.49 | 88.9 | 467592 | 311296 | 3 | 0 |
| pipeline-typed-ir-args-split | 0.50 | 90.2 | 468592 | 311296 | 3 | 1 |
| helpers-typed-ir-args-split | 0.50 | 89.0 | 467736 | 311296 | 7 | 0 |
| sha-typed-ir-args-split | 2.60 | 147.2 | 782920 | 475136 | 1 | 0 |
| fib-typed-ir-args-split-wrap | 0.50 | 89.0 | 467792 | 311296 | 3 | 0 |
| sum-typed-ir-args-split-wrap | 0.51 | 89.0 | 467808 | 311296 | 3 | 0 |
| pipeline-typed-ir-args-split-wrap | 0.49 | 90.2 | 468800 | 311296 | 3 | 1 |
| helpers-typed-ir-args-split-wrap | 0.49 | 89.0 | 467952 | 311296 | 7 | 0 |
| sha-typed-ir-args-split-wrap | 2.64 | 154.2 | 783360 | 475136 | 1 | 0 |
| fib-typed-ir-all | 0.50 | 89.0 | 468112 | 311296 | 3 | 0 |
| sum-typed-ir-all | 0.48 | 89.0 | 468128 | 311296 | 3 | 0 |
| pipeline-typed-ir-all | 0.50 | 90.2 | 469112 | 311296 | 3 | 1 |
| helpers-typed-ir-all | 0.49 | 89.0 | 468280 | 311296 | 7 | 0 |
| sha-typed-ir-all | 2.64 | 154.2 | 767536 | 458752 | 1 | 0 |

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
- fib-typed-ir-args: $worker.scalar.fib, fib, main
- sum-typed-ir-args: $worker.scalar.loop, loop, main
- pipeline-typed-ir-args: above, inc, weighted
- helpers-typed-ir-args: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-typed-ir-args: main
- fib-typed-ir-args-split: $worker.scalar.fib, fib, main
- sum-typed-ir-args-split: $worker.scalar.loop, loop, main
- pipeline-typed-ir-args-split: above, inc, weighted
- helpers-typed-ir-args-split: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, loop, main, mix, twice
- sha-typed-ir-args-split: main
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

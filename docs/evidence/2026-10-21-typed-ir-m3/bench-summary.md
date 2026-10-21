# M3 paired measurements

revision a8f25f9059799d301724817f6cbc33f4f1b5da29, compiler sha256 4916e8e3d3bb, macOS-27.0.1-arm64-arm-64bit
31 rounds; internal timers: fib, sum, pipeline; process wall: helpers, sha

## typed-ir against legacy

| workload | timer | legacy median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 74.547 | 74.580 | 0.9999 | 0.9993..1.0010 | 17/31 |
| fib | wall | 81.268 | 81.142 | 0.9997 | 0.9971..1.0006 | 17/31 |
| sum | internal | 22.999 | 20.941 | 0.9111 | 0.9095..0.9125 | 31/31 |
| sum | wall | 29.210 | 27.179 | 0.9309 | 0.9296..0.9365 | 31/31 |
| pipeline | internal | 5.298 | 5.298 | 1.0004 | 0.9983..1.0025 | 13/31 |
| pipeline | wall | 17.449 | 17.414 | 0.9942 | 0.9841..1.0149 | 16/31 |
| helpers | wall | 227.992 | 157.737 | 0.6923 | 0.6913..0.6932 | 31/31 |
| sha | wall | 199.314 | 199.527 | 0.9973 | 0.9957..1.0012 | 19/31 |

## typed-ir-noloop against legacy

| workload | timer | legacy median ms | typed-ir-noloop median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 74.547 | 74.553 | 1.0003 | 0.9996..1.0006 | 12/31 |
| fib | wall | 81.268 | 81.313 | 1.0003 | 0.9987..1.0015 | 14/31 |
| sum | internal | 22.999 | 21.209 | 0.9222 | 0.9209..0.9246 | 31/31 |
| sum | wall | 29.210 | 27.448 | 0.9407 | 0.9343..0.9421 | 30/31 |
| pipeline | internal | 5.298 | 5.298 | 1.0004 | 0.9991..1.0024 | 14/31 |
| pipeline | wall | 17.449 | 16.824 | 0.9664 | 0.9599..0.9816 | 26/31 |
| helpers | wall | 227.992 | 157.800 | 0.6923 | 0.6898..0.6928 | 31/31 |
| sha | wall | 199.314 | 199.818 | 1.0021 | 0.9973..1.0068 | 13/31 |

## typed-ir against legacy-best

| workload | timer | legacy-best median ms | typed-ir median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 74.599 | 74.580 | 0.9994 | 0.9988..1.0005 | 20/31 |
| fib | wall | 81.214 | 81.142 | 1.0001 | 0.9970..1.0021 | 15/31 |
| sum | internal | 20.991 | 20.941 | 0.9980 | 0.9969..0.9987 | 23/31 |
| sum | wall | 27.256 | 27.179 | 0.9981 | 0.9923..1.0018 | 18/31 |
| pipeline | internal | 5.303 | 5.298 | 0.9989 | 0.9981..0.9998 | 21/31 |
| pipeline | wall | 17.421 | 17.414 | 1.0017 | 0.9895..1.0138 | 12/31 |
| helpers | wall | 219.907 | 157.737 | 0.7180 | 0.7170..0.7192 | 31/31 |
| sha | wall | 186.384 | 199.527 | 1.0702 | 1.0664..1.0725 | 0/31 |

## typed-ir-noloop against legacy-best

| workload | timer | legacy-best median ms | typed-ir-noloop median ms | median of paired ratios | 95% bootstrap CI | faster pairs |
|---|---|---:|---:|---:|---:|---:|
| fib | internal | 74.599 | 74.553 | 0.9995 | 0.9989..1.0004 | 18/31 |
| fib | wall | 81.214 | 81.313 | 1.0011 | 0.9993..1.0034 | 12/31 |
| sum | internal | 20.991 | 21.209 | 1.0107 | 1.0089..1.0117 | 1/31 |
| sum | wall | 27.256 | 27.448 | 1.0049 | 1.0002..1.0067 | 9/31 |
| pipeline | internal | 5.303 | 5.298 | 0.9983 | 0.9958..1.0008 | 17/31 |
| pipeline | wall | 17.421 | 16.824 | 0.9674 | 0.9585..0.9788 | 24/31 |
| helpers | wall | 219.907 | 157.800 | 0.7179 | 0.7176..0.7183 | 31/31 |
| sha | wall | 186.384 | 199.818 | 1.0723 | 1.0668..1.0755 | 0/31 |

## Builds

| build | compile wall s | compiler max RSS MiB | binary bytes | __TEXT bytes | native functions in the root | legacy functions in the root |
|---|---:|---:|---:|---:|---:|---:|
| fib-legacy | 0.54 | 88.2 | 449912 | 294912 | 0 | 3 |
| sum-legacy | 0.58 | 88.2 | 449928 | 294912 | 0 | 3 |
| pipeline-legacy | 0.54 | 89.3 | 450944 | 294912 | 0 | 4 |
| helpers-legacy | 0.54 | 89.2 | 450064 | 294912 | 0 | 7 |
| sha-legacy | 3.65 | 144.5 | 764184 | 458752 | 0 | 1 |
| fib-legacy-best | 0.55 | 88.2 | 451440 | 294912 | 0 | 3 |
| sum-legacy-best | 0.55 | 88.2 | 451456 | 294912 | 0 | 3 |
| pipeline-legacy-best | 0.54 | 89.3 | 452456 | 294912 | 0 | 4 |
| helpers-legacy-best | 0.54 | 89.2 | 451600 | 294912 | 0 | 7 |
| sha-legacy-best | 4.20 | 154.5 | 767312 | 458752 | 0 | 1 |
| fib-typed-ir | 0.60 | 88.5 | 466896 | 311296 | 2 | 1 |
| sum-typed-ir | 0.60 | 88.5 | 466912 | 311296 | 2 | 1 |
| pipeline-typed-ir | 0.60 | 89.6 | 467888 | 311296 | 3 | 1 |
| helpers-typed-ir | 0.60 | 89.5 | 467040 | 311296 | 4 | 3 |
| sha-typed-ir | 3.71 | 142.8 | 781584 | 475136 | 0 | 1 |
| fib-typed-ir-noloop | 0.60 | 88.5 | 467184 | 311296 | 2 | 1 |
| sum-typed-ir-noloop | 0.60 | 88.5 | 467200 | 311296 | 2 | 1 |
| pipeline-typed-ir-noloop | 0.61 | 89.6 | 468184 | 311296 | 3 | 1 |
| helpers-typed-ir-noloop | 0.60 | 89.5 | 467336 | 311296 | 4 | 3 |
| sha-typed-ir-noloop | 3.71 | 144.8 | 782176 | 475136 | 0 | 1 |

## Coverage under the backend (root unit)

- fib-typed-ir: $worker.scalar.fib, fib
- sum-typed-ir: $worker.scalar.loop, loop
- pipeline-typed-ir: above, inc, weighted
- helpers-typed-ir: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, mix
- fib-typed-ir-noloop: $worker.scalar.fib, fib
- sum-typed-ir-noloop: $worker.scalar.loop, loop
- pipeline-typed-ir-noloop: above, inc, weighted
- helpers-typed-ir-noloop: $spec.rootf8a31802acfe.twice.mono.0, clamp, lerp, mix

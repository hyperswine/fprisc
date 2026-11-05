# Reject scalar lets before scanning their continuations

This is a compiler-cost refinement of
[finite Base field expansion](2026-11-05-FINITE-BASE-FIELD-WORKERS.md).
Codegen remains 191: the admission conditions and emitted program are unchanged.

During constructor-argument preparation, most lets bind scalar computations.
The pass previously scanned their entire continuation for rebinding and
single-call use before checking whether the right-hand side could produce a
constructor. Successive worker rounds repeated those unsuccessful scans.
The shape check now runs first. Constructor candidates still undergo exactly
the same capture, use and movement checks. The supplied-shape scan applies
the same ordering to its existing `shapeOf` test.

These are pure tests over finite Core. Changing their short-circuit order
does not move any source expression, relax admission or change runtime fuel.
No fixed worker count, depth or body limit is reintroduced.

## Measured cost

The [cold compiler comparison](../bench/2026-11-05-field-shape-prefilter-cost.json)
uses the saved qualified compiler from the finite-expansion milestone and the
new compiler, with unchanged source fixtures and separate cold caches:

| Independent wrapper arguments | Previous time | Current time | Previous / current allocation |
| --- | ---: | ---: | ---: |
| 8 | 1.65 s | 1.54 s | 1.666 / 1.666 GB |
| 16 | 0.84 s | 0.76 s | 1.859 / 1.858 GB |
| 32 | 1.82 s | 0.94 s | 2.651 / 2.650 GB |
| 64 | 16.36 s | 1.88 s | 6.816 / 6.814 GB |

These are individual cold compile samples, not runtime throughput measurements.
The 64-argument slowdown is largely removed; compiler allocation remains a
separate scaling cost. Its explicit payload control uses 1.698 GB and 0.74 s.
Root code remains 26,184 bytes with one private worker.

The [code comparison](../bench/2026-11-05-field-shape-prefilter-code.json)
checks all eleven finite-expansion fixtures: five/eight/sixteen nested wrappers,
eight through sixty-four independent arguments, eight returned fields,
129 helpers, and bodies with 256/2,048 additions. Emitted RV64 assembly and
diagnostics are exactly equal after normalizing only the separate cache-root
prefixes. The shared source path is unchanged. This is direct evidence for
retaining codegen revision 191; no new runtime speedup is claimed.

Both focused Haskell suites (`WorkersCheck` and `RegionInterfaces`) pass,
including fallback, shared-entry and exact conditional-fuel oracles. The native
finite-field regression passes all 77 recorded allocation/semantic rows and
normal-region executions. The unchanged absolute compiler gates pass at
**1.61 / 32.80 / 67.51 GB**, with peak live memory **27 / 350 / 501 MB**.
These focused checks belong to the refined compiler; the prior full 41-suite
run remains tied to the preceding compiler in its own manifest.

The checks, inputs and evidence hashes are recorded in the
[validation manifest](../bench/2026-11-05-field-shape-prefilter-validation.json).
The prior host scheduling outliers and physical-timing qualification limits
remain open. This change is a compiler-efficiency improvement supporting the
already measured allocation removal, rather than additional abstraction removal.

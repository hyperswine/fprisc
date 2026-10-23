# Captured NEON maps in the typed backend

This is the first increment of the
[complete typed IR migration goal](2026-10-23-TYPED-IR-COMPLETION.md),
starting at `98abc0c`. AArch64's typed map kernels now accept matching-type
scalar captures in their two-lane NEON body. The former capture-free gate
remains only in the legacy generator, where it will disappear with that
backend. No runtime context or calling-convention change is needed.

## Representation and proof

`SCapture n` refers to a capture operand of `OSimdPair`. Those operands
are explicit SSA uses: substitution, liveness, allocation and verification
all see them. The verifier checks their indices and raw representations.
The kernel builder checks that every capture matches the lane type and
that the profile uses a 64-bit word.

After descriptor/capture guards, Int captures are untagged once before
the pair loop. F64 captures retain their raw word bits. The pair body
broadcasts captures with `dup vN.2d, xM`. The selected stream gives each
broadcast its own instruction/use so reload pressure stays bounded even
with seven captured arguments. Captures survive fuel calls in preserved
registers or frame slots. No vector scratch is live across the fuel call.

Int SIMD remains exactly one addition or subtraction over fitting lanes,
captures and constants. The result fits a machine word, and each lane's
63-bit fit is checked. Longer Int chains use the scalar typed kernel so
an overflowing intermediate cannot be hidden by a later operation.
F64 supports ordered expression trees of addition, subtraction and
multiplication; there is no FMA contraction or reassociation. Division,
mixed capture types, oversized expressions and unsupported callbacks keep
the scalar path. The planner checks the expanded expression's actual
scratch budget, including repeated subexpressions, before selecting SIMD.

The loop retains the existing counted-fuel policy, scalar odd tail,
descriptor guards and generic fallback. At most fifteen vector temporaries
are used alongside the lane register. The generator revision is 73 and
A64 selection revision 22. Existing unit/executable cache identities
already include SIMD enablement. The other native selectors are unchanged.

## Correctness

`tests/check_captured_simd.py` checks both SIMD enabled and disabled:

- 6,729 independent C-oracle cases per mode: Int add/subtract/reverse
  subtract, F64 affine expressions and a seven-capture expression,
  empty/odd vectors, canaries beyond the vector, IEEE edges and random
  raw floating bits, descriptor and capture guard fallbacks.
- A fuel yield before essentially every body, clobbering caller-saved
  vector scratch. The SIMD run takes 70,942 hostile yields; scalar takes
  106,725. Each mode preserves the required per-element logical fuel.
- Six overflow executions per mode: the first or second lane overflows
  for add, subtract and reverse subtract. Both modes reach the same
  kernel overflow entry. Large captures at both tagged-Int limits are also
  checked, and a separate no-yield check proves the same logical fuel charge.
- Emission asserts that the intended five captured kernels contain NEON
  loads/broadcasts, and mixed-type, longer checked-Int and oversized F64
  shapes do not. Disabling SIMD removes the pair body.
- The real hosted runtime produces `-498500` with one and four harts.

The IR and builder units check capture use/substitution, type and index
refusals, matching captured-kernel admission and the 32-bit refusal.
The complete Base sweep passed **113/113 jobs**, exit 0, on four workers,
including x64/RV kernels and existing SIMD coverage
([full log](evidence/2026-10-23-captured-simd/base-final.log)). That sweep ran
the initial 6,714-case oracle; the focused final run adds Int-limit and
exact logical-fuel checks, for 6,729 cases per mode on the same production code. See the [oracle log](evidence/2026-10-23-captured-simd/oracles-final.log)
and [unit log](evidence/2026-10-23-captured-simd/kernel-units.log).

## Paired measurements

31 paired rounds, one macOS AArch64 host and one hart, using the preserved
starting-revision compiler versus the new compiler and the same runtime.
Captures come from the vector's runtime length, so they are not specialized
into compile-time literals. The independent timer surrounds the map only;
vector creation and the answer-checking fold are outside it. Every output
is checked. Emitted code confirms the baseline has one scalar map and the
new compiler has one NEON map for each targeted workload.

| Workload | Timer | Baseline median ms | New median ms | Median paired ratio | 95% bootstrap interval |
|---|---|---:|---:|---:|---:|
| Captured Int map | map internal | 1.538 | 0.660 | 0.4284 | 0.4274..0.4305 |
| Captured F64 affine map | map internal | 1.617 | 0.649 | 0.4010 | 0.3973..0.4050 |
| Captured Int map program | wall | 11.166 | 10.237 | 0.9162 | 0.9005..0.9263 |
| Captured F64 map program | wall | 13.886 | 12.891 | 0.9304 | 0.9237..0.9381 |
| Pipeline control | internal | 2.572 | 2.571 | 1.0004 | 0.9957..1.0031 |
| Record control | internal | 8.771 | 8.800 | 0.9980 | 0.9964..1.0019 |
| Nbody control | wall | 230.326 | 230.452 | 0.9996 | 0.9975..1.0007 |

Both targeted map timers improve in all 31 rounds: about 57% and 60% less
time. Whole-program wall gains are about 8% and 7%. This is one host and
two workloads; it is not a claim about all captured maps, other targets,
energy or physical QOS execution. Background load and CPU frequency are
not controlled.

[Raw rounds](evidence/2026-10-23-captured-simd/paired-results.json),
[full summary](evidence/2026-10-23-captured-simd/paired-summary.md),
[compiler identities](evidence/2026-10-23-captured-simd/metadata.json) and
[measured patch](evidence/2026-10-23-captured-simd/measured-source.patch)
are retained. Test/docs changes and production comments followed measurement;
measured and final compiler identities are recorded separately. Exploratory
failure logs retain their names and are not successful validation evidence.

```sh
PKG_CONFIG_PATH=/opt/homebrew/opt/libarchive/lib/pkgconfig \
python3 -u tools/bench-typed-ir-m3.py \
  --output /private/tmp/fpr-captured-simd-paired2 \
  --against /private/tmp/fpr-captured-simd-baseline \
  --variants baseline,typed-ir \
  --workloads simdintmap,simdf64map,pipeline,records,nbody --runs 31
```

## Next increments

Add x64 SSE2 pairs under their own scratch budget, then fused map/filter
SIMD with stable compaction and checked source-order failures. The complete
migration goal also requires builtin manual/GC and ARC policies; SIMD
performance work does not replace those retirement gates.

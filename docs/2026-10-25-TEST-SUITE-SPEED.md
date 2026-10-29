# Faster suites: shared configurations and frame emitters

Date: 2026-10-25. Kind: implementation and measurement record. Applies to
the test-runner changes on main based on `a6043da`, including the local
module-check regression fix.

This first pass removes repeated work from the FP-RISC CI plan and the
large-frame oracles. QOS output isolation and parallel service tests remain a
separate follow-up.

## One registry, successful coverage

`tests/check_registry.py` owns Base's script jobs and all 31 explicit native,
RISC-V and additional host CI configurations. Base's inline cases are unchanged.
The normal local `python3 tests/check_base.py` still runs every Base job.

CI runs the registered groups through `tests/check_ci.py`. After each successful
invocation it atomically records the configuration ID and elapsed time. Each
record binds to source contents (including local untracked inputs), checkout,
host and a hash of relevant environment values. It cannot be reused after an
edit. Failed invocations do not receive completion records. The final `--verify`
requires every registered configuration, before Base can reuse coverage.

Base's `--completed FILE` replaces the old two-name `--skip-typed-ir-native`
shortcut. The complete CI plan covers 21 Base script invocations, eliminating
19 repeated jobs beyond that old shortcut. All distinct modes remain:

- required execution and x64 entry optimizations;
- RV32 and RV64 independent execution oracles;
- default and explicitly typed RV64 Linux lowering/runtime checks;
- default raw checks and the ARC suite's strict-environment raw child checks.

`--require-execution` strengthens the same suite; its successful configuration
covers the default invocation. The default RV64 Linux runtime configuration also
runs the default lowering assertions, so it covers Base's lowering-only call.
Other argument/environment variants need explicit coverage review.

Configuration regression tests are themselves part of Base. They check required
variants, workflow group coverage, source invalidation, and partial/failed runs.

## One frame emitter build

`tests/FrameEmitters.hs` dispatches to the existing A64, x64 and RV frame emitters.
Their generators and assertions are unchanged. `tests/frame_emitter.py` builds
this single executable, sharing compiled codegen dependencies across all three
suites. Its cache key includes compiler/test Haskell sources, helper build code,
GHC information and package metadata. A file lock serializes publication;
private build directories and atomic executable replacement prevent partial or
racing hits. Each oracle still owns its generated assembly, linked programs and
FP-RISC runtime caches.

On this Apple Silicon host, one local build measurement gave:

| Work | Before | After |
| --- | ---: | ---: |
| Three separate emitter builds | 34.28 s | — |
| Shared cold build + two reuse calls | — | 17.17 s |
| Individual warm reuse | — | 0.22–0.24 s |

This measures helper construction only. It is not a measured full-suite or
hosted-CI speedup. The before/after measurements used the same GHC optimization
level and existing Cabal dependency cache. Ordinary test fixtures and deliberate
cold-cache/invalidation tests keep their existing cache behavior.

## Timing records and commands

CI uploads `check-results.json` and `base-times.json` even on failure. Base's
record separates elapsed job time from lock wait and records the commands it
launches. Nested sub-check internals are represented by their script duration,
not a claimed compiler/linker/boot phase breakdown.

```sh
python3 tests/check_base.py -j 4 --times --timings-json build/base-times.json
python3 tests/check_base.py --only check_typed_ir_a64_frames --only check_typed_ir_x64_frames
python3 tests/check_ci.py --list --results build/ci-results.json
python3 -m unittest discover -s tests -p test_check_registry.py
```

Use a fresh results path per CI run. `--list` never builds or runs tests. A
completion file is local runner state, not a signed attestation; only supply
records produced by the current trusted run.

## Validation

The full local Base sweep passed all 126 jobs on four workers (560 s). It ran
alongside the independent parity comparison, so this duration is validation
evidence, not a before/after performance baseline. Registered missing-tool and
nonmatching-host skips retain their original behavior. Native A64 and Rosetta
frame checks and RV32/RV64 QEMU frame/actor-runtime checks passed. All 16 frame
emission variants are byte-identical to standalone emitters.

Two concurrent helper processes produced one build and one reuse. Two real
native checks exercised successful CI recording and Base selected exactly their
completed coverage. Later edits made that record stale and Base rejected it. An
intentional Base failure returned exit 1 and preserved its timing/status record.
The registry regression suite passes eight tests; the workflow also parses.
Hosted Linux CI has not been rerun with this change.

[Evidence summary](evidence/2026-10-25-test-suite-speed/summary.json),
[Base timings](evidence/2026-10-25-test-suite-speed/base-times.json),
[emission hashes](evidence/2026-10-25-test-suite-speed/frame-emission-parity.json),
[helper before](evidence/2026-10-25-test-suite-speed/emitter-before.json) and
[helper after](evidence/2026-10-25-test-suite-speed/emitter-after.json).

The checkout advanced to `ff96204` and acquired concurrent printer edits during
validation; those edits were preserved. The new local timing report puts A64
frames (237 s) and typed kernels (190 s) ahead of Ideal (149 s) and MVU reload
(136 s). Next FP-RISC work should split or share the expensive fixture
construction in those suites. For QOS, first give each leg its own build/disk/
port/process state, then introduce bounded parallel service groups.

## Update 2026-10-30: native unit objects and shared test caches

Commit `9489871` preserves the patch measured on 2026-10-29 against `94f699b`.
Native `fpr build` now caches imported units' assembled objects, with atomic
publication; ordinary test fixtures honor an outer XDG cache and additional
Haskell checks use the existing compiled Cabal test suites. No registered
Base jobs are removed.

The paired runs used the same 160 jobs and four workers, isolated FP caches,
a built compiler/library and built Haskell test binaries. Both passed all jobs,
with normal host/tool-specific internal skips. Wall time fell from 906.5 s to
778.0 s (14.2%); aggregate user/system CPU fell from 2800.4 s to 2413.9 s (13.8%).
These measurements precede the latest Sol merge and are not a full-suite
measurement of that merge. External load varied.

Warm native builds (three-run medians) changed as follows:

| App | Before | New |
| --- | ---: | ---: |
| Hello | 0.98 s | 0.51 s |
| Logbook | 25.41 s | 21.52 s |
| POS1 | 38.02 s | 30.10 s |

Assembly is byte-identical for all three. Cold app samples show no consistent
improvement under the varying load. The clean compiler build took 201.3 s
(dependencies cached), an edit to a Build.hs leaf took 6.9 s to rebuild, and
unchanged `make fpr` took 55 ms. All 30 Haskell suites passed in 23.6 s for
the first build/run against the built library and 8.2 s for a repeat.

[Consolidated evidence](evidence/2026-10-29-build-test-speed.json) retains the
source/patch/binary identities, per-command CPU/RSS/load data, app timings and
per-job bottleneck summary. The main remaining slow jobs are Ideal, A64 frame
oracles, MVU reload and typed kernels.

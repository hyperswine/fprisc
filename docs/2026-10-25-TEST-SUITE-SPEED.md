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

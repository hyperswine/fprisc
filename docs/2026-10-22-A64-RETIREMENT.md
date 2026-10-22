# AArch64 translator retirement

Date: 2026-10-22 to 2026-10-23. Kind: implementation and validation record.
Branch: `typed-ir-retire`, starting at `72d4bb0`.

## Acceptance gate, before deletion

The default backend was tested with `FPR_TYPED_IR_BACKEND` and
`FPR_TYPED_IR_STRICT` unset, before any source edits:

| Suite | Result |
|---|---|
| `tests/check_base.py --serial --times` | 106/106 jobs, exit 0, 1,287 seconds |
| QOS `f9c00ae`, `check-all.sh`, using this checkout through `FPRISC_ROOT` | 162 legs, `ALL LEGS GREEN`, exit 0, approximately 62 minutes |

The suites ran sequentially, with fresh `XDG_CACHE_HOME` roots. Individual
checks retained their existing build-cache and temporary-directory rules.
This was a serial, low-contention correctness run on this 10-core Apple
Silicon Mac, not an isolated performance measurement. Recorded CPU samples
during the suites were about 59-76% idle; Spotlight activity was observed.

The QOS verdict includes its existing dependency/platform skips: DRM's Linux
headers, Python `websockets`, Linux A64 cross/VM/JIT tooling, several Linux
Xvfb checks, and GPU dispatch captures. Native macOS GL checks, including
Graphics.qa and both Main Profile boots with all six onboard apps, passed.
This is local evidence, not hosted CI or physical Pi/P4 evidence.

The starting compiler SHA-256 was
`7063021139c5f7a6e89e0ad591bdf0b5cfe6915d7a92bbdf0e68e0c4aac66894`.
[Full logs, machine samples and binary hashes](evidence/2026-10-22-a64-retirement/metadata.json):
[Base](evidence/2026-10-22-a64-retirement/base-before.log),
[QOS](evidence/2026-10-22-a64-retirement/qos-before.log).

## Change

- Deleted `compiler/A64.hs` (513 lines) and its Cabal module registration.
- Removed `FPR_A64_FIT_GUARDS` and `FPR_A64_FRAME_PAIRS`, including their
  executable-cache inputs, dedicated tests and guard benchmark driver.
- A64 code generation refuses `legacy`, `0` and `off`. Type-only checks,
  std proofs and Sol retain their own analysis/execution paths.
- Every A64 function and kernel must emit natively, even when a named
  `FPR_TYPED_IR_STRICT` subset would otherwise permit fallback. A unit
  requiring translation fails before assembly is written.
- A64 unit-cache identities now contain `-native1`, so cached units from
  before retirement cannot bypass that requirement. The module interface
  target identity retains its existing revision 15; the cache policy has
  its own version.
- Removed A64 legacy emission/runtime legs from shared optimization tests.
  Their RV/x64 legacy legs remain; A64 tests use independent arithmetic,
  trap, ownership, C interoperability and SIMD oracles. A64 whole/mixed
  granularities retain separate cache-transition checks.
- Native-only enforcement exposed a previously hidden fallback in imported
  polymorphic vector constructors. The shared typed lowering now recognizes
  inference-generated `Vec.fromListAs` and `Vec.mapAs` runtime entries,
  whose V ABI and arities are already defined in `runtime/vec.c`, and the
  inference-selected boxed I64 operators defined in `runtime/runtime.c`. Native
  selector cache revisions were advanced for that widened coverage.
- Opaque or partially applied HAL primitives now apply their runtime
  function objects, using the existing `fpr_applyN` path. This closes
  QOS's `Sys.storeReq` and `Sys.bindStore` fallbacks without assuming the
  source arity hint is the actual C-entry arity.
- The A64-only timing driver now offers typed variants. Reproducing its
  historical legacy comparisons requires the pre-retirement revision.

`X64.hs` and RISC-V text emission still serve their existing consumers.
The RISC-V `# wcet:` ratchet remains in use; its pre-deletion sweep result
was 104 against the ceiling of 200. Native-metric admission migration is a
separate change.

## Validation after deletion

- Compiler build passed.
- Aggregate/string runtime checks passed in typed and entry-optimization
  modes, with one/four harts and exact range traps.
- Retirement regression: all five A64 targets emit native-only roots and
  imports; whole/mixed unit caches remain distinct; every rollback alias
  is refused, including through a populated executable cache. Unsupported
  foreign calls are refused by name in default, whole-unit and named-strict
  modes. Module contract stamps retain their prior target identity.
  RV32/RV64/x64 rollback emission remains available.
- Imported polymorphic vector construction and dynamic mapping passed
  independent Int/F64/boxed-string results with one/four harts and strict
  native emission. The full higher-order contract check also passed.
- Focused I64 acceptance passed, including wraparound, unsigned views,
  conversions, parsing, structures, actor sends and type refusals. Native
  I32 acceptance and expected panic cases also passed.
- Full post-change Base suite: **105/105 jobs, exit 0**, 612 seconds with
  two workers. The two obsolete translator checks were replaced by one
  retirement regression. [Log](evidence/2026-10-22-a64-retirement/base-after.log).
- QOS emission catalog: **198 native-only roots**, with native-only imports,
  **zero native fallbacks**, and A64 function headers verified. The remaining
  49 roots were frontend refusals under the standalone plugin flags, plus
  the independent frontend exception below.
  [Per-source results](evidence/2026-10-22-a64-retirement/qos-emission.json).
- Portable QOS storage: real app/host replayed 200 KB, 256 KiB and 300 KB
  intact through the opaque storage bridge.
  [Log](evidence/2026-10-22-a64-retirement/qos-kv-after.log).
- Loaded QOS app and both plugins passed **two boots**, with persistent
  storage, plugin calls and QAR2 image checks.
  [Log](evidence/2026-10-22-a64-retirement/qos-after.log).

The first post-change Base attempt encountered Cabal's missing Homebrew
`libarchive` pkg-config path after the package module list changed. The
retry supplies `/opt/homebrew/opt/libarchive/lib/pkgconfig`, as the build
already does. The failed attempt is retained in
[its log](evidence/2026-10-22-a64-retirement/base-after-attempt1.log).

The second post-change attempt exposed the `Vec.fromListAs` fallback in
`check_higher_order_contracts.py`. The runtime-entry mapping fix above
addresses it; the failed attempt is retained in
[its log](evidence/2026-10-22-a64-retirement/base-after-attempt2.log).

The third attempt passed the preceding 104 Base jobs, then the final I64
job exposed inference-only `I64.+`, `I64.*` and comparison entries. The
same explicit runtime-entry registry now includes all ten boxed I64
arithmetic/comparison operators. Its log is retained as
[attempt 3](evidence/2026-10-22-a64-retirement/base-after-attempt3.log).

A full 105/105 Base pass before the HAL extension is also retained in
[its log](evidence/2026-10-22-a64-retirement/base-after-before-hal.log).
The final 105/105 result above includes the HAL extension and its new tests.

The first QOS emission catalog found seven source roots using opaque HAL
calls; this led to the generic HAL application fix. One standalone library
root, `programs/mods/blockep.fpr`, hits `Exhaust.hs:191`'s `head []` in
`--check-only` mode and with the surviving legacy x64 backend too. That
frontend exception is independent of A64 retirement and is recorded as
such, rather than counted as successful emission.

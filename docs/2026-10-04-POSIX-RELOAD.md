# POSIX module attachment and production MVU clock

Date: 2026-10-04. Extends the
[checked interface gate](2026-10-04-RUNTIME-INTERFACES.md) and
[event identity checks](2026-10-04-RELOAD-IDENTITY.md).

## Building and attaching

`fpr build math.fpr --module -o math.dylib` builds a host shared module on
macOS; the default extension is `.dylib` there and `.so` on Linux. The normal
checker still runs. The image contains its module closure and checked root
exports, with no private allocator, scheduler or runtime. `fpr run --module`
and module builds for ESP-IDF refuse explicitly.

Host modules use PIC address resolution. AArch64 uses GOT references for
external addresses and the host's x28 hart register; x64 uses GOT references
and initial-exec access to the executable's TLS, including staged wide
arguments. ELF pointer tables use `.data.rel.ro`, allowing loader relocation
without text relocations. Module units have separate cache tags. Codegen
revision is 38; native runtime ABI remains 3. Interface stamps now identify
the actual ISA/lowering cache tag, rather than the common rv64 emission IR.
Rebuild executables and modules together.

`N = use "std/native"` exposes `attach path`, `loadAt baseline path`, and
`loadVersionAt baseline from to path`. The latter two use the shared gates.
Attachment opens a trusted module with local symbol visibility and checks
its native ABI, codegen revision and module-table schema before registration.
The executable exports its runtime symbols. Publish each replacement at a
distinct immutable path: the dynamic loader does not refresh an already loaded
path after its file is overwritten. Missing images/metadata, wrong
ABI/schema and duplicate attachment refuse without adding a registry entry.

An accepted module stays mapped, including after an interface/identity refusal
removes its table. Saved old functions remain callable. The host closes a
failed pre-registration handle, and closes the extra handle reference on a
duplicate. There is still no reclamation of adopted images and no concurrent
registry publication; the sole writer contract still applies. Dynamic loading
is for trusted compiler output, not a sandbox or authenticated publisher.

## Clock

`Sys.mtime Unit : Int` reads the scheduler HAL's monotonic timer in 10 MHz
units. POSIX supplies `CLOCK_MONOTONIC`; QOS supplies its existing timer HAL.
Sol's actor bridge supplies the same unit from GHC's monotonic clock.
`std/mvu` uses this primitive for subscription deadlines and frame pacing,
with parked `Sys.sleepUs` between deadline checks. It no longer needs a
memory-mapped `read` primitive on Base. The cfg `mt` field remains for existing
records but does not select the clock. Frame `tick` remains in 10 MHz units,
and `STick` remains in milliseconds. A target must supply a functioning timer
HAL; this does not add a clock to timerless hosts or solve RV32 timer wrap.

The Base clock shim was removed. Production tick tests assert that tick
subscriptions fire while keeping the model/render trace deterministic.

## Verification and boundaries

- Real Apple Silicon shared modules on one and repeated four-hart runs:
  successful replacement, missing/metadata/ABI/schema/duplicate failures,
  stale/wrong identity, same-arity type/contract refusal, root-scoped baseline,
  old saved functions, registry rollback, nine-argument calls and clock advance.
- Real POSIX MVU runs on one/repeated four harts: module replacement between
  events, refused candidate, retained model, updated render env and timed frames.
- x64 and AArch64 Linux artifacts: root plus imported units and nine-argument
  spill compile/assemble/link as ELF shared objects with `-z text`. These are
  relocation checks; Linux module execution was not tested on this Mac.
- Shared MVU variants run without a test clock, including a real `STick` variant.
- QOS real reload tests pass on one/four harts; focused MVU/browser smoke passes.
  Interpreted Sol `mvutick` reaches the 30s band/four statics builds; its existing
  unjoined render actor is cancelled at the transaction boundary.

`python3 tests/check_base.py` passed the complete Base suite. Final targeted
module and production-tick checks passed with the current compiler too. No full QOS
check-all, native RV64 plugin reload or real browser/GL module reload is claimed.
QOS follows this milestone through its compiler pin; the tests below were
run against the sibling compiler before publication.

Next: publication/store watching and restart policy, typed live-module env
reconstruction, QOS journal/replay, then image reclamation and measured long-run
costs. This slice provides explicit attachment, not `fpr watch`.

# Core pipeline ownership

Date: 2026-10-25. Kind: implementation record. Applies to the working-tree
changes on `97d6ad7`; follows [the architecture review](2026-10-25-ARCHITECTURE-REVIEW.md).

This is a historical first-stage record. See the
[current structural checkpoint](2026-10-26-COMPILER-STRUCTURAL-CHECKPOINT.md)
for the checked semantic pipeline and remaining physical boundaries.

The first slice separates Core transformations from native generation without
changing the generated program. This is not the full typed, uniquely named Core
migration proposed by the review.

## Owners and contracts

| Owner | Responsibility |
|---|---|
| `Core.Syntax` | Core nodes, names, program bindings and lexical queries; no parser/inference dependency |
| `Core.Primitives` | Core/scalar primitive arities and floating widths |
| `Core.Analysis.FusionSafety` | Arithmetic/effect admission for fusion |
| `Core.Opt.Normalize` | Core normalization and indexed-memory rewrite |
| `Core.Opt.Fusion` | Fixed-point vector composition |
| `Core.Opt.Vector` | Vector admission, kind checks and record-column dualization |
| `Core.Opt.Vector.Plan` | Typed vector operations and their payloads |
| `Core.Opt.Pipeline` | Pass order, options, stage reports and worker ABI metadata |
| `Codegen` | Native lowering/selection, kernel conversion, static data and diagnostics |

`Codegen.hs` falls from 1,716 to 567 lines. Core-only clients import
`Core.Syntax`; `FPRISC` reexports it for source compatibility. The constructors
and generic Binary order are unchanged, preserving cached Core values.

The Core pipeline runs fusion, private workers, normalization for reuse, then
constructor reuse. Its result owns the program, scalar signatures and pass
reports together; clients cannot construct the result by mixing unrelated
stages. Each boundary checks retained function entry arities, distinct formal
parameters, worker existence and worker signature arity. These checks do not
prove Core types or general lexical correctness.

The existing switch behavior remains: normalization at this boundary only feeds
the reuse pass when reuse is enabled. ARC and indexed-memory normalization keep
their existing native-lowering positions.

Vector operation strings become constructors: scalar map/filter/fold, record
map/filter, layout map, writeback fold and fused pipeline. Layouts, callback
names and pipeline stages are payloads, not string prefixes to parse. Floating
widths are `Float32`/`Float64`. The old symbol serialization remains only at the
native ABI boundary, so generated symbols and cache revision 89 remain valid.
The lower-level kernel IR still uses string stage names; per-ISA instruction
ADTs are also outside this change.

## Validation

- The compiler builds with `make fpr`.
- `tests/check_core_pipeline.py` checks worker ABI failures, pass order/options,
  typed pipeline stage order, shadowed-primitive refusal, layout payloads and
  the Binary byte oracle generated from the previous Core definition.
- Fresh assembly and dependent units match the pre-change compiler byte for
  byte in 128 cases: eight targets (RV32, RV64, A64 ELF/Mach-O, x64 ELF/Mach-O,
  qx64 and qa64), seven fixtures with default and worker/reuse-disabled modes,
  plus two fixtures with vector fusion disabled. Comparison outputs live in
  `/private/tmp/fpr-architecture-before` and
  `/private/tmp/fpr-architecture-final-after` for this local run.
- QOS Main and its 49 dependent units also match the saved compiler byte for
  byte. Receive-turn decisions are identical; the existing coverage gap and
  reporting defect are recorded in the region-status page.
- Full Base passed: 127 jobs, all statuses `ok`, in 410.61 seconds with six
  workers and no reused CI coverage. The run includes the new Core pipeline
  check, workers/reuse, typed scalar/kernel checks, ARC/raw paths, frame
  oracles, reloads and actor/arena cleanup checks. Three platform/toolchain
  subchecks reported their existing skips: standalone typed x64 execution and
  Linux x64 actor execution on the nonmatching host, and the POSIX RV64 clang
  artifact check without a RISC-V backend. RV32/RV64 QEMU frame/runtime checks
  did execute. No hosted CI or physical-board run is claimed.
  Local records: `/private/tmp/fpr-architecture-base.log` and
  `/private/tmp/fpr-architecture-base-timings.json`.

The first broad attempt lacked Homebrew libarchive pkg-config metadata; a
subsequent attempt collided with an in-progress compiler rebuild. The successful
run above used the final fixed source/build and
`PKG_CONFIG_PATH=/opt/homebrew/opt/libarchive/lib/pkgconfig`.

## Next slices

1. Establish a typed, uniquely named Core boundary after inference: preserve
   source types and stable binder identity before replacing downstream shape
   reconstruction. Introduce it alongside the current Core so the migration
   can retain differential tests; do not annotate nodes by guessing types after
   optimization.
2. Add type/scope lint and explicit contracts to individual pass inputs and
   outputs, including generated worker and region metadata.
3. Introduce a region-plan analysis/report with boundary reasons and explicit
   refusals before changing allocation. This will need the preserved types,
   costs and resource ownership described in
   [the region status](2026-10-25-REGION-STATUS.md).
4. Separately split surface syntax/parser/desugaring/linearity, and consolidate
   compiler options/diagnostics. These need their own compatibility checks;
   moving all responsibilities into another large module would not help.

## Sync and type-vocabulary prerequisite

The cleanup was rebased onto main `0f6df38`, including the region stages and
codegen revision 105. The revision-89 byte comparisons above record the first
slice before that sync; the refactor does not override the new region ABI or
cache revision. The updated memory status distinguishes those two snapshots.

`Type.Syntax` now owns Type, Row, Scheme, primitive type constructors and the
pure float-presence query. It depends on neither inference nor either AST;
`Infer` reexports the vocabulary for compatibility. ReceiveTurns consumes the
type model directly, and Compile/Sol separate model imports from inference
operations. This removes a dependency cycle that would otherwise prevent Core
from carrying checked source types. It does not yet annotate Core binders.

Make's compiler inputs now include nested Haskell modules, so changing a Core
or Type module alone rebuilds fpr. Validation after integration is recorded in
the cleanup goal register.

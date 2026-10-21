# Typed IR: loaded QOS apps on AArch64

Date: 2026-10-22. Kind: implementation and validation record.
Base: main `0bf1bbf` (the [kernels and F64 work](2026-10-22-TYPED-IR-KERNELS.md)).
Branch `typed-ir-qos`, implementation commit `428b744`.

Until now a QOS app or plugin (`--target=qa64`, `qa64mac`, `qa64single`,
`qx64`, `qrv64`) never reached the typed backend: the profile was refused
by name. QOS is where most FP-RISC code runs, so this page admits it on
AArch64 and validates it with QOS's own suite.

## What a loaded QOS app needs from generated code

The [runtime contract register](2026-10-21-NATIVE-IR-CONTRACTS.md) records
the QOS app contract as the hosted Base one with the plane underneath:
allocation, scheduling and stack growth go through the app-side runtime,
which delegates to the host, under the same symbols (`fpr_alloc`,
`fpr_stack_grow`, `fpr_fuel_exhausted`, `fpr_applyN`). The legacy path's
only rewrite for a QOS app on AArch64 is the hart read
(`A64.deTlsQosAppA64`): `x28` holds the hart pointer, set once per hart and
never saved by the context switch; under `qa64single`, a global cell. The
typed A64 backend already reads the hart from `x28` for `fpr build`
programs, and appends its text after the legacy translation, so the
rewrite never sees it.

## Change

- `Codegen.Policy`: the `QosApp` profile is admitted with fuel, under the
  same contract as hosted Base; without fuel it is refused by name.
- `Codegen.Target.A64`: a `HartGlobal` access form, `adrp`/`ldr` of
  `fpr_posix_hart` (ELF `:lo12:`, Mach-O `@PAGE`/`@PAGEOFF`), the legacy
  single form.
- `Compile.hs`: `qa64` and `qa64mac` select the A64 backend with `x28`,
  `qa64single` with the global cell; plugins included.
- `a64SelectionRev` 13.

x86-64 (`qx64`) and RISC-V (`qrv64`) QOS apps stay refused: each needs a
hart read through the host's TLS offset cell (`fpr_g_tlsoff`), and x86-64
also its argument cells for parameters 7 and 8 through the same offset.
There is no QOS run environment for those targets on this host.

## A defect QOS found

The first check-all run with the backend on failed seven legs, all on one
compiler error: the simplifier's branch-on-comparison pass threaded away a
Bool join whose parameter was tested again two joins later, so that test
had no definition on the threaded paths (the verifier refused it, a
compiler error, not silent miscompilation). The pass now requires the
join's parameter and its `truth` to be unused outside the join.
`tests/TypedIR.hs` reproduces the shape (a Bool tested twice); it fails
without the fix. A simplifier failure now prints the function before and
after the failing pass.

## Validation (this Mac, arm64; QOS `587fdb1`)

- **QOS `check-all.sh` with `FPR_TYPED_IR_BACKEND=mixed`** for every FP-RISC
  build it makes (apps, plugins, the Portable host's FP-RISC, the shell),
  against this compiler: **162 legs, all green** (second run, after the
  simplifier fix; the first run is the seven-leg failure above).
- Coverage of QOS programs under the backend:

  | Program | Native functions |
  |---|---:|
  | `programs/main.fpr` (the paged GUI shell) | 2,421 of 2,427 |
  | `tests/devpublication.fpr` | 1,652 of 1,652 |
  | `tests/appsessionmemory.fpr` | 1,145 of 1,149 |
  | `tests/qsys.fpr` | every unit fully native |

  The main shell's six fallbacks are all in-place constructor reuse
  (`$reuse.fresh`), which the typed lowering declines by name.
- `tools/qsys-check.sh` with the backend on: the app and both plugins
  native, two boots hold.
- `tests/SelectedIR.hs`: the QOS profile with `x28`, the global hart cell in
  ELF and Mach-O syntax, and the refusal of a QOS app without fuel.

Not verified: QOS on a Pi or STAR64, QOS Native (`qos-native`), x86-64 or
RISC-V QOS apps (refused), and performance: no QOS timing was taken. QOS's
compiler pin is unchanged; the backend stays opt-in there.

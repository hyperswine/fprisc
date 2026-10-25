# Shared compiler options and cache contracts

Date: 2026-10-25. Kind: implementation and validation record.
Applies after typed aggregate/pattern lowering at `6ab8d1d`.

`Compiler.Options` is the single interpretation of the native compiler's
environment controls. Each native driver invocation reads them once into
`CompilerOptions`, with separate `CodegenOptions`, `NativeOptions`,
`DiagnosticOptions` and `DriverOptions` products. `Compile` no longer performs
individual environment lookups throughout lowering/emission, and `Build` no
longer maintains another list of codegen switches for its executable cache.

`Compiler.CommandLine` owns the compile argument record, syntax and host/target
resolution. `--check-only` is a field in that parsed product rather than a
second scan of the argument list. CLI `--no-inline` and its environment control
combine before both lowering and unit-cache identity. Defaults use named
record initializers rather than long positional Boolean constructors.

Backend granularity and strict selection have independent constructors in the
options vocabulary, reexported by `Codegen` for compatibility. Native emission
still requires complete coverage. The dead check for strict mode without any
backend was removed: CLI compilation always selects the native generator.
Supported diagnostic spellings and tested differential controls remain at the
compatibility boundary; this stage does not silently change their defaults or
delete controls still used to validate optimizations.

## Cache correctness

Native, optimization and vector option renderers now own the existing
generated-unit suffix spelling. They are also used to form the executable
cache's versioned `compiler-options-v1` identity. Native compiler modes are
interpreted before consulting that cache, including refusal of retired
backend aliases. Report-only controls are separate from emitted-code identity.
FP-pool identity is conservative in the executable cache; unit keys continue
to reflect its target-specific availability.

This fixes an observed mismatch: `FPR_NO_RECEIVE_TURNS` changed generated-unit
keys but was missing from Build's executable-cache flag list. A warm `fpr run`
could therefore execute a build from the wrong compiler mode. The regression
first runs a bounded receive loop, disables automatic receive regions and
expects the resulting heap-growth failure, then restores a default alias and
checks reuse of the original executable without modifying it. The saved
`6ab8d1d` compiler fails this test by reusing the bounded default build in the
disabled mode; the new compiler passes it.

The executable key also includes the configured C compiler, cross target and
foreign declaration contents. Replacing a foreign contract at the same path
now invalidates the executable; a focused native regression checks this.
The executable-cache identity intentionally changes. Generated-unit key
spellings, codegen revision **106**, source Binary formats and physical native
ABIs remain unchanged from the preceding stage.

## Validation and remaining work

`tests/CompilerOptions.hs` checks canonical default aliases, every emitted-code
control's cache sensitivity, diagnostic independence, retired/unknown backend
refusals, strict names, CLI/environment precedence, module/check-only flags,
host flag ordering, explicit cross targets and export syntax. The independent
native cache test covers actual receive-region behavior, reuse and changed
foreign declarations. It is one registered Base job with the existing Cabal
lock.

All **128** fresh root/dependent-unit emission and key comparisons pass against
the saved pre-frontend baseline with only the preceding stage's explicit
g106/g105 revision normalization. No instruction normalization or new unit-key
normalization is used for this options refactor.

Full Base passed **135 jobs in 435.19 seconds on six workers**, with no reused
CI coverage, on the frozen final compiler tree. Existing host/toolchain-dependent
subchecks retain their explicit skips. Sol argument/shared-language fixtures
and 3,000,000-iteration self/mutual tail calls passed (peak 86 MB). Hosted CI for
`6ab8d1d` was still running its Linux x86-64 direct-backend step when this stage
finished local validation; the push requests a new cumulative check.
Local logs are `/private/tmp/fpr-options-{build-final,focused-final,base}.log`,
`/private/tmp/fpr-options-base.json`,
`/private/tmp/fpr-options-final-parity.log`,
`/private/tmp/fpr-options-cache-before.log` and
`/private/tmp/fpr-options-sol-{args,both,tail}.log`.

The [full compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) remains active.
This options ownership stage does not migrate closure/optimization/region
passes across typed Core's erasure boundary, introduce structured source
diagnostics or replace string-encoded native instruction contracts. Further
target/ABI contract regularization belongs with those remaining stages.

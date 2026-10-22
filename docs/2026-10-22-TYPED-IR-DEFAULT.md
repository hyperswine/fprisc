# The typed backend is the default

Date: 2026-10-22. Kind: decision and validation record.
Base: main `12b7d24` plus [the remaining kernels](2026-10-22-TYPED-KERNELS-COMPLETE.md).
Branch `typed-ir-retire`.

## Decision

`FPR_TYPED_IR_BACKEND` unset now means `mixed`: on every target the typed
backend supports (hosted A64 and x86-64, RV64 and RV32 hosted and
bare-metal, QOS AArch64 apps and plugins), each function and each vector
kernel that lowers is emitted by the typed backend, and the rest by the
legacy generator, as `mixed` did. `1` still selects whole units.
`FPR_TYPED_IR_BACKEND=legacy` (also `0` or `off`) is the rollback: the
legacy generator and its translators for everything, byte for byte what
the default produced before this page. The targets the typed backend does
not support (x86-64 and RISC-V QOS apps, ESP-IDF, RISC-V modules and
plugins, builtin and ARC profiles) are unchanged: they never selected it
and still do not.

The [retirement inventory](2026-10-22-TYPED-IR-RETIREMENT.md) made the
promotion wait for two things: typed vector kernels (done, in the three
kernel pages) and the test sweep. The sweep's rule changes here: a test
that reads legacy text or exercises a legacy-only switch names the legacy
backend explicitly (`FPR_TYPED_IR_BACKEND=legacy`) instead of dropping the
variable, since dropping it now selects the typed backend. Every pin from
the earlier sweep was converted, and the tests whose legacy leg was "the
variable unset" (`check_typed_ir_native`, `check_typed_ir`,
`check_typed_ir_aggregates`, `check_float_inline`, `check_x64_scalar`,
`check_rv64_linux`, `x64_probe`, `check_x64_local`, `check_reuse`, the
coverage tool, the M3 benchmark's `legacy` variants) were given the same
explicit value. Their differential checks therefore still compare the typed
backend against the legacy generator, not against itself.

CI runs `check_base` twice: with the default, and with
`FPR_TYPED_IR_BACKEND=legacy`, so the rollback stays tested for as long as
the legacy path exists. The explicit typed stages (the direct-backend
suites, the RV64 Linux typed leg) are unchanged.

## What this does not do

- It does not delete the translators (`A64.hs`, `X64.hs`) or the RISC-V
  generator. They still serve the rollback and the unsupported targets.
- It does not change QOS: QOS pins its compiler, and with its pin moved to
  this compiler its builds take the typed backend by default; its three
  legacy-text legs accept the typed kernels as the witness since `f9c00ae`.
- It does not change the cache keys' meaning: the unit cache tag names the
  backend, so legacy and typed units never collide.

## Validation (this Mac, arm64; QOS `f9c00ae`)

With the variable unset: `check_typed_ir_kernels.py --require-execution`
passes; `check_base.py`, every job, 106 of 106; QOS `check-all.sh` 162 of
162 in one run. With `FPR_TYPED_IR_BACKEND=legacy`: `check_base.py` 106 of
106. `FPR_TYPED_IR_BACKEND=bogus` is refused with the three accepted
values named. The switch's four accepted spellings were checked on fib:
unset, `mixed` and `1` emit the typed unit, `legacy` the legacy one. CI
runs on the push, with the new legacy `check_base` stage.

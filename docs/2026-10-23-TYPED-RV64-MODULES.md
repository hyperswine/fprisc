# Typed RV64 posix modules

Date: 2026-10-23. Kind: implementation and validation record.
Base: main `493f234` (after the [A64](2026-10-22-A64-RETIREMENT.md) and
[x86-64](2026-10-23-X64-RETIREMENT.md) retirements). Branch `typed-ir-retire`.

A loaded posix module on RV64 (`--module`, `fpr build --target=linux-riscv64
--module`) was the last RISC-V hosted consumer of the legacy generator: the
typed RISC-V backend was never selected for a plugin. The
[retirement inventory](2026-10-22-TYPED-IR-RETIREMENT.md) sized it small to
medium. It needed two things the typed backend did not have: the hart read
of a shared object, and position-independent references.

## What a loaded RV64 module needs

The legacy path (`RV64.lowerPosixRV64 shared`) assembled the module under
`.option pic` and rewrote every hart read as initial-exec TLS:
`la.tls.ie rd, fpr_posix_hart; add rd, rd, tp; ld rd, 0(rd)`. The GOT entry
holds the cell's offset from tp, resolved by the dynamic loader against the
host executable's `fpr_posix_hart`, so a module never has a TLS block of its
own. Under `.option pic` the assembler turns `la` into a GOT load and
`call`/`tail` into PLT relocations, which is what makes external symbols
interposable.

## Change

- `Codegen.Target.RV`: a third hart access form, `HartTlsIe`, rendered as
  the legacy sequence above (in the entry check, after a stack-segment
  change and at every safepoint). The frame ceiling is the hosted one. Under
  that form a unit-local label (a `.L` string object) is addressed with
  `lla`, PC-relative, as the A64 module pass keeps local labels; every other
  `la` stays a GOT load. `rvSelectionRev` 11.
- `Compile.hs`: a posix module selects the typed RISC-V backend with
  `HartTlsIe` (QOS plugins stay refused: their hart contract is the host's
  TLS offset cell). A translation-free module unit starts with
  `.option pic`; a unit that still carries legacy text already had it from
  the legacy lowering. The module PIC pass (`posixPic`: `.rodata` to
  `.data.rel.ro` for the pointer tables) runs over the typed text as it did
  over the legacy text.

## Tests

- `tests/check_typed_ir_rv_module.py` (Base, CI's QEMU oracle stage): a
  five-function module (a HAL import, Int and F64 arithmetic, a string, a
  local call) compiled with the default backend in strict mode. Emission:
  every function native, `la.tls.ie t3, fpr_posix_hart` and no `%tprel` in
  each, one `.option pic`, a `lla` for the string label, no short jump to an
  external symbol, and the legacy rollback's unit identity separate.
  Relocations, from the assembler: `R_RISCV_TLS_GOT_HI20` for the hart,
  `R_RISCV_CALL_PLT` for calls, no `R_RISCV_TPREL`. Execution: the
  module's functions linked statically against a C oracle whose crt sets
  `tp` to the TLS block (`.tdata`; the cells are initialised so a static
  freestanding image gives them memory, since `.tbss` would alias `.bss`),
  run under `qemu-system-riscv64`: 1,805 cases, the HAL import reading the
  same TLS cell, the string object, and a fuel yield on every entry proving
  the hart was read through the cell.
- `tests/check_rv64_linux.py`: the lowering checks (`la.tls.ie` and
  `.option pic` in the module text, no `mv tp`, no short external jumps,
  separate unit identities) now run for the typed backend as well as the
  legacy rollback; the Linux module case requires the module's own
  functions native, and its host loads and calls the module on 1 and 4
  harts under `qemu-riscv64` in CI, with the real loader and the host's TLS.

## Validation (this Mac, arm64)

- `check_typed_ir_rv_module.py --require-execution`: the three stages above
  pass (emission, relocations, 1,805 executions under QEMU). The first
  execution attempt trapped because the oracle's TLS cell sat in `.tbss`
  and aliased the oracle's hart array; initialising it moved it to `.tdata`.
- `check_rv64_linux.py` lowering checks: pass with the default backend and
  with `FPR_TYPED_IR_BACKEND=legacy`.
- `check_typed_ir_rv.py --width 64` and `--width 32` with execution
  required, `check_a64_retirement.py`, `check_x64_retirement.py` (their
  RISC-V rollback legs), `check_posix_modules.py` and `check_pos_reload.py`
  (the A64 modules, through the shared module pass), `KernelIR.hs` and
  `SelectedIR.hs`: pass.
- `check_base.py`, every job, with the default backend: 108 of 108.
- Linux CI (the push): the module case loads the typed module with the
  real loader and runs it on 1 and 4 harts under `qemu-riscv64`; the
  typed leg requires the module's own functions native.

Not verified here: a real Linux dynamic loader and the host's TLS (CI's),
RISC-V hardware, and QOS (no RV64 posix modules there). The module
interface identity (`rv64HostRev`) is unchanged: the module's ABI is the
generated-code ABI either way.

# Native RISC-V plugins and RVV startup

Plain bare-metal `--plugin` on RV32 and RV64 now selects the typed backend.
It reads the hart directly from `tp`, as the old bare-metal output did.
Posix modules still use initial-exec TLS/GOT addressing; QOS apps/plugins
still use the host's `fpr_g_tlsoff` cell. ESP plugin and builtin ARC plugin
refusals keep their existing profile boundaries.

The RV target owns the RVV preamble and `fpr_rvv_enable` startup hook. Every
RVV unit, including a functionless unit, supplies the same COMDAT definition;
the linker keeps one strong definition over the runtime's weak no-op. The
runtime invokes it on each hart. The hook sets both `mstatus.VS` bits, then
returns. Builds without RVV supply no hook and touch no vector state.

A fully native RVV unit now emits native startup, functions, kernels and data
without passing through the RISC-V text generator. During retirement, a unit
with a legacy function emits the hook only through its remaining legacy
section. This avoids duplicate labels inside one assembly unit. The hook's
instructions and calling convention are unchanged. Codegen revision 78 and
RV selection revision 18 invalidate earlier cached units.

## Validation

`tests/check_typed_ir_rv_startup.py --require-execution` checks:

- Default strict native routing of plain RV32/RV64 plugins, including every
  unit in the manifest and byte-identical cold/warm root assembly.
- Complete root assembly/data linked against an independent freestanding C
  host. Both widths execute 1,803 arithmetic/argument calls plus string and
  exported-PAP calls. The host inspects module-table magic, schema, five
  export rows, string objects and the callable PAP's code/arity/argc layout.
  The ninth argument uses hart spill cells. Entries yield through the `tp`
  hart, with caller registers and hart argument cells overwritten.
- Both widths execute the typed RVV sum with VLEN 128, 256 and 512: 1,032
  cases per run, lengths 0 through 257, signed values, scalar lane/accumulator
  bound fallbacks, unchanged descriptors and exact independent answers.
  The fuel stub overwrites VL and vector registers v8-v10 as well as caller
  GPRs and hart argument cells. Large lanes that would overflow take the
  checked scalar path and trap in a separate execution for each width.
- The CRT starts with vector state disabled. The generated hook enables it;
  repeated calls are harmless. Two independently generated units link to
  exactly one strong startup symbol. A functionless unit supplies its hook.
- Native executable routing carries the preamble too. Current mixed and
  all-legacy units each assemble with exactly one hook. Non-RVV plugin
  images execute with the CPU's V extension explicitly disabled.

The test is registered in Base and required in the Linux QEMU CI job.
The complete local Base sweep passed **118 jobs in 445 seconds**, with the
existing SoftFloat runtime explicitly supplied for the RV32 execution legs.
Retained local logs are in [evidence](evidence/2026-10-23-rv-startup/).
These checks use a statically linked freestanding host, not a dynamic board
plugin loader. No physical RVV or hosted CI execution is claimed.

This closes routing and startup dependencies. The old affine-map vector
compiler is unreachable: `rvvMapInner` immediately returns `Nothing` because
its lanes lack checked Int overflow. Both generators use scalar maps for
that shape, so deleting that dormant template needs no new RVV map feature.
Large hosted frames, declined kernel plans and explicit legacy modes remain
part of the final production-caller and acceptance audit.

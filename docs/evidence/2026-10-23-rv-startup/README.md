# Native RV plugins and RVV startup evidence

Base: `1185b2a`, plus the source changes identified by `metadata.json`.
The source and compiler hashes were checked again after execution.

- `oracles.log`, `oracles.exit`: required RV32/RV64 freestanding plugin
  and RVV execution, all three VLENs and overflow controls; exit 0.
- `base.log`, `base.exit`: complete Base sweep, 118 jobs, 445 seconds,
  four workers, exit 0. RV32 software runtime root was explicitly set to
  the existing sibling checkout's `build/tangnano20k-softfloat` libraries.
- `caller-audit.txt`: remaining production consumers and the dormant
  RVV map gate, grounded in current source.
- `metadata.json`: local compiler/source identities and tool versions.

Reproduce from the worktree:

```sh
python3 -u tests/check_typed_ir_rv_startup.py --require-execution
FPR_SOFTFLOAT_ROOT=/Users/jasonqin/Documents/GitHub/fprisc/build/tangnano20k-softfloat python3 -u tests/check_base.py -j 4 --times
```

These are local static-link QEMU and hosted Base results. They do not
claim dynamic plugin loading on a board, physical RVV execution, hosted CI
success or a timing improvement. Runtime reservation and remaining
legacy-generator acceptance gates are still open.

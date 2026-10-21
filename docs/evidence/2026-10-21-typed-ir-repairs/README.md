# Typed IR repair validation, 2026-10-21

- `typed-ir.log`: final focused verifier, lowering and native oracle run.
- `workers.log`: independent focused worker regression run.
- `base.log`: initial Base run through the safety allow-list, including the
  Homebrew pkg-config failure at specialization.
- `base-continuation.log`: specialization and every remaining Base assertion,
  resumed with Homebrew libarchive metadata available.
- `base-compiler.json` and `final-compiler.json`: compiler identities. The only
  later functional edit was an additional diagnostic metadata-arity refusal;
  native emission stayed the same.

The continuation retained the imports, ROOT setup and `run` helper from
`tests/check_base.py`, skipped its already-executed calls from the initial
`make fpr` through `check_trust.py`, and executed the original source from
`check_specialization.py` to EOF. No test assertion or timeout was changed.

For a fresh uninterrupted run on this Apple Silicon Homebrew installation:

```sh
PKG_CONFIG_PATH="/opt/homebrew/opt/libarchive/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" python3 -u tests/check_base.py
```

One initial-run skip is retained: the POSIX RV64 artifact check requires a
RISC-V-capable compiler, which the local Clang does not provide. Other RV64
emission/QEMU checks in the suite have their own evidence in `base.log`.

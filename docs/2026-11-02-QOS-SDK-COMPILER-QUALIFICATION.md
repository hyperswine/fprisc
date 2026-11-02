# Compiler fixes found during QOS SDK qualification

The SDK 0.4.0 candidate uses FP-RISC `858238c`, codegen ABI 143. Qualification
found two compiler issues and fixed them without disabling checking:

- Local callback names now shadow global result shapes and ownership
  constraints. A local `error` callback is no longer treated as the builtin
  diverging operation. Regression coverage fails before the fix and passes
  after it.
- Implicit resource checking derives every declared work/allocation/live
  contract and its transitive dependencies. It no longer derives unrelated
  application equations merely because a bounded library is imported.
  Explicit cost reports and manifest judgements keep the full program view.
  An unused invalid contract still fails. Terra II now passes its frontend
  checks within the SDK's configured 2 GB heap limit; an uncapped diagnostic
  build before this change reached a sampled 26.6 GB physical footprint.

All 36 compiler unit suites, cost regressions (including unused invalid bounds,
higher-order composition and manifest budgets), and AArch64 FP context/pool
execution checks passed. The context oracle's integer-only negative control
failed as required.

SDK publication is held by one preferences retention assertion in the broader
QOS service sweep (15 of 16 groups passed). The installed graphical SDK,
external Dungeon/Terra II games, persistence, ABI refusal, pin policy and
FP values across scheduler yields passed. The
[QOS candidate report](https://github.com/hyperswine/qos/blob/main/docs/2026-11-02-PORTABLE-SDK-0.4.0-RELEASE.md)
records the outstanding gate. Homebrew still offers the previously published
SDK 0.3.1; the compiler fixes are source changes, not a replacement of the
immutable FP-RISC 0.13.1 archive.

After concurrent upstream changes were synced, combined FP-RISC source at
`a24055b` again passed all 36 unit suites and the cost regression suite. The SDK
candidate remains frozen at `858238c`; advance its pin and rerun SDK acceptance
when the outstanding retention gate is resolved.

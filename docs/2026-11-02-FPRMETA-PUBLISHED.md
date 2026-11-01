# fprmeta and qosmeta published through Homebrew

Status: done, 2 November 2026. This is step 4 ("Publish") of the
[toolchain manager proposal](2026-11-01-TOOLCHAIN-MANAGER.md), without signing.

## What changed

- The Homebrew tap (`hyperswine/homebrew-tap`) now has two formulas,
  `fprmeta` and `qosmeta`. They replace `fprisc` and `qos-portable`, which are
  renamed to them in `formula_renames.json`, so `brew upgrade` moves an
  existing install across.
  - `fprmeta` links `fprmeta`, `fpr` and `sol` to the one launcher binary.
  - `qosmeta` links `qosmeta` and `qos` to the same binary.
- The binary is released on its own: tag `fprmeta-v0.1.0`, archive
  `fprmeta-0.1.0-macos-arm64.tar.gz`. It links only `libSystem`.
- The version lists live in the tap: `toolchains/fprisc.json` and
  `toolchains/qos-portable.json`. fprmeta reads them from
  `raw.githubusercontent.com` unless `--index` or `FPRMETA_INDEX` /
  `QOSMETA_INDEX` names another list. This commit adds that built-in URL, and
  `fprmeta available` lists what a version list offers.
- The lists offer FP-RISC 0.12.0, the existing release, and QOS SDK 0.3.0,
  the first SDK with its own native `qos` command and `ld.lld`.

```sh
brew install hyperswine/tap/fprmeta hyperswine/tap/qosmeta
fprmeta install          # the newest FP-RISC toolchain, then the default
qosmeta install          # the newest QOS SDK
```

## Gaps

- **The lists are not signed.** Each entry's SHA-256 is checked, which catches
  a corrupt or replaced archive, but the list itself is trusted because it
  comes from GitHub. Ed25519 signing still needs a verifier that does not use
  Homebrew's OpenSSL.
- **Homebrew libraries are still needed.** FP-RISC 0.12.0, and the compiler
  inside SDK 0.3.0, load `libgit2` and `libarchive` from `/opt/homebrew/opt`,
  and SDK 0.3.0's `qosp-gl` loads `glfw`. The formulas depend on those three
  until releases bundle them (the self-contained archive work is on main, but
  no FP-RISC release has been cut from it).
- No `gc` command yet.

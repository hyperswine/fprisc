# Signed managers 0.2.0 are available through Homebrew

Status: published and installed-workflow checked, 2 November 2026.

Both `hyperswine/tap/fprmeta` and `hyperswine/tap/qosmeta` now install the
[0.2.0 manager release](https://github.com/hyperswine/fprisc/releases/tag/fprmeta-v0.2.0).
The signed indexes were published before the strict managers. Upgrade with:

```sh
brew update
brew upgrade hyperswine/tap/fprmeta hyperswine/tap/qosmeta
fprmeta available
qosmeta available
```

This macOS ARM64 binary requires **macOS 27.2 or later**. The formulas refuse
older systems before installation. It loads only macOS's libarchive and
libSystem. Updating the managers preserves the separately installed toolchain
and SDK versions, projects, caches and application data.

The archive SHA-256 is
`f5f9ee18878496e670a7cca0c35f72c0d49c799eee79f3aebb28c1867e86fc3b`;
its recorded source is `dfcb333c6e8e9fafbec5e36867cd43abb135fe25`.
`tools/package-fprmeta.py` packages a qualified binary from a clean commit and
records its archive, source, public key and system-library dependencies.

## What is available

- Comment-aware project pins, stable/prerelease/exact selection, signed-index
  verification, payload/index/platform/inventory refusals, atomic receipts,
  kernel locks and verified interrupted-install recovery.
- `which --json` format 1 for per-project compiler and SDK discovery.
- Signed indexes and the dedicated public key in the
  [Homebrew tap](https://github.com/hyperswine/homebrew-tap/tree/main/toolchains).
  The built-in key's fingerprint is
  `SHA256:pb+sg4pBrNy8hcRzKWsXW+hvIko4BOXgXbBBtqQCUj4`.

The first clean public install caught an existing metadata error: FP-RISC
0.13.0's index claimed macOS 27.0, while the archive declares 27.2. The manager
refused it. The entry was corrected to 27.2 and the index signed again; archive
bytes and hashes were preserved. Fresh installs then passed using the default
public URLs, without an unsigned-index override.

The compiler's own stricter project admission and QOS builder policy changes
are committed to their main branches. This manager release does not replace
the compiler or builder inside FP-RISC 0.13.0 or QOS SDK 0.3.0. They need their
next compiler/SDK releases to obtain those direct-check changes.

## Qualification

- Thirteen native manager contract test groups passed, including the editor
  selection API. The exact packaged manager passed 34 installed-workflow
  steps with FP-RISC 0.12.0/0.13.0 and QOS SDK 0.3.0; workspace source,
  GHC/Cabal and real manager homes were denied.
- Both Homebrew upgrades and formula tests passed. Formula tests verify the
  embedded production key against a signed local index and reject tampering.
- Fresh isolated stores installed FP-RISC 0.12.0 and 0.13.0 and QOS 0.3.0 from
  the public signed indexes through the installed Homebrew managers. Launches
  reported `fpr 0.13.0` and `QOS Portable 0.3.0`.
- The packaging-aware LSP was checked against those installed packages. See
  [editor integration](2026-11-02-EDITOR-MANAGED-TOOLCHAINS.md).

These are local macOS ARM64 checks. They do not claim Linux, Intel, GitHub CI
or a hardware QOS deployment. Exact pins remain release-selection contracts,
not hermetic-build guarantees; see the
[contract review](2026-11-02-PACKAGING-CONTRACT-FIXES.md).

The [release and editor evidence](evidence/2026-11-02-signed-managers-and-editor.json)
records the published archive hash, Homebrew outcomes and isolated VSIX check.

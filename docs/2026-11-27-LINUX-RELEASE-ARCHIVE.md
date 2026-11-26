# Linux toolchain archives: bundled libraries, built in a container (27 November)

Kind: delivery record. Branch `sol-libs`. Item 5 of the
[Sol review](2026-11-26-SOL-SCRIPTING-REVIEW.md) order (§5.4), with the owner's
choice of a bundled-libraries archive. Nothing was published: publishing to the
GitHub release and the `fprmeta` index waits for the owner.

## Result

Two candidate archives of `0.16.0-dev`, built from commit `2d23c473`:

| Archive | Size | SHA-256 | glibc floor | Bundled libraries |
|---|---|---|---|---|
| `fprisc-0.16.0-dev-linux-x86_64.tar.gz` | 34.0 MB | `ec5252d0…71aca3d33` | 2.36 | 50 |
| `fprisc-0.16.0-dev-linux-arm64.tar.gz` | 41.1 MB | `469c228e…249caa48` | 2.36 | 50 |

They are on the build Mac under `~/.cache/fprisc-linux/out-amd64/` and
`~/.cache/fprisc-linux/out/`. They are candidates rather than a release because
the tree's compiler reports `0.16.0-dev`. `tools/package-toolchain.sol` packages
only a version commit, and choosing to release 0.16.0 is the owner's call.

## Qualification

Each archive passed two runs:

1. **`tools/archive-smoke.sol` in the build container.** It stages with bundled
   libraries, packs with the release `tar` flags, and extracts to a path
   containing a space. It then runs `fpr --version`, `sol --version`,
   `fpr new` / `check` / `test` / `run -- Ada` / `build` (native), and a Sol
   script using `std/order`, with `HOME` empty and `PATH` limited to the
   archive's `bin`, `/usr/bin` and `/bin`. Its linkage check finds no
   `/usr/local` or Homebrew library.
2. **The archive alone in a fresh `debian:bookworm-slim`**, with only `gcc` and
   `libc6-dev` added: the same commands from a path containing a space. `ldd`
   shows every non-system library resolving from the archive's own `lib/`.

x86-64 ran under Rosetta on Apple silicon; arm64 ran natively. Neither has run on
real Linux hardware, and the `fprmeta` install path was not exercised.

## How it is built

- **Image** `packaging/linux/Dockerfile`:
  - Debian bookworm, so the archive's floor is glibc 2.36: Debian 12, Ubuntu
    22.10 and later, Fedora 37 and later.
  - GHC 9.8.2 and cabal 3.12.1.0 from ghcup, the compiler the macOS 0.15.0
    release used.
  - Two libraries newer than bookworm, which `fp-risc.cabal` requires:
    - libcurl ≥ 8.4 comes from bookworm-backports (8.14.1).
    - libgit2 ≥ 1.9 is built from the 1.9.1 release source into
      `/opt/libgit2-1.9.1`, because backports stops at 1.8.4. It uses HTTPS
      through OpenSSL and SSH through the system `ssh` binary
      (`USE_SSH=exec`), and its `COPYING` file goes in `share/licenses`.

  Building on trixie instead would need neither, but would raise the floor to
  glibc 2.41, excluding Ubuntu 24.04 LTS and RHEL.
- **Driver** `tools/linux-archive.sol --platform linux/amd64|linux/arm64 --rev REV --out DIR`:
  - builds the image;
  - in it, checks out the revision, runs `make fpr` and `archive-smoke`;
  - runs the clean-container smoke test.

  The build tree and cabal store persist under `~/.cache/fprisc-linux/<arch>`.
  The steps are inline in the Sol script, since the repository holds no shell
  scripts.
- **Bundling** `tools/toolchain-elf.sol`, used by `tools/stage-toolchain.sol` on
  Linux:
  - It takes the executable's closure from `ldd`.
  - It copies every library except glibc, its loader and `libgcc_s` into
    `libexec/fprisc/lib`, with each image's runpath set to `$ORIGIN` by
    `patchelf`.
  - It records, for each library, its Debian package and version and that
    package's `copyright` file. A library built from source instead takes its
    notices from `PREFIX/share/licenses`.
  - It checks that every ELF image loads only system libraries or toolchain
    ones.
  - It reads the glibc floor from the newest `GLIBC_` symbol version any image
    needs.
- **Packaging** `tools/package-toolchain.sol` and `tools/toolchain-release.sol`
  now accept Linux hosts: archives are named `linux-x86_64` and `linux-arm64`,
  as `archive-smoke` names them, the ELF checker replaces the Mach-O one, and
  the Homebrew formula is written only for macOS. They have not yet packaged a
  Linux release, because that needs a version commit.

## Problems met on the way

- A path that colima does not share (the scratchpad under `/private/tmp`) mounts
  as an empty directory, so build inputs and caches live under `$HOME`.
- With merged `/usr`, dpkg records `/lib/<triple>/libX.so` for what resolves to
  `/usr/lib/<triple>/...`, so packages are looked up by file name.
- Extracting into a directory shared from macOS fails on the read-only `bin/`,
  so the smoke test works in the container's own `/tmp`.
- Docker's `credsStore: desktop` points at a helper that does not exist under
  colima. The runs here used a temporary `DOCKER_CONFIG`; the owner's
  configuration was not changed.

## To release

1. Make a version commit (`0.16.0`).
2. Run `tools/linux-archive.sol` for both platforms at that commit.
3. Run `tools/package-toolchain.sol` in the same image. It adds the compiler's
   Haskell licence notices (`tools/compiler-licenses.sol`) and the release
   manifest.
4. Publish to the GitHub release and the `fprmeta` index. This step needs the
   owner's go-ahead.

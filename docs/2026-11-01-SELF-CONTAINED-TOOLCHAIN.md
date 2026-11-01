# Self-contained toolchain archives

Status: done on branch `self-contained-toolchain`, 1 November 2026. Nothing
was published and the Homebrew tap is unchanged. This is step 1 of the
[toolchain manager proposal](2026-11-01-TOOLCHAIN-MANAGER.md). Evidence:
[evidence/2026-11-01-self-contained-toolchain.json](evidence/2026-11-01-self-contained-toolchain.json).

## The problem

The 0.12.0 compiler loaded two libraries by absolute Homebrew path:

```text
/opt/homebrew/opt/libgit2/lib/libgit2.1.9.dylib
/opt/homebrew/opt/libarchive/lib/libarchive.13.dylib
```

Those two load seven more: `openssl@4` (libssl, libcrypto), `libssh2`,
`llhttp`, `xz` (liblzma), `zstd`, `lz4` and `libb2`. A toolchain unpacked by
`fprmeta` must not need any of them.

## What changed

**Bundled, not static.** Homebrew ships `.a` archives for eight of the nine
libraries, but not for `llhttp`, so a fully static link would mean building
`llhttp` ourselves. Bundling handles all of them the same way and leaves
developer builds (`make fpr`) unchanged:

- `tools/native_linkage.py` walks the compiler's `otool -L` closure. It copies
  every library outside `/usr/lib` and `/System` into `libexec/fprisc/lib/`,
  sets each one's install name to `@rpath/NAME`, and rewrites every reference
  to `@rpath/NAME`.
- It adds `LC_RPATH @executable_path/lib` to `fpr` and `@loader_path` to each
  library.
- It re-signs every changed file ad hoc (`codesign --force --sign -`), because
  `install_name_tool` invalidates the signature.
- It copies each library's licence files (`COPYING`, `LICENSE*`) from the
  prefix it came from into `libexec/fprisc/lib/licenses/PACKAGE-VERSION/`.
  A library with no notice stops the stage.
- `toolchain.json` lists the bundled libraries under `bundledLibraries`, with
  source path, package, version and notices.

The result adds 8.8 MB to a 62 MB compiler. Staging twice gives
byte-identical files.

**Refusals.**

- `tools/stage-toolchain.py` checks every Mach-O file in the stage after
  bundling. `tools/package-toolchain.py` checks the copy it is about to
  archive. A file may load only from `/usr/lib`, `/System`, or files inside the
  toolchain (through `@rpath`, `@loader_path` or `@executable_path`). Every
  `LC_RPATH` must point inside the toolchain too. A violation names the binary
  and the path:

  ```text
  libexec/fprisc/fpr loads /opt/homebrew/opt/libgit2/lib/libgit2.1.9.dylib
  (library outside /usr/lib, /System and the toolchain)
  ```

- The packager refuses a bundled library whose notices are missing.
- The packager refuses compiler notices collected for a different GHC than the
  plan used.

**Frozen Cabal plan.**

- `cabal.project.freeze` is committed. `cabal build` (and so `make fpr`) reads
  it automatically.
- It pins the 33 packages of the plan 0.12.0 was built from, their flags, and
  `index-state` 2026-10-30.
- A fresh `cabal freeze` at that index picked `network-3.2.10.0`; the freeze
  file was edited to `3.2.7.0`, the version in 0.12.0's plan. This is the same
  drift QOS hit.
- The stager records the plan of the compiler it stages (`cabalPlan` in
  `toolchain.json`). It records the plan only when the staged binary is
  byte-identical to that plan's `exe:fpr`; otherwise it records why not.
- The packager compares that record with the committed freeze: versions, and
  every frozen flag, including `fp-risc -dev`. It refuses any difference and
  lists each one, for example `network: plan 3.2.10.0, freeze 3.2.7.0`.

**Install check.**

- `tools/toolchain-install-check.py` makes `/opt/homebrew` unreadable to every
  step, as well as `/usr/local/opt` and `/usr/local/Cellar` where they exist.
  The optional `--qos` steps are the exception, because the QOS CLI is itself
  a Homebrew install.
- New steps:
  - `homebrew-libgit2-denied` and `homebrew-libarchive-denied` prove the
    denial works.
  - `dyld-libraries` runs `fpr --version` with `DYLD_PRINT_LIBRARIES=1`. It
    requires every loaded library to be a system one or a file inside the
    toolchain, and libgit2 and libarchive to be among the bundled ones.
  - `native-git` and `native-git-log` init, add, commit and read the log of a
    repository through `sol/lib/git`.
  - `native-archive` writes a `.tar.gz` through `sol/lib/archive`, and the
    check reads it back.
- As a control, the Homebrew-linked compiler from `main`, run under the same
  profile, stops at launch: "Library not loaded:
  /opt/homebrew/opt/libgit2/... (blocked by sandbox)".

**Formula.** `packaging/homebrew/fprisc.rb.in` no longer depends on `libgit2`
or `libarchive`.

## The proof

Candidate `0.13.0-rc1`:

- Branch `main` reports `0.13.0-dev`, and the packager accepts only a compiler
  that reports a release version. So the candidate is packaged from a local
  branch, `self-contained-candidate` (bb2a0c6). That branch is this work plus
  one commit that sets the version to `0.13.0`. It is not a release and is not
  pushed.
- Archive: `fprisc-0.13.0-rc1-macos-arm64.tar.gz`, 19.0 MB, SHA-256
  `ab779c1e…a3fe5`.
- Recursive `otool -L` over the 11 Mach-O files in the unpacked archive
  (`fpr` and the ten libraries) finds only:
  - `/usr/lib`: libSystem, libbz2, libcharset, libcurl, libexpat, libffi,
    libiconv, libz;
  - `@rpath/…` entries, each resolving to a file in `libexec/fprisc/lib`.

  The only rpaths are `@executable_path/lib` (in `fpr`) and `@loader_path`
  (in each library).
- `toolchain-install-check.py --release` passed all 51 steps with
  `/opt/homebrew` denied. These were the 45 existing steps plus the 6 new
  ones. dyld loaded all ten bundled libraries from the toolchain and nothing
  from anywhere else. Relocation and the read-only checks passed as before.
- The same check in staging mode, on the `0.13.0-dev` build from this branch,
  also passed all 51 steps.

## Updating the freeze on purpose

Do this when a dependency must move, and never as a side effect of building:

```sh
rm cabal.project.freeze
cabal update                      # only if a newer index is wanted
cabal freeze                      # resolves and writes the new plan
git diff cabal.project.freeze     # review every version that moved
make fpr && make unit-tests
```

Commit the freeze in its own commit, and say why each version moved. Then
stage and package as usual. The packager compares the new build with the new
freeze. Note that `cabal freeze` writes `index-state`, so a later
`cabal update` does not change the resolution.

## Not covered

- `brew install` of the candidate was not run (the tap is untouched).
  Homebrew rewrites the install names of dylibs inside a keg when it installs
  a formula. Loading goes through `@rpath`, so that should be harmless, but it
  is unverified. `fprmeta` will not go through Homebrew.
- Pushing over SSH (libgit2 with libssh2 and OpenSSL) was not exercised with
  Homebrew denied. Local repository operations and libarchive were.
- The bundled OpenSSL still has `OPENSSLDIR` `/opt/homebrew/etc/openssl@4`
  compiled in. With it unreadable, everything exercised still worked. HTTPS
  remotes for libgit2 would need CA certificates; the compiler uses only SSH
  remotes today.
- Linux keeps using system libraries through `pkg-config`. The stager bundles
  only on macOS.

## For QOS to copy

- The QOS SDK's private compiler has the same two Homebrew libraries.
  `tools/native_linkage.py` is standalone: `bundle(sdk, executable)` and
  `problems(prefix, executable)`. QOS's SDK packager can import it, or copy
  it, for its compiler and for `qosp-gl` (Homebrew `glfw`).
- QOS needs its own `cabal.project.freeze` and the same plan comparison. The
  `frozen_plan` and `plan_drift` helpers in `tools/package-toolchain.py` can
  be reused.
- The install-check pattern carries over: deny `/opt/homebrew`, prove the
  denial, and record what dyld actually loaded.

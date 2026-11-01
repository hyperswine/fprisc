# Proposal: a toolchain manager instead of versioned formulas

Status: proposal, 1 November 2026. Nothing here is shipped. It changes how
roadmap steps 1 and 5 of the
[installed toolchain roadmap](2026-10-30-INSTALLED-TOOLCHAIN-ROADMAP.md) are
delivered. Steps 2 to 4 are unchanged. The QOS side, which also covers making
the app-side HAL a black box, is in QOS
`docs/2026-11-01-SDK-PROCESS-APPS.md`.

## The idea

Today Homebrew installs one version of FP-RISC (`fprisc` 0.12.0) and one
version of the QOS SDK (`qos-portable` 0.2.0). An upgrade replaces the old
version in place. A project that needs the older compiler has no way to keep
it.

Instead, Homebrew installs small managers:

- **`fprmeta`** for FP-RISC toolchains, with versions under `~/.fpr`;
- **`qosmeta`** for QOS SDKs, with versions under `~/.qos`.

Each manager downloads and verifies a version, unpacks it into its own folder,
and runs the right version for each project. Both are the same binary, which
acts as one or the other from its own name, the way `fpr` acts as `sol`. So
there is one implementation of downloading, checking, installing and choosing
a version, and two names. The two can be installed separately: a QOS SDK
carries its own private compiler, so someone building only QOS apps never
needs `fprmeta`.

```text
brew install hyperswine/tap/fprmeta     # links fprmeta, fpr, sol
brew install hyperswine/tap/qosmeta     # links qosmeta, qos

~/.fpr/                     # FPRMETA_HOME overrides
  0.12.0/                   # unpacked release: fpr, core, std, sol/lib, runtime inputs
  0.13.0/
  settings.toml             # the default version
  receipts/                 # what was installed, from which archive, verified how
  lock                      # one installer at a time

~/.qos/                     # QOSMETA_HOME overrides; the same layout
  0.2.0/                    # whole SDK, including its own private matched compiler
  settings.toml  receipts/  lock
```

```sh
fprmeta install 0.12.0
fprmeta install                     # newest
fprmeta default 0.13.0
fprmeta list                        # installed, default, newest available
fprmeta which fpr                   # the binary this directory would run
fprmeta uninstall 0.12.0
fprmeta gc                          # remove versions the launcher has not run for N days; never the default
fpr +0.12.0 build                   # one command on a named version

qosmeta install 0.2.0               # the same commands for QOS SDKs
qos +0.2.0 build
```

`fpr`, `sol` and `qos` stay the commands people type. The formulas link them
to launchers, so there are no PATH edits, as with `rustup` proxies.

## Choosing a version

For each command, the launcher picks the version in this order:

1. `+VERSION` as the first argument (`fpr +0.12.0 build`).
2. `FPR_TOOLCHAIN` (for `qos`, `QOS_SDK`) in the environment.
3. The project's pin, found by walking up from the current directory. It is
   either a compatible pin or an exact one:

   ```toml
   [toolchain]
   fpr = "0.12.0"     # compatible: 0.12.0 or any later 0.12.x
   fpr = "=0.12.3"    # exact: 0.12.3 and nothing else
   ```

   - **Compatible** (`"0.12.0"`). This is what `fpr.toml` already means
     ([project workflow](2026-10-31-PROJECT-WORKFLOW.md)): the oldest
     compatible version in the same series. The launcher runs the newest
     *installed* version in that series that is not older than the pin.
   - **Exact** (`"=0.12.3"`). The launcher runs exactly that version.
     `+VERSION` and the environment still win, so it is possible to try a
     newer compiler on a pinned project without editing it. `fpr` itself also
     checks the pin, so a compiler run directly, not through the launcher,
     refuses a project that pins a different exact version.
   - **Older toolchains.** Today's `Project.hs` refuses `"=0.12.3"` with exit
     2 ("the toolchain is a version"). So an older toolchain never misreads an
     exact pin as a compatible one; it stops. The change is small: `compatible`
     gains the exact case, and the error message learns the `=` form.
     `fpr.toml` can stay at manifest format 1.
   - **`qos.toml`.** v1 refuses unknown keys, so the SDK pin needs a `qos.toml`
     v2 with `[sdk] version`, using the same two forms. See the QOS proposal.
4. The default in `settings.toml`.

If nothing installed satisfies the pin, the command stops with exit 2 and
prints the install command to run, for example `fprmeta install 0.12.3`. It
never silently uses another version, and it never downloads unasked.
Auto-install can be an opt-in setting later.

`fpr new` writes a compatible pin. `fprmeta pin` (with no argument: the
version this directory would run now) rewrites the project's pin to the exact
form. It changes only that one line of `fpr.toml`.

`fpr build --release` and `qos build` already record the compiler identity.
They should also record the exact version the launcher chose, so a build can
be repeated exactly even under a compatible pin.

### Launchers must be real executables

The `sol` symlink test (30 October) showed that macOS refuses a shell script as
a shebang interpreter: `#!/opt/homebrew/bin/sol` broke when `sol` was a
wrapper script. So the launchers are one small native binary. `fpr`, `sol` and
`qos` are links to it, and it dispatches on its own name.

- It then `exec`s the chosen version's real binary with the same name in
  `argv[0]`, because `fpr` already decides to act as Sol from its own name.
  Checked: `compiler/Main.hs` uses `getProgName`, which is `argv[0]`, not the
  executable's path, so this works without changing the compiler.
- The launcher must start in a few milliseconds. The script wrapper cost about
  7 ms, which is the budget to beat.

It can be written in FP-RISC and built by the toolchain itself. The install
check already shows an `fpr`-built executable running with the SDK
unreadable.

## What a version must provide

The manager installs whatever a release archive contains. Each archive must
therefore be self-contained and declare what it needs.

1. **No Homebrew paths inside.** This is not true today:
   - the 0.12.0 compiler links `/opt/homebrew/opt/libgit2` and
     `/opt/homebrew/opt/libarchive` by absolute path;
   - QOS 0.2.0's `qosp-gl` links Homebrew `glfw`;
   - its `bin/qos` is a script the formula writes, pointing at Homebrew's
     `python@3.14`, `llvm`, `lld` and the Cellar.

   Each release either links these libraries statically or ships them beside
   the binary and loads them relative to it (`@rpath`). The release packager
   refuses a binary whose `otool -L` names anything outside `/usr/lib` and
   `/System`, or the archive itself.
2. **Its own entry points.** The archive carries `bin/fpr` (and `bin/qos` for
   the SDK) as files. `toolchain.json` or `sdk.json` lists the commands the
   version provides, and the launcher refuses any name not on that list.
3. **Declared external requirements.** These are things the manager does not
   install: Apple's Command Line Tools for native FP-RISC builds, and Python
   3.11+, an ELF-capable Clang and `lld` for QOS today. The manager checks
   them at install time and `fpr doctor` reports them. The QOS proposal
   removes Python and ships `lld`, so a QOS SDK needs only what FP-RISC
   needs.
4. **Moving its folder works.** This is already qualified:
   - the FP-RISC install check moves the unpacked toolchain and builds again;
   - `compiler/Home.hs` finds `std` beside the real executable when
     `FPR_HOME` is unset;
   - QOS 0.2.0's acceptance ran from the unpacked tarball.

   The manager therefore sets no environment variables. That matters because
   `FPR_HOME` already means "this compiler's home". The managers' own folders
   are `~/.fpr` and `~/.qos` by default, overridden by `FPRMETA_HOME` and
   `QOSMETA_HOME`. `~/.fpr` is the intended default, not the XDG folders.
   Downloads in progress live in `~/.fpr/tmp/` too, so an install never
   crosses file systems.

## Version list and trust

Each manager has a signed list, `index.json`, published with each release and
fetched from a fixed URL: one for FP-RISC, one for QOS. Each entry names one
version for one platform:

```json
{ "component": "fprisc", "version": "0.13.0", "platform": "macos-arm64",
  "url": "https://github.com/hyperswine/fprisc/releases/download/v0.13.0/fprisc-0.13.0-macos-arm64.tar.gz",
  "sha256": "...", "size": 41234567, "minimumOS": "27.0",
  "requires": ["xcode-clt"], "yanked": false }
```

- **Signing.** A checksum fetched from the same release only catches
  corrupted downloads. The list is signed (minisign or signify), and the
  public key is built into the managers. The manager refuses an unsigned or
  wrongly signed list, and any archive whose hash differs from its entry.
- **Withdrawn releases.** `yanked` withdraws a broken release from `install`
  and `default`, without breaking projects that already have it.
- **Offline.** `fprmeta install --archive FILE --signature FILE` installs a
  tarball you already have, for CI and machines without network.

## Installing safely

1. Take `~/.fpr/lock` (`~/.qos/lock`), so only one installer runs at a time.
2. Download into `~/.fpr/tmp/` (`~/.qos/tmp/`).
3. Check the hash.
4. Unpack.
5. Check every file against the archive's own `toolchain.json` or `sdk.json`
   inventory.
6. Remove write permission, which matches how qualification runs.
7. Rename the folder into place, so a half-finished install never appears.
8. Write a receipt.

Uninstalling removes only that version's folder and receipt. Projects, build
caches (`XDG_CACHE_HOME`), QOS disks and Sol recovery state live elsewhere, and
nothing the manager does may touch them.

## Homebrew's role

- The tap gets two formulas built from the same source. `fprmeta` links
  `fprmeta`, `fpr` and `sol` to the launcher; `qosmeta` links `qosmeta` and
  `qos`. Each `brew test` runs an install from a local signed list and a
  tarball bundled with the test.
- The `fprisc` and `qos-portable` formulas are deprecated, with caveats saying
  how to move: `fprmeta install 0.12.0` or `qosmeta install 0.2.0`, then
  `brew uninstall` the old formula. `fprmeta` conflicts with `fprisc` and
  `qos-fpr`, and `qosmeta` with `qos-portable` and `qos-fpr`, because each
  pair installs the same command names.
- Homebrew still upgrades the manager. Toolchains are never upgraded in
  place: a new version installs beside the old one.

This drops Homebrew's per-version checks (`brew test`, `brew linkage`,
dependency tracking). The existing install checks
(`tools/toolchain-install-check.py`, QOS `portable-sdk-check.py`) become the
release gate. They run against the archive that the version list names.

## Disk use

Each version is a full copy. That is small for FP-RISC. QOS SDKs carry their
own compiler and a profile. A later step can store files once by content hash
and hard-link them into each version folder, so an SDK and a toolchain that
share a compiler binary share its bytes. Hard links need one file system, so
the store would live under `~/.fpr` and `~/.qos` would use it only when both
are on the same volume. This is not
needed for the first version.

## What "upgrade testing" becomes

The planned 0.12.1 `brew upgrade` test is replaced by:

1. `fprmeta install 0.12.1` beside 0.12.0.
2. Check that a project pinned exactly (`"=0.12.0"`) still builds with
   0.12.0, with byte-identical output.
3. Check that a project with a compatible pin (`"0.12.0"`) now builds with
   0.12.1, and that its build records 0.12.1.
4. Uninstall 0.12.0 and check that the projects, their caches and Sol recovery
   state are untouched. The exactly pinned project then gets the exit-2
   message naming `fprmeta install 0.12.0`.
5. For QOS, the same steps with `qosmeta`, plus the existing disk check: an app's stored data
   survives a move to a new SDK version.

Freezing the Cabal plan (`cabal.project.freeze`) is still required in every
case. Without it, rebuilding the same commit does not give the same compiler
(QOS 0.2.0 hit this).

## Order of work

1. **Self-contained archives.**
   - Link or bundle libgit2 and libarchive (and glfw for QOS).
   - Add the `otool -L` refusal to the packagers.
   - Freeze the Cabal plan.
   - Release FP-RISC 0.12.1 this way, still through the existing formula, so
     nothing changes for users yet.
2. **`fprmeta` for FP-RISC only.**
   - The manager, launchers, a local signed version list, and the steps under
     "Installing safely".
   - Exact pins in `Project.hs` (`"=VERSION"`) and `fprmeta pin`.
   - Acceptance: the steps under "What upgrade testing becomes", with
     checkouts denied as in the install check.
3. **`qosmeta`.**
   - The same binary acting as `qosmeta`, with `~/.qos`.
   - `qos.toml` v2 with the SDK pin, compatible or exact.
   - The SDK ships its entry point without Python, and ships `lld`.
   - Builds standalone process apps without vendored files (the QOS
     proposal).
4. **Publish.** Signing key, hosted version lists, the `fprmeta` and `qosmeta`
   formulas, and deprecating `fprisc` and `qos-portable`.
5. **Linux** (arm64 first, on the existing VM). This is the first platform
   where Homebrew is not the natural home anyway.

## Decided (1 November 2026)

- **Names:** `fprmeta` for FP-RISC toolchains and `qosmeta` for QOS SDKs. They
  are one binary that acts as either from its own name.
- **Exact pins:** projects can pin an exact version (`"=0.12.3"`) as well as
  a compatible one (`"0.12.0"`).
- **Folders:** `~/.fpr` by default (`~/.qos` for SDKs), not the XDG
  locations. `FPRMETA_HOME` and `QOSMETA_HOME` override them.

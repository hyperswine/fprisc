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

Instead, Homebrew installs a small manager, `fprup` (name open). The manager:

- downloads and verifies each FP-RISC toolchain or QOS SDK version;
- unpacks it into its own folder under `~/.fpr`;
- runs the right version for each project.

```text
brew install hyperswine/tap/fprup

~/.fpr/
  fprisc/0.12.0/            # unpacked release: fpr, core, std, sol/lib, runtime inputs
  fprisc/0.13.0/
  qos-portable/0.2.0/       # whole SDK, including its own private matched compiler
  settings.toml             # default version per component
  receipts/                 # what was installed, from which archive, verified how
  lock                      # one installer at a time
```

```sh
fprup install fprisc@0.12.0
fprup install qos-portable          # newest
fprup default fprisc@0.13.0
fprup list                          # installed, default, newest available
fprup which fpr                     # the binary this directory would run
fprup uninstall fprisc@0.12.0
fprup gc                            # remove versions unused for N days, never a default
fpr +0.12.0 build                   # one command on a named version
```

`fpr`, `sol` and `qos` stay the commands people type. The formula links them
to launchers, so there are no PATH edits, as with `rustup` proxies.

## Choosing a version

For each command, the launcher picks the version in this order:

1. `+VERSION` as the first argument (`fpr +0.12.0 build`).
2. `FPR_TOOLCHAIN` (or `QOS_SDK`) in the environment.
3. The project's pin, found by walking up from the current directory:
   - `fpr.toml`'s `[toolchain] fpr`. This already exists
     ([project workflow](2026-10-31-PROJECT-WORKFLOW.md)) and means "the oldest
     compatible version in the same series". The launcher runs the newest
     *installed* version in that series that is not older than the pin.
   - `qos.toml`'s SDK pin. `qos.toml` v1 refuses unknown keys, so this needs a
     `qos.toml` v2 with `[sdk] version`. See the QOS proposal.
4. The default in `settings.toml`.

If nothing installed satisfies the pin, the command stops with exit 2 and
prints the `fprup install` command to run. It never silently uses another
series, and it never downloads unasked. Auto-install can be an opt-in setting
later.

`fpr build --release` and `qos build` already record the compiler identity.
They should also record the exact version the launcher chose, so a build can
be repeated exactly.

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
   `FPR_HOME` already means "this compiler's home". The manager's own folder
   variable is `FPRUP_HOME`, with `~/.fpr` as the default.

## Version list and trust

There is one signed list, `index.json`, published with each release and
fetched from a fixed URL. It has one entry per component, version and platform:

```json
{ "component": "fprisc", "version": "0.13.0", "platform": "macos-arm64",
  "url": "https://github.com/hyperswine/fprisc/releases/download/v0.13.0/fprisc-0.13.0-macos-arm64.tar.gz",
  "sha256": "...", "size": 41234567, "minimumOS": "27.0",
  "requires": ["xcode-clt"], "yanked": false }
```

- **Signing.** A checksum fetched from the same release only catches
  corrupted downloads. The list is signed (minisign or signify), and the
  public key is built into `fprup`. The manager refuses an unsigned or
  wrongly signed list, and any archive whose hash differs from its entry.
- **Withdrawn releases.** `yanked` withdraws a broken release from `install`
  and `default`, without breaking projects that already have it.
- **Offline.** `fprup install --archive FILE --signature FILE` installs a
  tarball you already have, for CI and machines without network.

## Installing safely

1. Take `~/.fpr/lock`, so only one installer runs at a time.
2. Download into `~/.fpr/tmp/`.
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

- The tap gets an `fprup` formula. It installs the manager and links `fpr`,
  `sol` and `qos` to the launcher. Its `brew test` runs an install from a
  local signed list and a tarball bundled with the test.
- The `fprisc` and `qos-portable` formulas are deprecated, with caveats saying
  how to move: `fprup install` the same versions, then `brew uninstall` the
  old formulas. `fprup` declares `conflicts_with` both, because they install
  the same command names.
- Homebrew still upgrades the manager. Toolchains are never upgraded in
  place: a new version installs beside the old one.

This drops Homebrew's per-version checks (`brew test`, `brew linkage`,
dependency tracking). The existing install checks
(`tools/toolchain-install-check.py`, QOS `portable-sdk-check.py`) become the
release gate. They run against the archive that the version list names.

## Disk use

Each version is a full copy. That is small for FP-RISC. QOS SDKs carry their
own compiler and a profile. A later step can store files once by content hash
(`~/.fpr/store/sha256/…`) and hard-link them into each version folder, so an
SDK and a toolchain that share a compiler binary share its bytes. This is not
needed for the first version.

## What "upgrade testing" becomes

The planned 0.12.1 `brew upgrade` test is replaced by:

1. Install 0.12.1 beside 0.12.0.
2. Check that a project pinned to 0.12.0 still builds with 0.12.0, with
   byte-identical output.
3. Check that an unpinned project uses the new default.
4. Uninstall 0.12.0 and check that the project, its caches and Sol recovery
   state are untouched. A project pinned to 0.12.0 then gets the exit-2
   message naming the install command.
5. For QOS, the same steps, plus the existing disk check: an app's stored data
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
2. **`fprup` for FP-RISC only.**
   - The manager, launchers, a local signed version list, and the steps under
     "Installing safely".
   - Acceptance: the steps under "What upgrade testing becomes", with
     checkouts denied as in the install check.
3. **QOS SDK as a component.**
   - `qos.toml` v2 with the SDK pin.
   - The SDK ships its entry point without Python, and ships `lld`.
   - Builds standalone process apps without vendored files (the QOS
     proposal).
4. **Publish.** Signing key, a hosted version list, the `fprup` formula, and
   deprecating `fprisc` and `qos-portable`.
5. **Linux** (arm64 first, on the existing VM). This is the first platform
   where Homebrew is not the natural home anyway.

## Open questions

- **The name.** Options: `fprup`, `fprm`, or `fpr toolchain …` inside the
  launcher itself.
- **Exact pins.** Should a project be able to pin an exact version (for
  example a lock entry written by `fpr build --release`), or is "oldest
  compatible in the series" plus the recorded build identity enough?
- **The folder.** `~/.fpr`, as asked, or the XDG locations
  (`~/.local/share/fpr` for data, `~/.cache/fpr` for downloads). `FPRUP_HOME`
  overrides either.

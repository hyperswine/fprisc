# Installed FP-RISC developer toolchain

Status: roadmap and local feasibility work, 30 October 2026. Commands explicitly
marked proposed below are not shipped interfaces. No standalone FP-RISC Homebrew
release has been published by this work.

## Intended experience

Install a versioned toolchain once, then develop outside the compiler repository.
Native applications, Sol scripts and selected cross builds should need no GHC,
Cabal, contributor checkout, Makefile invocation or environment-variable setup.
The package supplies its language libraries and internal native runtime inputs;
building native applications still requires a C compiler, assembler/linker and
platform SDK, installed or diagnosed automatically. Running Sol does not require
that native-build toolchain. Applications and durable data live outside the
Homebrew Cellar, release directories and temporary folders.

Proposed project-level interface:

```sh
brew install hyperswine/tap/fprisc
fpr new hello --template=cli
cd hello
fpr check
fpr run
fpr build --release
fpr test
sol --repl
```

Existing `fpr build file.fpr`, `fpr run file.fpr`, `fpr sol file.sol` and Sol's
REPL already work. The formula, project discovery, `new`, `check`, `test` and
`--release` interface above remain proposed. The existing `--manifest` flag
names a cost contract; do not reuse it for a project manifest.

## Roadmap

### 1. Standalone installed compiler and Sol package

Stage a prebuilt compiler, `fpr`/`sol` launchers, `core`, `std`, Sol libraries,
committed module inputs, runtime sources/headers and POSIX host files as one
versioned SDK. Runtime C files are internal SDK build inputs, not a contributor
checkout. Use the current C-object cache first; prebuilt runtime archives can be
an optimization once the target, ABI, hart count and build-mode contract is
defined. Do not introduce a new runtime ABI just to package this slice.

Record the exact staged bytes, compiler hash, revision/dirty status, target and
native library dependencies. Release qualification additionally needs dependency
notices, a clean versioned source/build identity, checksums and minimum-OS checks.
Reuse the QOS release experience, while keeping FP-RISC's package independent
of QOS's runtime and SDK.

Sol already has its own prefix installer
([Sol installation](2026-10-29-SOL-INSTALLATION.md): `make sol-install` /
`tools/sol-install.py`). It installs `PREFIX/bin/sol` and refuses to replace
an unrelated `bin/sol`. Decide whether the formula replaces that path or the
two stay separate install methods. Then document what happens when a prefix
install and a Homebrew install are both on PATH, and which `sol` owns the
recovery journals.

The initial host is macOS ARM64. This checkout's compiler currently records
macOS **27.0** as its minimum. Supporting older macOS needs a deliberate rebuild
and acceptance run; changing a formula requirement cannot lower that binary's
minimum. Current dynamic dependencies include Homebrew libgit2 and libarchive,
alongside Apple system libraries. Ordinary native application builds use Apple's
Command Line Tools in the local feasibility probe.

Command ownership must be resolved before co-installation is advertised. Two
QOS formulas install global commands today:

- `qos-portable` 0.1.0 installs `bin/fpr` (a wrapper around its private
  compiler) and `bin/qos`. Its builder verifies the bundled compiler's hash.
  Keep that private, matched compiler intact.
- `qos-fpr`, the source contributor toolchain (QOS
  `packaging/homebrew/qos-fpr.rb`), installs `bin/fpr`, `bin/sol` and
  `bin/qos`. `qos-portable` already declares `conflicts_with "qos-fpr"`.

**`qos build` already exists and selects QOS's private compiler**, so a new
builder entry point is unnecessary. The plan is that standalone FP-RISC owns
global `fpr` and `sol`, which takes these changes, in this order:

1. A QOS Portable release that stops exporting global `fpr`. This changes a
   published interface: the 0.1.0 quickstart, the formula caveats, the
   formula test and QOS's workflow docs all use
   `fpr build --target=qos-portable`. So it needs a new version with a
   migration note pointing to `qos build`, not only updated examples. It
   must ship before or together with the FP-RISC formula; until it does,
   Homebrew cannot link both `fpr` binaries.
2. The FP-RISC formula declares `conflicts_with "qos-fpr"`, unless `qos-fpr`
   is retired or stops exporting `fpr` and `sol` first.

`fpr build --target=qos-portable` is not a hypothetical integration. It is
already in `compiler/Build.hs` (`qosPortable`, since `32bad6f`). It runs
`tools/portable_sdk.py` found beside the running compiler, or
`QOS_PORTABLE_BUILDER`. Standalone `fpr` has no such file, so today it fails
with "install a matching QOS Portable SDK and use its bin/fpr", and once
step 1 ships no such `bin/fpr` will exist. With `QOS_PORTABLE_BUILDER` set,
QOS's builder refuses the standalone compiler because its hash does not
match. That failure is safe, but the message points nowhere. Choose one:

- **Keep the dispatch**, and have it explicitly find an installed QOS SDK
  (for example through `qos` on PATH). It must run that SDK's builder with
  the SDK's own compiler, not pass itself as `--compiler`.
- **Remove the dispatch** and replace it with a refusal that points to
  `qos build`.

Either way, it must never silently substitute a newly upgraded compiler into
an older QOS package.

First acceptance (passed locally on 30 October 2026; see the
[feasibility record](#first-step-feasibility-record) below; release
qualification remains open): from a fresh external directory and isolated caches, make the
staged SDK read-only, deny access to contributor checkouts and deny execution of
GHC/Cabal/make/Git. Build and execute a native application, run Sol with installed
library imports and its REPL, check diagnostics, and show that the generated
application can execute with the SDK inaccessible. Exercise paths containing
spaces, relocation and unchanged installed file hashes. This is local SDK
feasibility; actual Homebrew installation/upgrade is a separate gate.

### 2. Small external-project workflow

Introduce a versioned project manifest: entry point, application kind, dependency
identities, selected target and compatible toolchain. Preserve explicit-file
commands. Start with native CLI, native service and Sol templates, clear check
diagnostics, a small test convention and `fpr doctor`. Reuse installed-compiler
discovery in the editor extension; module checking must not require `main`.
Avoid adding an expansive package manager before these workflows are useful.

Avoid name clashes with QOS. QOS already has `qos new`, and its builder
finds `qos.toml` by walking up parent directories. Give the FP-RISC project
manifest a different filename, so neither tool picks up the other's project.
A proposed `fpr check` would also sit beside the existing `fpr stdcheck` (the
std proof pass); name or document the difference.

### 3. Managed cross targets

Current native target selection already supports Linux AArch64/x86-64/RV64 and
macOS x86-64; Linux cross builds require a caller-supplied `--cc`. Add versioned,
checksum-verified target toolchains and sysroots, with explicit libc/ABI and
minimum-OS contracts. Proposed interface:

```sh
fpr target add linux-aarch64
fpr build --target=linux-aarch64
```

First qualify macOS ARM64 to macOS x86-64 and Linux AArch64, then Linux x86-64 and
RV64. Each target gets build and execution evidence separately; Rosetta/QEMU
functional evidence is not physical-host performance evidence. Keep ESP-IDF and
bare-metal toolchains explicit add-ons. No Windows support is implied.

### 4. Application delivery and services

Package executable, assets, dependency inventory and application version through
a documented command. Provide service templates with launchd/systemd setup,
restart behavior, logs, permanent data paths and an upgrade/rollback procedure.
Explain login-scoped versus boot-time services. Never install mutable application
data into a toolchain version or temporary directory. Logbook's restoration is
a practical input to this contract, not a compiler-specific deployment protocol.

### 5. Release and upgrade qualification

Test actual Homebrew install and upgrade using the same public artifact as users.
Keep source checkouts inaccessible and the SDK read-only during external native,
Sol and selected cross-target workflows. Upgrading/removing the toolchain must
leave projects, service data and Sol recovery state intact. Test QOS coexistence
and preserve its private compiler identity. Keep a bounded smoke gate for each
release, with larger host/target matrices separate from everyday feedback.

## First-step feasibility record

**The installed SDK core is feasible and passed locally.**
`tools/stage-toolchain.py` now stages a private standalone SDK without installing
global commands. `tools/toolchain-install-check.py` qualifies it with real access
denial, a minimal tool PATH and fresh caches. The
[recorded evidence](evidence/2026-10-30-installed-toolchain-feasibility.json)
contains 22 completed steps, including negative guard probes. It covers:

- An external native application importing installed `std/list`, both build and
  run commands, module checking without `main`, module building and diagnostics.
- Installed Sol library imports, an executable shebang script and a REPL command.
- macOS x86-64 output built on ARM64 and executed successfully under Rosetta.
- SDK, project and cache paths containing spaces, SDK relocation, fresh builds
  after relocation, and unchanged installed file hashes.
- Executing the native application while access to both contributor checkouts
  and the installed SDK is denied.
- A real external counter built by the installed QOS 0.1.0 `qos build`, with the
  standalone `fpr` on PATH. QOS selected its own hash-matched private compiler;
  no package, global command or QOS compiler was modified.

The initial run exposed a native driver bug: `Compile` writes `.units` as one
path per line, but `Build` read it with `words`. A cache path containing spaces
was split into invalid assembler inputs. `Build` now reads the list with
`lines`; the same installed workflow passed after rebuilding. The evidence
retains the failing binary identity and diagnostic as well as the fixed result.
The fix covers `fpr build`/`fpr run` only. The contributor make rules still
expand `.units` with `$(cat ...)`, which splits on spaces: `fprisc/Makefile`
(virt, base and builtin images) and QOS `qos-app.mk`. They fail the same way
when unit paths contain spaces, for example under a cache directory with a
space in it. They are outside the installed workflow, but still need fixing.

Reproduce on macOS with the required system C toolchain and existing dynamic
libraries available; `--output` must be a fresh directory outside the workspace:

```sh
make fpr
python3 tools/toolchain-install-check.py --output /private/tmp/fprisc-install-check
# Optional coexistence check when QOS Portable is installed:
python3 tools/toolchain-install-check.py --qos /opt/homebrew/bin/qos \
  --output /private/tmp/fprisc-install-check-with-qos
```

The C toolchain is needed for native builds, not ordinary Sol execution. The
compiler's macOS minimum remains 27.0. This was an uncommitted local candidate,
not a clean release build or proof of older-macOS/Linux support.

Next concrete release work, in order:

1. Release a QOS Portable version that uses its existing `qos build` without
   exporting global `fpr`, with a migration note for 0.1.0's
   `fpr build --target=qos-portable`.
2. Decide what happens to the `qosPortable` dispatch in `Build.hs`: keep it
   and have it select the installed QOS SDK, or replace it with a refusal
   that points to `qos build`.
3. Generate the binary archive and formula with notices, a clean release
   identity and `conflicts_with "qos-fpr"`.
4. Settle `sol` ownership against the existing Sol prefix installer.
5. Test actual Homebrew installation, upgrade and co-installation with
   `qos-portable`. The QOS probe above establishes build-time compiler selection, not
Homebrew co-installation. Native project scaffolding and the manifest belong to
the following workflow slice; they are not required to package the already
working explicit-file commands.

Related work: [Sol installation](2026-10-29-SOL-INSTALLATION.md),
[Logbook service restoration](2026-10-30-LOGBOOK-M1-RESTORE.md), and the sibling
QOS repository's `docs/2026-10-29-DESKTOP-RELEASE.md`.

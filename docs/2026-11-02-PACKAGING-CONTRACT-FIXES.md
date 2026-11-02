# Packaging contracts after the manager review

Status: manager fixes published as 0.2.0 on 2 November 2026; see the
[release and qualification](2026-11-02-SIGNED-MANAGERS-RELEASE.md). The original
candidate checks below preceded publication. Compiler and SDK direct-check
changes remain on main for their next releases.

## 1. Project pins are authoritative

The launcher's pin reader strips comments outside strings before reading
section headers and assignments. `[toolchain] # compiler` and `[sdk] # SDK`
therefore select the project's pin, including from nested working directories.
Basic and literal quoted version strings work; a quoted `#` elsewhere in the
manifest does not start a comment. Malformed pin values, duplicate pin keys,
and malformed section headers fail with the manifest and line rather than
silently choosing the default. A nearest `fpr.toml` missing its required pin
also fails. A legacy `qos.toml` without an SDK pin can still use the default.

`pin VERSION` rewrites the pin assignment and retains its comment, including
when its previous string used literal quotes or escapes.

## 2. One release-selection policy

The launcher, direct FP-RISC project commands, native QOS builder and reference
Python QOS builder now use these rules:

| Pin | Admitted versions |
| --- | --- |
| `0.3.0` | Stable `0.3.x` releases at least `0.3.0`; excludes `0.4.0` and `0.3.1-dev` |
| `1.2.0` | Stable `1.x` releases at least `1.2.0`; excludes `2.0.0` |
| `=0.3.0-rc.1` | Exactly `0.3.0-rc.1`, including its tag |
| `0.3.0-rc.2` | Versions at least that prerelease in the same series, explicitly including prereleases |

Pins require three canonical numeric components fitting FP-RISC Int, with optional nonempty
alphanumeric/hyphen tag identifiers separated by dots. Numeric prerelease
identifiers compare numerically (`rc.10` follows `rc.2`), including identifiers
larger than a machine integer. A bare `install` selects the newest stable
release; installing a prerelease requires naming it.

The compiler uses `toolchain.json`'s release identity when installed, rather
than discarding its prerelease tag or relying on a binary reporting only the
base version. `new`, project admission and `doctor` use that same identity.
Development checkouts fall back to the compiler's build version. A development
QOS stage with no release number retains its explicit warning and unchecked
pin behavior; it is not a qualified release SDK.

The FP-RISC version policy lives in `tools/fprmeta/version.fpr`; QOS carries
the same implementation in `tools/qos/version.fpr` so an installed SDK needs
no sibling checkout. Native/reference policy parity is covered by tests.
These compiler/builder fixes require their next respective releases; updating
only the manager cannot change an older toolchain's own project checks.

## 3. Installation, authentication and recovery

The manager verifies a detached OpenSSH SSHSIG signature on the exact index
bytes before parsing it. The dedicated Ed25519 public key is compiled into
`tools/fprmeta/trust.fpr` and also recorded in `tools/fprmeta/release.pub`:

```text
SHA256:pb+sg4pBrNy8hcRzKWsXW+hvIko4BOXgXbBBtqQCUj4
```

Verification uses macOS `/usr/bin/ssh-keygen`, namespace `fprmeta-index`, signer
identity `fpr-release`. See the [OpenSSH signature verification contract](https://man.openbsd.org/ssh-keygen#verify).
The manager links only macOS's `libarchive` and `libSystem`, with no Homebrew
crypto dependency. This replaces the proposal's minisign/signify suggestion.
The private key is stored outside Git with owner-only permissions; only its
public counterpart belongs in source or release artifacts.

A separately supplied `--trusted-key FILE` (or `FPRMETA_TRUSTED_KEY` /
`QOSMETA_TRUSTED_KEY`) selects a different Ed25519 public key. A key is never
fetched from the index's location. `--allow-unsigned-index` explicitly opts
into unauthenticated indexes, useful for independently trusted local fixtures.
If an explicit trust key is supplied, verification is still mandatory even
when that flag is present. Offline `--archive` installation still requires
`--sha256` or a neighboring `SHA256SUMS`; those hashes alone do not authenticate
who published an archive. Index signatures establish authenticity, not index
freshness or protection against replay of an older valid list.

Additional refusal checks:

- Index format and component, applicable entry fields, duplicate versions,
  checksum syntax, HTTPS/file URLs, boolean `yanked`, and declared archive size.
- Payload format, component layout, release versus requested index version,
  host architecture/OS, minimum OS versus both host and index, and inventory.
- Declared requirements: known Homebrew runtime dependencies must be present;
  absent Command Line Tools produce a native-build prerequisite message but
  do not prevent installing a toolchain to run Sol. Unknown requirements fail.
- Archive path traversal, absolute paths, hardlinks, special files, duplicate
  files, symlink parents, and links escaping the extraction tree. Extraction
  is bounded to 10,000 entries, 256 MiB compressed, 512 MiB per file and 2 GiB
  expanded. Inventories cover regular files; safe symlinks are bound by the
  authenticated archive hash and extraction checks.

Old format-1 indexes may omit `size`, `minimumOS` and `requires`; if present,
these fields are enforced. Release payloads must declare host and minimum OS.
Requirements are checked for index installs; offline archive users supply
runtime prerequisites independently, since older payloads do not carry the
same structured requirement vocabulary.

Installers use a persistent `flock` file. The kernel releases the lock on
process exit, including a crash; do not remove its inode to unlock it. An old
`lock/` directory is still refused, so migration cannot steal an old manager's
active lock. Downloads and archive snapshots use separate private temporary
directories, and checksums are checked on the snapshot actually extracted.

The receipt is written inside the staged version before the single rename
that publishes it. Settings are replaced atomically. If the process stops
between publication and updating the legacy receipt/default, the version is
still visible. `repair` rechecks payload metadata and inventory and recreates
legacy receipts; it can also adopt an older interrupted local installation
that passes those checks. It does not invent an archive hash for that older
installation, authenticate arbitrary local directories, or change an existing
default. Choose a missing default with `default VERSION`. Interrupted private
staging directories may remain on disk; they are never launcher candidates.

### Release the candidate

1. Back up the dedicated signing key securely. Do not add it to Git or a
   release archive. Do not use the public RFC test-vector key in production.
2. Publish the signed index pairs from `docs/release-indexes/` to the tap's
   `toolchains/` directory, preserving their exact bytes and `.json.sig` names.
   Subsequent edits must be signed again using `tools/sign-release-index.sh`.
3. Release and qualify the new manager and update both Homebrew formulas.
   Ship the signed indexes before the strict manager so default installation
   works immediately. The old manager ignores the added signatures.
4. Release the compiler and SDK changes for their direct pin checks as well.

The initial local qualification did not replace any public index, formula or
installed manager. The subsequent release above published the signed indexes,
updated both formulas and upgraded the managers without replacing existing
user toolchains.

## 4. Exact version selection is not a hermetic build

An exact pin fixes the selected release. The index hash fixes the downloaded
archive, and QOS checks its private compiler and platform inputs. This keeps
upgrades from silently switching those inputs. It does **not** by itself fix:

- The host Clang, assembler/linker, system libraries and Apple platform SDK.
- Target, optimization and environment overrides, foreign inputs or dependency
  contents outside the pinned archive.
- Source, output, cache and toolchain install paths, timestamps, linker UUIDs,
  signing behavior or other host-dependent build inputs.

The upgrade acceptance checks byte-identical output with the same source,
compiler archive, paths, options and host tools before and after installing a
second version. That is an upgrade-isolation check under a fixed environment,
not a claim of cross-machine or cross-location reproducibility. QOS still has
the recorded compiler-unit-order dependence on the SDK's install location;
rebuilding `ld.lld` can also record different build paths.

A hermetic/reproducible-build effort needs pinned host tools/sysroots, recorded
build settings and dependencies, normalized paths/metadata, and comparisons
across fresh locations and machines. That remains separate roadmap work.

## Validation

- `make fprmeta` and `python3 tools/fprmeta-contract-check.py`: native pin,
  signature, metadata, archive, lock, receipt recovery and packaged compiler
  identity regressions in disposable manager homes.
- `make unit-tests UNIT=ProjectWorkflow`: compiler project contract tests.
- QOS `tools/qos-pin-check.fpr` built with `tools/qos/host.c`, then
  `QOS_PIN_TEST_BINARY=... python3 tools/portable-sdk-test.py`: native/reference
  version parity and SDK project contracts.
- `tools/fprmeta-check.py` with the published FP-RISC 0.12.0 and 0.13.0 archives
  and QOS SDK 0.3.0: installed native builds, exact-pin upgrade isolation,
  cross-minor compatible-pin isolation, Sol shebangs, refusals and uninstall
  preservation, with source checkouts, GHC/Cabal and real manager homes denied.

Result: all checks passed: 12 native manager test groups, `ProjectWorkflow`,
19 QOS project test groups with 20 native/reference version cases, and 34
installed-workflow steps. The signed production-index candidates verified
with the embedded key under the source-denied sandbox. See the
[check summary](evidence/2026-11-02-packaging-contract-checks.json) and
[installed-workflow evidence](evidence/2026-11-02-packaging-manager-acceptance.json).

## Editor selection API

Manager 0.2.0 adds `fprmeta which fpr --json` and
`qosmeta which qos --json`. Format 1 reports the selected release, selection
source/pin, command path, compiler path, module home/search roots, foreign
declarations, default check flags and metadata path. This is read-only and
never installs a missing version. Consumers must query from the project
directory and must not infer a compiler home by resolving the launcher's
symlink. Existing human-readable `which` output is unchanged.

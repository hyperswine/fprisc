# Sol build migration in FP-RISC and QOS

Implementation checkpoint for the local FP-RISC and QOS trees on 13 November 2026. The base revisions are FP-RISC `297622e65ebc` and QOS `d1f98b71f851`. The changes described here are local to those trees.

Both projects use Sol for new build scripts. Scripts must run with the Sol executable shipped in FP-RISC 0.13.1. A compatible newer executable is fine for daily use. The packaged 0.13.1 executable identifies itself as `Sol 0.14.0-dev (scripting API 1)`. Test compatibility by running that executable. Some existing shell and Python commands remain as launchers while their callers migrate.

## What moved

The committed base revisions are available as source releases under the same tag, `pre-sol-build-removal-2026-11-13`. Each release preserves the scripts as they were before the local migration. [FP-RISC rollback release](https://github.com/hyperswine/fprisc/releases/tag/pre-sol-build-removal-2026-11-13) · [QOS rollback release](https://github.com/hyperswine/qos/releases/tag/pre-sol-build-removal-2026-11-13)

| Path | Build logic now in Sol |
| --- | --- |
| FP-RISC toolchain | Stage the compiler and its libraries, check native linkage, collect license notices, and package the SDK and Homebrew formula. QOS release instructions use the same compiler-license collector. [Staging](../tools/stage-toolchain.sol) · [Packaging](../tools/package-toolchain.sol) · [Licenses](../tools/compiler-licenses.sol) |
| FP-RISC targets | Compile and link builtin images, check target RAM limits, and build the Virt CLINT, Tang Nano, ESP-IDF and AWS POS1 targets. Tang presets, ISA checks and build manifests now run in Sol. [Image admission](../tools/target-image.sol) · [Tang build](../machine/tangnano20k/build.sol) |
| FP-RISC developer tools | Build and install Sol bundles, package compiler metadata, generate printer-alert catalogs, and build benchmark peers. Static-arena contract verification and linking, as well as the compilation steps in Pi runtime qualification, also moved. [Static-arena linker](../tools/static-arena-link.sol) · [Pi qualification build](../tools/pi-qualification-build.sol) |
| QOS apps and images | Build models, the Virt HAL and process apps. Generate app manifests, ELF import and export tables, relocatable QA packages, and disk images. Existing callers can use their old entry points. See `tools/build-process-app.sol`, `tools/qa-pack.sol` and `tools/mkdisk.sol` in QOS. |
| QOS SDK and boards | Build the SDK linker and Pi compiler SDK. Drive Buildroot and run the Raspberry Pi 4 and STAR64 post-build hooks. Cached Buildroot configurations can still invoke the old hook names. See `tools/pi4/compiler-sdk.sol` and `tools/buildroot/br.sol` in QOS. |

## Comparisons completed

| Build path | Evidence from the local run |
| --- | --- |
| macOS arm64 SDK | All 197 staged file hashes matched the Python reference. The compiler and ten bundled libraries passed signature checks. The staged and archived installs each passed 51 qualification steps with the source checkout inaccessible. |
| Release archive | A clean fixture with matching freeze and plan produced the same 297 archive entries, modes and contents, comparing JSON as data. Each archive passed its own checksum. The compressed archive bytes differed. The license collector matched all 36 license files and the manifest for 35 packages. |
| Target RAM and static arenas | Sol and Python agreed on 18 accepted images and 28 refusals. The existing target-image check exercised four real builds, including both Virt ARC modes and the two Tang RAM layouts. The static-arena and static-sequence checks passed with execution required, including preservation of earlier output after a rejected build. |
| Tang Nano 20K | The public build command with the `fprisc-48` preset reproduced the previous RV32 firmware binary byte for byte. All build-manifest fields matched on the same paths and inputs. The RV64 ISA checker also ran on a linked image. |
| Buildroot post-build hooks | The Pi splash and STAR64 console checks passed. Running the hooks twice on fixture root filesystems produced matching installed content. STAR64 now preserves the existing permissions on `/etc/inittab`, including when they are more restrictive than the default. |
| Printer alerts | Regeneration reproduced exact categories for 4,477 codes across seven catalogs and omitted the same 186 ambiguous codes. Only the generator-name comment changed in the generated FP-RISC source. |

## Core migration completed

The remaining core build paths now run in Sol:

- `tools/build-static-arena.sol` owns scalar callers, typed finite sequences,
  linked placement, stack admission, optional callback instruction proofs and
  publication. The RV64 IMC decoder and linked-byte abstract interpreter live in
  `riscv-compressed.sol` and `linked-rv64.sol`. `linked-stack.sol` also replaces
  Python in the Makefile's optional `BUILTIN_STACK_ENTRIES` gate. Physical and
  contract checks have library modules shared with their CLI entry points.
- `tools/build-pi-runtime-qualification.sol` reads checked-in FP-RISC fixtures
  and plans under `tools/pi-fixtures/`; it no longer imports Python test modules.
  It sanitizes compiler controls, records the selected plan and builder hashes,
  and calls the existing Sol compiler/case/scheduler modules.
- QOS's `qbuild` and `tools/main-profile.sol` own contributor builds, app/plugin
  bundles and Main profile generation. Bundles carry a native launcher. Its
  installed SDK stager and packager remain Sol, with a native installed `qos`.
- `fpr build --target=qos-portable` no longer implicitly launches Python. Native
  builders and explicit executable or Sol overrides propagate their exit codes.
- The Pi compiler SDK defaults to a Python-free compiler/plugin bundle.
  Its optional legacy editor daemon requires an explicit target Python runtime,
  copied without executing it during packaging.

Retired FP-RISC coordinators are independent test oracles under
`tests/build-reference/`, with no production build callers. The compiler and C
build mechanisms still use Make and POSIX `/bin/sh`; this migration removes
Python and Bash from the core orchestration, not upstream vendor toolchains.

### Validation

`tests/check_sol_core_build.py` compares all seven Pi plans with the retired
coordinator: the full plan has 98 language builds; focused slices have 18, 14,
12, 18, 12 and 8 respectively. Scheduler jobs are expanded separately by Sol.
It compares all 38,550 supported RV64 compressed encodings with the independent
Python decoder, normalized ELF bytes, placement, linked stack/work receipts,
QEMU results, typed previous-result handoffs and preservation after refusals.
The four compressed/uncompressed and relaxed/unrelaxed linked fixtures also
match stack/work bounds and refuse dynamic stack changes, unresolved jumps,
retaining cycles, damaged return links and writes outside the proved frame.
GCC's random temporary object names are normalized only in the ELF string table.
Receipts themselves retain the exact image hash.

A scalar Bool callback requires exactly 20 instructions in both implementations.
Compact QOS process ABI values 24/6/5 and legacy values 23/6/4 match the target
headers under the same layout. The rebuilt compiler's SDK dispatch preserves
paths containing spaces and distinct native/Sol exit codes, and refuses a missing
native builder even when a legacy Python builder is present.

The QOS guide is `qos/docs/2026-11-13-CORE-SOL-BUILDS.md` in the sibling checkout.
Core contributor bundles have been built with Python and Bash blocked on PATH
and launched successfully. QOS installed SDK acceptance passed with both source
checkouts inaccessible; installed desktop and standalone process builds also
passed with Python and Bash blocked on PATH. The existing static-arena regression
and four target-image builds passed, including failed-publication preservation.
Release-package and clean-checkout verification are recorded in the sibling
QOS core build guide. The release-plan audit also added the already-used
GHC Haskeline 0.8.2.1 and terminfo 0.4.1.6 packages to `cabal.project.freeze`;
all dependency versions and flags now match the verified compiler plan.

### Qualification boundaries

The full compiler/QOS test corpora still use Python and Bash, including the
QOS sweep's leg bodies. The migration does not claim their removal. Physical
Pi/STAR64 qualification, upstream Buildroot images, native Linux Pi SDK
installation and ESP-IDF vendor dependencies need separate validation. Existing
release packaging guards for clean inputs, matching revisions, inventories,
licenses and native linkage are preserved.

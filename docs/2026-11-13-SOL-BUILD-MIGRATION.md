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

## Where to resume

The QOS Python entry points `ccobj.py`, `mkimports.py`, `mkexports.py` and `native-abis.py` have been removed locally. Their replacements matched the cached C fixture object, assembly for 83 imports in three output modes and 983 exports, and ABI values for both cell layouts. The assembly comparisons allowed the generated filename comment to change. The Pi post-build hook also ran through its legacy filename using the packaged Sol executable on `PATH`.

The QOS disk builder's Python entry point was also removed. Given the same two QA archives, the Sol builder produced a byte-identical 4 MiB disk. In a separate run, `tools/build-checkout-app.sol` compiled `tests/appa.fpr` and `tests/appb.fpr` through the real Make target and seeded the resulting archives in that order. The output image has not been booted.

QOS has since removed the Python mesh converter. Its Sol replacement reproduced the module bodies for all 11 checked-in STL inputs. Clean-checkout comparisons also covered ASCII, a binary file with a solid-prefixed header, negative scale and floor alignment.

FP-RISC now reads fresh per-export heap proofs in Sol, and admission receipts identify the checker by SHA-256. A fresh paired checkout admitted a 416-byte heap requirement against a 512-byte reserve and executed the image under RV64 QEMU, returning 42. QOS read native ABI values 24, 6 and 5 from the same FP-RISC checkout. The run used a previously built compiler binary.

The Pi builder now expands scheduler sources and the eight optimization-control configurations in Sol. The full generated plan matched its predecessor for 98 build entries and 99 case specifications, as did all six focused plans, excluding the changed builder's own hash. These comparisons cover fixture generation; physical Pi qualification remains outstanding.

1. Finish the FP-RISC static-arena driver. [The existing entry point](../tools/build_static_arena.py) still generates the caller, computes placement and coordinates publication. It also invokes the optional linked-stack and callback proofs. Keep the last admitted image intact when any of those steps refuses a replacement.
2. Move Pi qualification fixture generation and case selection out of [the Python coordinator](../tools/build_pi_runtime_qualification.py). Compare a focused bundle's case list, expected values and produced binaries before retiring the old path.
3. Finish QOS checkout app build orchestration in `qos.py`. The installed Portable SDK uses the native `qos` command. Its parity check stages `tools/portable_sdk.py` separately as a comparison builder. Exercise process and plugin builds through the contributor CLI and the installed SDK, then remove Python build paths whose callers have moved. Inventory script references in CI, Make recipes and packaging before deleting the remaining launchers.
   [The compiler driver](../compiler/Build.hs) now forwards `fpr build --target=qos-portable` to the native `tools/qos` beside its SDK metadata. Older SDKs retain the Python fallback. An explicit `QOS_PORTABLE_BUILDER` ending in `.sol` runs with the same compiler; other overrides preserve the old Python invocation. The rebuilt compiler selected the native SDK builder and forwarded a project path containing a space, the compiler path and a verbose flag. Temporary SDK fixtures also exercised the Python fallback and an explicit Sol override. The compiler propagated their distinct exit codes (19, 23 and 21) and returned 2 when no builder existed.
   The native process linker and ABI probe now share `cellLayoutFlag` in QOS `tools/native-abi.sol`. Build the same process with the default compact layout and with `FPR_COMPACT_CELLS=0`. For each build, compare the packaged native, actors and memory ABI values with those from the target headers under that layout. This comparison is pending.
4. Verify both repositories together from clean checkouts. QOS still pins FP-RISC `94efae2b7e3a`. Check which QOS commands require newly added FP-RISC scripts and coordinate the pin with the FP-RISC change. Run the full suites and the Linux SDK install check, build the Buildroot images and verify board boots separately. Those runs are deferred.

# Build toolchain on this machine

Captured 2026-09-04 on Apple Silicon. This is an inventory of the tools
currently selected by `PATH` and the project Makefiles; it is not a statement
of minimum supported versions.

## Host

| Item | Version |
| --- | --- |
| macOS | 26.6.2 (build 25G83), arm64 |
| macOS SDK | 26.5 |
| Clang target | `arm64-apple-darwin25.6.0` |

The active SDK is
`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`.

## Build tools

| Role | Tool selected on this machine | Version | Path |
| --- | --- | --- | --- |
| Top-level build driver | Python | 3.14.7 | `/opt/homebrew/bin/python3` |
| Build graph | GNU Make | 3.81 | `/usr/bin/make` |
| FP-RISC package build | cabal-install / Cabal library | 3.16.1.0 / 3.16.1.0 | `/Users/jasonqin/.ghcup/bin/cabal` |
| FP-RISC Haskell compiler | GHC | 9.8.2 | `/Users/jasonqin/.ghcup/bin/ghc` |
| QOS Portable C compiler (`gcc`) | Apple Clang | 21.0.0 (`clang-2100.1.1.101`) | `/usr/bin/gcc` |
| AArch64 `.qa` C compiler | Apple Clang | 21.0.0 (`clang-2100.1.1.101`) | `/usr/bin/clang` |
| Native Mach-O linker | Apple `ld` | project `ld-1267` | `/usr/bin/ld` |
| AArch64 ELF linker | Homebrew LLD | 23.1.0 | `/opt/homebrew/bin/ld.lld` |
| Desktop GL metadata | pkgconf (`pkg-config`) | 3.0.6 | `/opt/homebrew/bin/pkg-config` |
| Desktop GL library | GLFW | 3.5.1 | reported by `pkg-config glfw3` |
| RISC-V C cross-compiler | `riscv64-unknown-elf-gcc` | 14.2.0 (`g04696df09`) | `/opt/homebrew/bin/riscv64-unknown-elf-gcc` |
| RISC-V system emulator | QEMU | 11.1.1 | `/opt/homebrew/bin/qemu-system-riscv64` |
| Test timeout helper | GNU coreutils `timeout` | 9.11 | `/opt/homebrew/bin/timeout` |

`gcc` on this macOS installation is Apple's Clang driver, not GNU GCC.
FP-RISC itself is package version 0.12.0. Its normal `make fpr` route uses
Cabal because `cabal` is installed; Cabal invokes GHC and compiles the three C
FFI shims declared in `fp-risc.cabal`.

## Build routes

- `./qos.py build` uses Python and Make to build `fpr`, `qosp`, and the native
  QOS image.
- `make -C fp-risc fpr` uses Cabal and GHC for the FP-RISC compiler and Sol VM.
- `make -C qos portable` invokes `gcc`, which resolves to Apple Clang, for
  `qosp`.
- `make -C fp-risc qos-app-macos` invokes Apple Clang with
  `--target=aarch64-none-elf -fuse-ld=lld` for an AArch64 ELF `.qa` image.
- QOS Native and FP-RISC bare-metal builds use the RISC-V GCC cross-compiler;
  their run targets use `qemu-system-riscv64`.
- The native Sol JIT is hand-assembled for A64 on this host. LLVM is not part
  of the FP-RISC build or runtime linkage.

## Optional tools not installed

The cross-ISA HandJIT check in `check-all.sh` skips on this machine because
`aarch64-linux-gnu-gcc` and `qemu-aarch64` are not installed. These are not
needed for native Apple Silicon builds or for QOS Native's RISC-V QEMU path.

## Refreshing the snapshot

Use each tool's version command (`python3 --version`, `make --version`,
`cabal --version`, `ghc --version`, `clang --version`, `ld.lld --version`,
`riscv64-unknown-elf-gcc --version`, and `qemu-system-riscv64 --version`) plus
`sw_vers`, `xcrun --show-sdk-version`, and `pkg-config --modversion glfw3`.

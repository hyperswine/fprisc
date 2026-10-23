# FP-RISC

The FP-RISC language implementation: compiler, Sol interpreter, language libraries,
checks, and standalone bare-metal runtime. QOS lives in the sibling `qos` repository.

```sh
make fpr
./fpr sol sol/examples/tabling.sol
make stdcheck
make bare-metal PROG=tests/fmath.fpr
```

Native AOT compilation uses verified typed IR and direct RV32/RV64, AArch64 and x64
selectors. The RISC-V text generator and translators are retired in the current
migration candidate. See the [retirement acceptance record](docs/2026-10-23-TYPED-GENERATOR-RETIREMENT.md)
for validation scope and runtime ABI changes.

The compiler needs GHC and the dependencies declared in `fp-risc.cabal` (normally
resolved with Cabal), plus pkg-config, libgit2 >= 1.9 and libarchive >= 3.6 for
native hosted automation. On macOS install `pkg-config libgit2 libarchive` with
Homebrew; on Linux install their development packages. Bare-metal builds
additionally need the RISC-V cross compiler;
`make bare-metal-run` needs QEMU. Neither building the compiler nor running Sol or
building bare-metal examples requires QOS.

`make fpr` builds the compiler at -O1 with a 64 MiB GHC nursery: the binary
deploys ship, the suites run and `fpr build` spawns; it compiles a program
about twice as fast as the -O0 build, and its own rebuilds cost the same.
`make fpr-dev` is the -O0 build at the same `./fpr` (own build dir, so the two
stay incremental); `make fpr-opt` is the -O2 experiment at `build/fpr-opt`.
See [docs/2026-10-19-COMPILER-DEFAULTS.md](docs/2026-10-19-COMPILER-DEFAULTS.md).

- `compiler/`: shared frontend, native backends, Sol bytecode interpreter and JIT.
- `core/`, `std/`: language prelude and libraries that do not import QOS services.
- `runtime/`: the RUNTIME -- allocation, actors and the scheduler, vectors, values.
- `machine/virt/`, `machine/posix/`, `machine/builtin/`, `machine/unix/`: the MACHINE LAYER, one
  per system -- what the runtime needs from whatever it runs on (boot, context
  switch, a console byte, the doorbell and timer). Device drivers are not
  here: the HAL a program sees is QOS's. See [docs/2026-09-19-HAL.md](docs/2026-09-19-HAL.md).
- `sol/`, `tests/`, `tools/`: examples, compiler/runtime checks and language tools.
- `docs/`: language and platform design documentation, one dated page per
  topic in the order it was written; `docs/README.md` is the index.

QOS-specific `std` modules, operating-system tests, programs, application manifests,
loaders, packaging and Unix devices are maintained by QOS. The compiler still
understands QOS targets, and `runtime.c` still has an optional `FPR_QOSAPP` ABI adapter.
This split changes source ownership, not language semantics or the profile model.
Actor/Vector placement and the future Builtin/Base/ExtBase contracts remain design
work; the current runtime is not being presented as a completed minimal Builtin.

## Profiles and systems

A file declares what it is written against -- `profile builtin.`,
`profile base.` (the default), `profile extbase.`, `profile sol.`, or
`unsafe base.` to mark it blanket-unsafe at the same time -- and the compiler
is told where it runs: `--system=bare-metal | qos-native | qos-portable |
posix`.  See [docs/2026-09-19-PROFILES.md](docs/2026-09-19-PROFILES.md) for the matrix.

## The Base profile: programs for this machine

```sh
./fpr build tests/base/hello.fpr -o hello && ./hello
./fpr run tests/base/args.fpr one two
```

`fpr build` makes an ordinary executable for the host (x86-64 or AArch64
on Linux/macOS, or RV64GC/LP64D on Linux): the same core runtime as bare metal, with libc as the board
(`machine/posix`).  A program gets the command line, the environment, stdin,
stdout, stderr, files, the clock and the exit status -- see
[docs/2026-09-18-BASE.md](docs/2026-09-18-BASE.md).  `tests/check_base.py` is the conformance run.

Cross-build Linux RISC-V programs with `fpr build prog.fpr
--target=linux-riscv64 --cc riscv64-linux-gnu-gcc`. Shared modules use the
same command with `--module`. See [Linux RV64 support](docs/2026-10-14-LINUX-RV64.md)
for the ABI, QOS images and hardware checks.

On any Mac, `fpr build prog.fpr --target=macos-x86_64` builds an x86-64
Mach-O executable or module with the system clang; Apple Silicon runs it
under Rosetta. See [macOS x86-64](docs/2026-10-24-X64-MACOS.md).

The same system runs on an ESP32-P4: `fpr run prog.fpr --host=esp-idf`
builds the program as an ESP-IDF application, flashes it, and is its console,
with the same files, sockets, poller and std modules, and `std/wifi`,
`std/ble` and `std/gpio` for what the board has beyond POSIX
([machine/esp-idf/README.md](machine/esp-idf/README.md)).
`tests/check_esp_board.py` is the conformance run on an attached board.

## Working with QOS

Set `FPRISC_ROOT` to this checkout when working in QOS, for example:

```sh
export FPRISC_ROOT=/Users/jasonqin/Documents/GitHub/fprisc
cd /Users/jasonqin/Documents/GitHub/qos
./qos.py build
```

QOS invokes the compiler and compiles runtime sources directly from that path.
There are no cross-repository source links or setup-generated overlays.
`FPR_HOME` selects the primary module home; `FPR_PATH` adds module roots separated
by the platform path separator (`:` on Unix). Importer-relative resolution takes
priority, then the home, then the extra roots in order. QOS sets these automatically.
Standalone FP-RISC still needs neither variable.

Both repositories retain the original monorepo history and tags; the split is a new
working-tree change on `main`. Old tags describe the old combined layout. No Git
remote is configured for this new repository. `SPLIT-SOURCE.json` records the source
commit. See `../qos/docs/2026-09-18-REPOSITORY-SPLIT.md` for ownership and release migration.

For the unsafe, scheduler-free RV64 build and memory/bit API, see
[BareMetal–Builtin](docs/2026-09-18-BAREMETAL-BUILTIN.md). Start with
`make bare-metal-builtin-run PROG=tests/builtin.fpr`.

Experimental automatic ARC for first-order Builtin programs is available with
`make bare-metal-builtin-run ARC=1 ARC_CHECK=1 PROG=tests/builtin_arc.fpr`.
See the [ownership and feature limits](docs/2026-09-18-BAREMETAL-BUILTIN.md#automatic-arc-first-order-milestone).

The [machine primitive API](docs/2026-09-18-MACHINE-PRIMITIVES.md) adds assembly-backed bit/memory
operations, CSR access, interrupt masking, atomics and fences. Try
`make bare-metal-builtin-run ARC=1 ARC_CHECK=1 PROG=tests/builtin_machine.fpr`.

For a chronological account of the QOS review, repository split, profile design
and BareMetal implementation, see the [project progress summary](docs/2026-09-18-PROJECT-PROGRESS-SUMMARY.md).

## Local printer dashboard

`examples/printers.fpr` is a small read-only `std/live` dashboard, with
expandable printer cards, live telemetry/freshness, measured report and refresh
rates, and cameras that connect only on demand. It uses a narrow Python LAN
transport for Bambu MQTT/TLS and camera framing; an opt-in native TLS/MQTT
collector owns authenticated telemetry, and an opt-in native camera service
owns shared JPEG framing and MJPEG streaming. The UI and per-session state are
FP-RISC. Try it without any printer or credentials:

```sh
./fpr build examples/printers.fpr -o build/printers
python3 tools/printer_dashboard.py --demo
```

See [setup and checks](examples/printer-dashboard/README.md) for local-printer
configuration and the current validation boundary.

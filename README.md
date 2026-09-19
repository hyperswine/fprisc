# FP-RISC

The FP-RISC language implementation: compiler, Sol interpreter, language libraries,
checks, and standalone bare-metal runtime. QOS lives in the sibling `qos` repository.

```sh
make fpr
./fpr sol sol/examples/tabling.sol
make stdcheck
make bare-metal PROG=tests/fmath.fpr
```

The compiler needs GHC and the dependencies declared in `fp-risc.cabal` (normally
resolved with Cabal). Bare-metal builds additionally need the RISC-V cross compiler;
`make bare-metal-run` needs QEMU. Neither building the compiler nor running Sol or
building bare-metal examples requires QOS.

- `compiler/`: shared frontend, native backends, Sol bytecode interpreter and JIT.
- `core/`, `std/`: language prelude and libraries that do not import QOS services.
- `hal/core/`: the RUNTIME -- allocation, actors and the scheduler, vectors, values.
- `hal/virt/`, `hal/posix/`, `hal/builtin/`, `hal/unix/`: the MACHINE LAYER, one
  per system -- what the runtime needs from whatever it runs on (boot, context
  switch, a console byte, the doorbell and timer). Device drivers are not
  here: the HAL a program sees is QOS's. See [docs/HAL.md](docs/HAL.md).
- `sol/`, `tests/`, `tools/`: examples, compiler/runtime checks and language tools.
- `docs/`: language and platform design documentation.

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
posix`.  See [docs/PROFILES.md](docs/PROFILES.md) for the matrix.

## The Base profile: programs for this machine

```sh
./fpr build tests/base/hello.fpr -o hello && ./hello
./fpr run tests/base/args.fpr one two
```

`fpr build` makes an ordinary executable for the host (x86-64 or AArch64,
Linux or macOS): the same core runtime as bare metal, with libc as the board
(`hal/posix`).  A program gets the command line, the environment, stdin,
stdout, stderr, files, the clock and the exit status -- see
[docs/BASE.md](docs/BASE.md).  `tests/check_base.py` is the conformance run.

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
commit. See `../qos/docs/REPOSITORY-SPLIT.md` for ownership and release migration.

For the unsafe, scheduler-free RV64 build and memory/bit API, see
[BareMetal–Builtin](docs/BAREMETAL-BUILTIN.md). Start with
`make bare-metal-builtin-run PROG=tests/builtin.fpr`.

Experimental automatic ARC for first-order Builtin programs is available with
`make bare-metal-builtin-run ARC=1 ARC_CHECK=1 PROG=tests/builtin_arc.fpr`.
See the [ownership and feature limits](docs/BAREMETAL-BUILTIN.md#automatic-arc-first-order-milestone).

The [machine primitive API](docs/MACHINE-PRIMITIVES.md) adds assembly-backed bit/memory
operations, CSR access, interrupt masking, atomics and fences. Try
`make bare-metal-builtin-run ARC=1 ARC_CHECK=1 PROG=tests/builtin_machine.fpr`.

For a chronological account of the QOS review, repository split, profile design
and BareMetal implementation, see the [project progress summary](docs/PROJECT-PROGRESS-SUMMARY.md).

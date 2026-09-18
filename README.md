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
- `hal/core/`: runtime allocation, application, actors, vectors and value operations.
- `hal/virt/`: standalone RISC-V machine support, also consumed by QOS Native.
- `hal/unix/`: architecture context switching used by hosted runtime integrations.
- `sol/`, `tests/`, `tools/`: examples, compiler/runtime checks and language tools.
- `docs/`: language and platform design documentation.

QOS-specific `std` modules, operating-system tests, programs, application manifests,
loaders, packaging and Unix devices are maintained by QOS. The compiler still
understands QOS targets, and `runtime.c` still has an optional `FPR_QOSAPP` ABI adapter.
This split changes source ownership, not language semantics or the profile model.
Actor/Vector placement and the future Builtin/Base/ExtBase contracts remain design
work; the current runtime is not being presented as a completed minimal Builtin.

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

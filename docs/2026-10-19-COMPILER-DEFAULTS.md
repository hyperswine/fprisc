# The compiler's defaults: -O1 and a 64 MiB nursery

Date: 2026-10-19. Kind: decision record with its measurements.
Base: FP-RISC `3206b84` (code generation revision 51), GHC 9.8.2,
cabal-install 3.16.1.0, Apple M4 (10 cores, 16 GiB), macOS. Branch
`compiler-defaults`.

## The question

2026-10-18-COMPILER-BUILD-OPT.md measured that the compiler built at -O1
with a 64 MiB GHC nursery (`-A64m`) compiles a warm logbook in 6.8 s
against 14.6 s for the -O0 compiler with GHC's 4 MiB default, and that
the assembly is byte-identical. It left two things undone: the nursery
was not made the compiler's default because the processes that start the
compiler as a subprocess (the live runner, QOS's Editor) had not been
checked against the extra 64 MiB; and nothing used the optimised binary,
which the knob wrote beside the checkout as `build/fpr-opt`. This page
makes both the default where it is safe, and says where it is not.

## Who starts the compiler, and under what budget

Every spawn of the compiler, found by reading the callers:

| caller | the binary | where the compiler runs | memory bound on it |
|---|---|---|---|
| `fpr build`, `fpr run` (compiler/Build.hs `build`: `createProcess (proc self ["compile", ...])`) | the running `fpr` itself | the build machine | none |
| `fpr publish`, `fpr watch` (compiler/Publish.hs: `rawSystem exe ["commit"]`, `["build", ..., "--module"]`, `["publish", "--stored"]`) | the running `fpr` itself | the build machine | none |
| `fpr publish`'s module build and `fpr watch --module`'s app rebuild | the same, through `fpr build` | the build machine | none |
| QOS's compiler daemon `qos/tools/fprd.py` (`qos.py run --fprd`, `tools/main-profile.py --run`): `check`, `compile`, `plugin:` (through `make plugin-qa`), `publication:`, `watch:` | `$FPRISC_ROOT/fpr` | the host, as a Python subprocess | a wall-time limit (120 s or 300 s per request) and a 4 MiB source bound; no memory limit. The program the Editor then RUNS is confined to a quarter of the machine (`Sys.confine`, qos `programs/mods/editapp.fpr` `runBudget`); the compiler is outside that budget |
| `qos.py install`, Homebrew `qos-fpr` | copies `fpr` into `libexec/qos-fpr/toolchain/` | the installing machine | none |
| the Pi 4 Editor compiler SDK (qos/tools/pi4/compiler-sdk.md, compiler-sdk-run.py) | `fpr-editor`, built by its own `ghc -O0 -threaded -rtsopts -with-rtsopts=-V0.001 ... -main-is PiEditorCompiler` line, not by fp-risc.cabal or the Makefile | the Pi, from a 192 MiB tmpfs with a 128 MiB tmpfs for its work | `GHCRTS="-M512m -K64m"`: a 512 MiB cap on the GHC heap and 64 MiB on the Haskell stack |
| the arm64 Linux and FreeBSD guests (`make fpr` and `fpr build` inside a 2 GiB VM) | their own `make fpr` | the guest | the guest's 2 GiB |
| bare-metal, QEMU, ESP-IDF and `--target` cross builds | `fpr` | the host | none |

So the only process with a memory budget on the compiler is the Pi SDK,
and it builds the compiler with its own flags: a change to fp-risc.cabal
and the Makefile does not reach it until its ghc line is changed. The
question for it is whether `-A64m` fits under `-M512m`, measured below.

## Peak memory, with and without the nursery

`fpr compile --system=posix` of examples/logbook.fpr (114k lines of A64
assembly) and examples/pos1.fpr (196k), each configuration in a fresh
directory: cold is an empty unit cache (the prelude and every std module
compiled), warm is the same command again. Peak RSS is `/usr/bin/time -l`'s
maximum resident set size; residency, MUT and GC are the compiler's own
(`GHCRTS=-s`). The -O0 compiler is `make fpr` at `3206b84`; the -O1 one is
`make fpr-opt GHCOPT=-O1` of the same sources. The -O0 runs were taken at
load 3 to 4; the -O1 runs at load 11 (another session's sweep), so only
their memory columns are comparable with the -O0 rows, not their times.

| compiler | RTS | program | cache | peak RSS | max residency | MUT | GC | allocated |
|---|---|---|---|---|---|---|---|---|
| -O0 | default | logbook | cold | 460 MiB | 160 MB | 18.6 s | 6.5 s | 94.2 GB |
| -O0 | -A64m | logbook | cold | 472 MiB | 139 MB | 21.0 s | 3.9 s | 94.1 GB |
| -O0 | default | logbook | warm | 299 MiB | 108 MB | 9.7 s | 3.1 s | 50.9 GB |
| -O0 | -A64m | logbook | warm | 343 MiB | 108 MB | 10.0 s | 1.6 s | 50.9 GB |
| -O0 | default | pos1 | cold | 684 MiB | 245 MB | 26.9 s | 9.4 s | 128.6 GB |
| -O0 | -A64m | pos1 | cold | 606 MiB | 223 MB | 29.7 s | 5.5 s | 128.5 GB |
| -O0 | default | pos1 | warm | 427 MiB | 152 MB | 16.5 s | 5.2 s | 74.8 GB |
| -O0 | -A64m | pos1 | warm | 479 MiB | 155 MB | 15.3 s | 2.6 s | 74.8 GB |
| -O1 | default | logbook | cold | 446 MiB | 159 MB | 19.6 s | 7.6 s | 47.6 GB |
| -O1 | -A64m | logbook | cold | 430 MiB | 141 MB | 20.1 s | 4.0 s | 47.6 GB |
| -O1 | default | logbook | warm | 278 MiB | 106 MB | 8.7 s | 3.3 s | 21.6 GB |
| -O1 | -A64m | logbook | warm | 303 MiB | 95 MB | 8.0 s | 1.5 s | 21.6 GB |
| -O1 | default | pos1 | cold | 568 MiB | 223 MB | 26.0 s | 9.9 s | 64.6 GB |
| -O1 | -A64m | pos1 | cold | 597 MiB | 229 MB | 25.6 s | 5.5 s | 64.5 GB |
| -O1 | default | pos1 | warm | 423 MiB | 155 MB | 13.5 s | 5.0 s | 32.4 GB |
| -O1 | -A64m | pos1 | warm | 463 MiB | 166 MB | 12.8 s | 2.5 s | 32.3 GB |

The nursery adds 25 to 52 MiB to a warm compile's peak and nothing
measurable to a cold one (the cold peak is set by the old generation,
and the runs move by more than that between themselves: -O0 pos1 cold
went down by 78 MiB with the nursery). Residency does not move. GC time
halves at either build level, as the 10-18 page found.

A tiny compile (tests/base/hello.fpr) shows the floor the nursery sets:
the new compiler's peak is 112 MiB where the old one's was 73 MiB, and
it ran 16 minor collections for 1.37 GB allocated where the old one ran
611 for 2.63 GB. Any `fpr` invocation that allocates more than 64 MiB
now holds the whole nursery resident, so a long-lived `fpr watch`
supervisor or `fpr sol` session costs up to 64 MiB more of RSS than it
did; measured for `fpr watch` below.

Under the Pi SDK's cap, with the -O0 compiler the SDK builds (every run
completed; exit status 0 throughout; load 3 to 12 during these, wall
times not comparable):

| RTS | program | cache | peak RSS | max residency | MUT | GC |
|---|---|---|---|---|---|---|
| -M512m -K64m | logbook | cold | 433 MiB | 163 MB | 19.9 s | 7.1 s |
| -M512m -K64m -A64m | logbook | cold | 478 MiB | 185 MB | 23.0 s | 4.5 s |
| -M512m -K64m | logbook | warm | 282 MiB | 107 MB | 15.5 s | 4.7 s |
| -M512m -K64m -A64m | logbook | warm | 319 MiB | 108 MB | 13.7 s | 2.3 s |
| -M512m -K64m | pos1 | cold | 431 MiB | 242 MB | 52.6 s | 18.5 s |
| -M512m -K64m -A64m | pos1 | cold | 445 MiB | 240 MB | 47.9 s | 9.8 s |
| -M512m -K64m | pos1 | warm | 394 MiB | 152 MB | 22.2 s | 6.5 s |
| -M512m -K64m -A64m | pos1 | warm | 419 MiB | 155 MB | 25.7 s | 4.0 s |

`-M` makes GHC compact rather than copy as the heap nears the cap, which
is why the capped runs spend more in GC than the uncapped ones; the
nursery halves that too, and the peak stays 30 to 90 MiB under the cap on
the largest program in the tree. The Editor's own programs are far
smaller than pos1.

## The compiler's own rebuild time

The cost the -O0 default protected: the compiler rebuilt after an edit.
Both levels through cabal in their own build dirs, sequentially, the
edit a new top-level binding appended to one module (Build.hs is a leaf
imported only by Main; FPRISC.hs is imported by 22 modules), load 3.7 to
4.7 throughout:

| build | -O0 | -O1 |
|---|---|---|
| from scratch (53 modules, dependencies already in the cabal store) | 62.4 s | 60.3 s |
| Build.hs edited (1 module recompiled) | 3.7 s | 3.1 s |
| FPRISC.hs edited (35 modules recompiled) | 51.0 s | 49.5 s |
| the edits reverted (the same rebuilds again) | 3.2 s, 54.2 s | 3.3 s, 52.1 s |

There is no difference to protect. (FPRISC.hs itself is `-O2` by pragma
at both levels, which is where most of the compile time of the heavy
module already was; the rest of the compiler is small modules whose
-O1 cost is lost in GHC's front end.) The from-scratch `make fpr` with
the new defaults, timed afterwards under a load of 8 to 10, took 94 s.

## The decision

`make fpr` now builds the compiler at -O1 with
`-with-rtsopts="-V0.001 -A64m"`, and that `./fpr` is the binary deploys
ship and the suites run. Option (a), keeping `make fpr` at -O0 and
pointing deploys at `build/fpr-opt`, was rejected:

- every caller spells the compiler as `./fpr`: `qos.py install` ships
  it, fprd runs `$FPRISC_ROOT/fpr`, `qos-app.mk` and `check-all.sh` go
  through `make fpr`, `tests/check_base.py`, `tests/check_std.py` and
  `tools/bench.py` run `make fpr` then `ROOT/fpr`; (a) would have meant
  touching each of them or shipping the slow binary by default;
- `build/fpr-opt` was never a complete deploy command: compiler/Home.hs
  takes the executable's own directory as the toolchain home, so
  `build/fpr-opt` looks for the prelude and `std/` under `build/` and
  refuses (`use: no such module file ... (nor $FPR_HOME/std/live.fpr)`)
  unless `FPR_HOME` is set, contrary to what the 10-18 page said;
- the -O0 loop it would have preserved is not faster, per the table above.

What changed:

- fp-risc.cabal: `ghc-options: -O1 -rtsopts -threaded
  "-with-rtsopts=-V0.001 -A64m"`; the manual flag `optimised` is gone and
  a manual flag `dev` (default off) sets `-O0` instead.
- Makefile: `fpr` builds through cabal as before (now -O1); its
  classic-ghc fallback says `-O1` and the same rtsopts. New `fpr-dev`:
  `cabal build exe:fpr -f dev --builddir=dist-dev`, written to the same
  `./fpr`, so the two levels never clobber each other's objects and
  either rebuild stays incremental; after `make fpr-dev`, `make fpr` is
  a no-op until a source changes, so the suites then run the -O0 binary
  the developer chose (its assembly is byte-identical; 10-18 page).
  `fpr-opt` stays as the -O2 experiment (`--ghc-options=-O2`,
  `dist-opt-O2`, `build/fpr-opt`), no longer needing a flag. `clean-cabal`
  removes `dist-dev` too. The `-V0.001` tick is kept everywhere.
- README.md's build section says which build is which.
- The sweep: nothing to edit. `check-all.sh` (in qos), check_base,
  check_std and bench all reach the compiler through `make fpr`, which
  now is the deploy binary.
- The Pi SDK's ghc line in qos/tools/pi4/compiler-sdk.md and the
  `GHCRTS` in compiler-sdk-run.py are not changed here (another
  repository, and an appliance build): the table above is what adding
  `-A64m` to that `GHCRTS` would do under its cap.
- `fpr build`'s own spawn is unchanged: it runs the same binary, so the
  default reaches it; `GHCRTS` and `+RTS` still override per run.

## Verification

A live reload cycle of examples/logbook.fpr under `fpr watch`. Logbook
subscribes to no module and its `use`s are unpinned, so the single-file
form (`fpr watch logbook.fpr`, publish on save) refuses it at `fpr
commit` ("committed modules must be closed under their pin hash"). The
app form runs it: a workspace with a copy of logbook.fpr (its default
port changed so the two runs cannot collide) and examples/livereload's
math.fpr committed beside it, then

```sh
fpr watch logbook.fpr --module math --restart-on-change
```

Cycle 1 is from the start of `fpr watch` to its first `watch: app pid=`
line (publish the stored math module, `fpr build` the app, launch it);
cycle 2 is from a save of logbook.fpr (a comment appended) to the
`watch: app pid=` line after `watch: restarting app after checked root
change`. Before is the -O0 compiler without the nursery (`make fpr` at
`3206b84`); after is the new `make fpr`. Both ran at load 9 to 11, one
after the other, with the shared `~/.cache/fpr/build` unit cache in
whatever state the previous run left it:

| | before | after |
|---|---|---|
| cycle 1: start, publish, build, launch | 55.3 s | 35.3 s |
| cycle 2: save, rebuild, restart | 42.7 s | 16.6 s |
| the idle `fpr watch` supervisor's RSS at 10, 20, 30 s | 5.8, 7.3, 7.0 MiB | 5.8, 5.2, 9.0 MiB |

The supervisor's poll loop allocates too little to touch the nursery,
so the 64 MiB floor does not reach it; it is paid by each `fpr build`
and `fpr publish` it spawns, for their duration.

The warm compile itself, paired: after the suites, with the load down to
4.2 to 4.7, the old and the new binary compiled a warm logbook
alternately, three times each, in their own directories:

| run | old (-O0, 4 MiB nursery) | new (-O1, -A64m) |
|---|---|---|
| 1 | 14.5 s wall, 13.7 s user, 299 MiB | 7.3 s wall, 6.9 s user, 313 MiB |
| 2 | 14.2 s wall, 13.4 s user, 287 MiB | 6.8 s wall, 6.5 s user, 310 MiB |
| 3 | 13.7 s wall, 13.2 s user, 288 MiB | 7.1 s wall, 6.8 s user, 311 MiB |

2.0x, for 20 MiB more peak RSS: the 10-18 page's number, reproduced
with the defaults in the binary rather than in the environment.

The suites, in the `compiler-defaults` worktree against the new `./fpr`
(`make fpr` from a deleted `dist-newstyle`, 53 modules, then a no-op
for each suite's own `make fpr`):

- `python3 tests/check_base.py`: every step passes up to and including
  the Safety allow-list check (1074 s under load); the run then stopped
  at `check_specialization.py`, whose `cabal exec -- runghc` could not
  resolve the package because `PKG_CONFIG_PATH` did not name Homebrew's
  keg-only libarchive in that shell (`pkg-config package libarchive>=3.6,
  not found`), the same per-machine condition the Makefile's
  `NATIVE_PKG_ENV` exists for; it is not the binary. The remaining steps
  (check_specialization, check_workers, the inline Base block) were run
  from a copy of check_base.py with the passed steps removed and the
  path set: PASS, all 60 steps, 234 s.
- `python3 tests/check_std.py`: PASS, every module including the
  logbook live-app leg, 256 s.
- `tools/bench.py` (reported, not recorded; load 6 to 7 during the run):
  `workers: BUILD FAILED` with the undefined `_fpr_g_Bench_x2eelapsed_call1`
  / `_fpr_g_Bench_x2estart_call1` link error, and pingpong 1.9x,
  xpingpong 2.1x, fib 1.3x, strbuild 1.3x, byteloop 1.15x
  `bench/baseline.json`; the first four are the pre-existing set the
  10-18 page and the 2026-10-19 side notes recorded with the -O0
  compiler (the assembly is identical from either build, so the
  benchmark binaries are too), byteloop is within this run's load.

## Not verified

- QOS's Editor on a real install (`qos.py install`, Homebrew) and the
  Pi 4 appliance: the budget table is from reading the callers and from
  the capped runs on this Mac, not from running fprd under the new
  binary on a Pi. The Pi compiler keeps its -O0, 4 MiB-nursery build
  until its own ghc line changes.
- Boards (ESP32-P4, STAR64, the Buildroot Pi image) and the Linux and
  FreeBSD guests: not rebuilt or run; their `make fpr` picks up the
  new defaults the next time they build, and the arm64 Linux guest at
  2 GiB has room for the 600 MiB cold peak of pos1, by arithmetic only.
- Timings in the memory tables: the -O1 rows and the capped rows ran
  while another session loaded the machine (load 8 to 12), so their MUT
  and wall columns are inflated and do not show the 2x on their own;
  their memory columns are what this page needed. The paired warm run
  above, at load 4 to 5, is the compile-time measurement here, and the
  10-18 page has the cold and `fpr build` columns.
- The Sol profile, bytecode target and bare-metal targets were not timed
  with the -O1 compiler (the suites ran them).
- The `-A64m` floor on `fpr sol`: a long Sol session now holds up to
  64 MiB more; not measured.

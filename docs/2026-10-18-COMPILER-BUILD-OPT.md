# The compiler's own build optimisation

Date: 2026-10-18. Kind: measurement record and a build knob.
Base: FP-RISC `2ce2f5a` (code generation revision 49), GHC 9.8.2,
cabal-install 3.16.1.0, Apple M4 (10 cores), macOS.

## The question

2026-10-14-APP-ACCEPTANCE.md names compile time as the main felt cost of
an app: every deploy and every live reload pays for `fpr build`. The
compiler is built with `ghc -O0` on purpose (the Makefile's `fpr` recipe
and `ghc-options` in fp-risc.cabal): it is rebuilt many times a session
and the -O0 rebuild loop is fast. Only FPRISC, Sol.Bytecode and
Sol.Cache opt into -O2 through `OPTIONS_GHC` pragmas. How much of the
compile time is simply the unoptimised compiler, and can an optimised
build be had without slowing that loop?

## The knob

```sh
make fpr-opt              # -O2 compiler at build/fpr-opt
make fpr-opt GHCOPT=-O1   # the -O1 one, same place
```

- `make fpr` is unchanged: -O0, `dist-newstyle`, `./fpr`.
- `make fpr-opt` builds the same sources through cabal with the new
  manual flag `optimised` (fp-risc.cabal: `-O2` on top of the executable's
  `-O0`, so the flag wins) in its own build dir, `dist-opt-O2` (or
  `dist-opt-O1`), and writes the binary to `build/fpr-opt`. Neither build
  touches the other's objects, so both rebuilds stay incremental.
  `make clean-cabal` removes the `dist-opt-O*` dirs too.
- Without cabal the classic `ghc` path does the same with
  `-outputdir build/ghc-O2`.
- The optimised binary is a complete `fpr`: `build/fpr-opt build app.fpr`
  is the deploy command. It finds the prelude the way `./fpr` does (beside
  the checkout, or `FPR_HOME`).
- A from-scratch build of the compiler took 86 s at -O1 and 110 s at -O2
  (the two ran concurrently); a from-scratch -O0 build was not timed.

## Method

Each configuration is a compiler binary and a GHC RTS setting; each ran
on its own, in order, with the unit cache (`units/` beside the output
`.s`) deleted before its first `fpr compile`:

- compile cold: `fpr compile --system=posix --prelude=core/prelude.fpr
  examples/X.fpr X.s` with an empty unit cache (the prelude and every
  std module compiled);
- compile warm: the same again, every unit served from the cache; this is
  the state a deploy's `fpr build` is normally in, because `fpr build`
  shares `~/.cache/fpr/build/units` across runs;
- build: `fpr build examples/X.fpr -o X`, the second of two runs (the
  first is identical within a second once the shared cache is warm).

MUT and GC are the compiler process's own CPU times from `GHCRTS=-s`;
wall is the elapsed time of the command. The machine was not idle: other
sessions, Blender and a second `fpr` were running (load average 13 when the
-O0 pass started, 2.5 when the last pass ended), so wall times are
indicative and even the CPU times of the first two passes (-O0, -O2) are
inflated by contention. `-A64m` is `GHCRTS=-A64m`, a 64 MiB nursery in
place of GHC's default 4 MiB (`-with-rtsopts` sets only `-V0.001`).

## Results

logbook (examples/logbook.fpr, 114k lines of A64 assembly):

| compiler | RTS | compile cold wall | MUT | GC | allocated | compile warm wall | MUT | GC | allocated | build wall |
|---|---|---|---|---|---|---|---|---|---|---|
| -O0 | default | 47.9 s | 33.6 s | 11.6 s | 142.5 GB | 14.6 s | 10.9 s | 3.5 s | 54.8 GB | 29.1 s |
| -O1 | default | 24.9 s | 17.3 s | 7.2 s | 81.1 GB | 10.4 s | 7.0 s | 2.8 s | 23.1 GB | 24.4 s |
| -O2 | default | 41.8 s | 26.3 s | 10.7 s | 80.9 GB | 10.9 s | 7.5 s | 3.0 s | 23.0 GB | 25.4 s |
| -O0 | -A64m | 38.6 s | 30.7 s | 7.3 s | 142.4 GB | 13.5 s | 11.4 s | 1.9 s | 54.7 GB | 28.6 s |
| -O1 | -A64m | 24.1 s | 18.5 s | 5.2 s | 81.0 GB | 6.8 s | 5.6 s | 1.2 s | 23.0 GB | 19.5 s |
| -O2 | -A64m | 23.6 s | 18.1 s | 5.2 s | 80.8 GB | 7.7 s | 6.2 s | 1.3 s | 22.9 GB | 21.6 s |

pos1 (examples/pos1.fpr, 196k lines):

| compiler | RTS | compile cold wall | MUT | GC | allocated | compile warm wall | MUT | GC | allocated | build wall |
|---|---|---|---|---|---|---|---|---|---|---|
| -O0 | default | 56.8 s | 41.7 s | 14.0 s | 202.6 GB | 22.8 s | 17.1 s | 5.5 s | 81.3 GB | 46.0 s |
| -O1 | default | 39.6 s | 27.3 s | 11.2 s | 115.2 GB | 14.1 s | 9.9 s | 4.1 s | 34.5 GB | 34.2 s |
| -O2 | default | 38.2 s | 26.8 s | 10.6 s | 115.0 GB | 13.4 s | 9.3 s | 3.9 s | 34.4 GB | 33.1 s |
| -O0 | -A64m | 59.0 s | 46.3 s | 10.9 s | 202.4 GB | 21.1 s | 17.8 s | 2.9 s | 81.2 GB | 41.8 s |
| -O1 | -A64m | 30.2 s | 23.5 s | 6.7 s | 115.1 GB | 10.3 s | 8.4 s | 1.8 s | 34.5 GB | 28.6 s |
| -O2 | -A64m | 33.9 s | 26.1 s | 7.5 s | 114.9 GB | 12.1 s | 9.6 s | 2.0 s | 34.4 GB | 33.4 s |

Maximum residency did not move with the compiler (240 MB cold, 107 MB
warm for logbook; 336 MB and 155 MB for pos1); `-A64m` adds the
nursery's 64 MiB.

## What the numbers say

- The -O0 build is a large part of the compiler's own time. -O1 or -O2
  halves the allocation (142 GB to 81 GB cold, 55 GB to 23 GB warm) and
  takes the warm compile from 14.6 s to 10.4 s on logbook and from 22.8 s
  to 13.4 s on pos1. Cold, -O1 took 24.9 s against 47.9 s; the -O2 cold
  pass ran under the heaviest load of the sweep and its 41.8 s is not a
  property of -O2 (its warm numbers and the -A64m pass match -O1).
- -O1 and -O2 are the same compiler for this purpose: within noise on
  every warm number, and -O1 builds the compiler faster. The knob's
  default stays -O2; `GHCOPT=-O1` is the cheaper equivalent.
- GC is a quarter to a third of the compiler's time and the 64 MiB nursery
  takes most of it away regardless of the build: GC drops from 3.5 s to
  1.9 s (-O0) and from 2.8 s to 1.2 s (-O1) on a warm logbook, from 5.5 s
  to 2.9 s and from 4.1 s to 1.8 s on pos1, with MUT unchanged. It is
  orthogonal to the optimisation level and cheaper to adopt: it is a
  runtime flag. It is not the default yet (see below).
- Together, -O1 with `-A64m` makes the warm compile 2.1 times faster
  (14.6 s to 6.8 s on logbook, 22.8 s to 10.3 s on pos1) and `fpr build`
  1.5 to 1.6 times faster (29.1 s to 19.5 s, 46.0 s to 28.6 s).
- `fpr build` is not only the compiler. With `FPR_CC` pointed at a
  wrapper that times each cc call, a warm -O0 logbook build was 25.0 s of
  which the single cc call (assembling the program's 114k lines and the
  cached unit assembly, linking the cached runtime objects) was 12.4 s;
  pos1 was 45.6 s with 20.4 s in cc. The optimised compiler does nothing
  for that half, which is why a 2.1 times faster compile is a 1.5 times
  faster build. That half is the next place to look
  (2026-10-14-APP-ACCEPTANCE.md's 104 s for pos1 was on an M2 with the
  older compiler; today's warm pos1 build on the M4 is 46 s at -O0).
- The unit cache is the other half of the story: a cold compile is two
  to three times the warm one, and deploys are warm because `fpr build`
  shares its cache. A deploy from a fresh cache directory pays the cold
  column.

## Identical output

For both programs the `.s` written by the -O0, -O1 and -O2 compilers, with
and without `-A64m`, are byte-identical (`cmp`; SHA-1 of logbook's
`0d96b3bf…`, pos1's `2c304b6c…`, the same from every build). The unit
cache lists differ only in the absolute path of the cache directory each
run used.

## The checks with the -O2 compiler

A detached worktree of `2ce2f5a` with the -O2 binary installed as `fpr`
(its `build/.fpr-host-*` stamp created first, so the checks' own
`make fpr` step was a no-op and no other session's rebuild of `./fpr`
could swap the binary mid-run) ran `python3 tests/check_base.py`:

- every check passes. The two steps that are `cabal exec -- runghc` of
  compiler modules (tests/Specialization.hs, tests/Workers.hs) cannot run
  in a fresh worktree, which has no cabal package db; they do not use the
  binary and were run in the main checkout instead, where they pass. The
  binary halves of check_specialization and check_workers and the inline
  Base checks ran in the worktree and pass.
- `tools/bench.py` reports the same thing with the -O2 compiler and with
  the -O0 one, run back to back: fib, strbuild (1.1 times) and pingpong,
  xpingpong (4 to 4.7 times) slower than bench/baseline.json (recorded at
  `3a67d9a`), and `workers: BUILD FAILED`, a link error (undefined
  `_fpr_g_Bench_x2eelapsed_call1` and `_fpr_g_Bench_x2estart_call1` from
  the pairLoop worker). The link failure reproduces with the main
  checkout's own -O0 `./fpr` at `2ce2f5a`, and the workers.fpr assembly
  is identical from both compilers: it is the state of `2ce2f5a`'s
  private-worker pass, not the compiler build. The pingpong slowdown was
  not investigated here (the machine was not idle; both compilers report
  it alike). Both are follow-ups for the tree, not for this knob.

## Not verified

- The first -O0 baseline of the day was taken with a `./fpr` that
  predated the morning's commit (code generation revision 48; its
  assembly differed from the current compilers' in the revision tag and
  the `# private workers` line). It was discarded and the -O0 compiler
  rebuilt from `2ce2f5a` before the sweep above; the tables are all from
  revision 49 binaries.
- Wall times were measured under unrelated load, as said. The ordering
  between -O1 and -O2 is within that noise.
- Only the posix a64mac target was timed. The Sol profile, the bare-metal
  targets and `fpr compile --target=bytecode` were not timed with the
  optimised compiler, and the unoptimised compiler remains the one the
  sweep (`check-all.sh`) builds.
- `-A64m` was tried only as `GHCRTS`. Making it the compiler's default
  (`-with-rtsopts=-V0.001 -A64m`) is a one-line change in fp-risc.cabal
  and the Makefile's ghc path that this page does not make: the live
  runner and QOS's Editor start the compiler as a subprocess, and their
  memory budgets were not checked against the extra 64 MiB.
- The optimised compiler was not timed on Linux or on the Pi/STAR64
  hosts, where `fpr build` also runs.

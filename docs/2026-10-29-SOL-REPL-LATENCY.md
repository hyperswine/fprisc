# Sol REPL latency on Linux (2026-10-29)

CI `sol-repl-check` failed: session 57.9 ms/cmd vs process 19.0 (linux), 52.6 (macOS).
Measured on a Linux x86-64 box (GHC 9.10.3), SOL_TIMINGS=1, mean of 50 REPL commands:

| phase | ms/cmd |
|---|---|
| typecheck (whole prelude re-inferred) | 25.0 |
| bytecode (whole program) | 8.5 |
| transaction-commit (median 0.8; 0.04 with SOL_NOSYNC=1) | 1.6 |
| lower / specialize / layout | 1.3 / 0.4 / 0.1 |
| wall per command | ~37.5 |

Not Linux-specific and not GC (+RTS -s: GC ~4%; -A/-I/-N variants no gain); fsync <1 ms.
The old baseline re-ran ONE script 50x, i.e. compile-cache hits (~13 ms/process on Linux, ~10 ms of it exec);
the REPL bypasses the cache, so the ratio compared uncached vs cached. Fair baseline (50 distinct scripts):
~98–104 ms/process, REPL 2.7x faster. The gate now uses that baseline.

The 50 ms absolute bar is kept: it is missed on CI runners by real compute (prelude re-inference + whole-program
bytecode, ~90% of the command), not noise. Unlock: incremental compilation (prelude inferred/lowered once per session).

## Update: after incremental prelude (PR #27)
PR #27 compiles each command against only the prelude declarations it names.
Measured on the box: the session costs ~4.4 ms/command (was ~37.5). The gate's two
baselines both pass: cached process ~14.6 ms (CI linux 17.3, macOS 33.8) and
distinct uncached scripts ~26 ms. The fair baseline here is still the right
comparison; with #27 the gate is no longer close.

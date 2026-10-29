# Sol REPL speed after syncing remote main

Date: 2026-10-30. Local macOS ARM64, GHC 9.8.2, normal optimized compiler.

The local native-object/test-cache changes were preserved as `9489871` and
remote `main` at `f9f63a6` was merged in `af94c7a`. That includes the checked
library verdict cache, library slicing and the REPL fix that re-splices imports
on each command.

The repo compiler was rebuilt before checking or timing it. Use
`./fpr sol --repl` from this checkout to run that compiler.

## Interactive response

Real PTYs, input echo disabled. A sample starts when the harness writes a
complete command and ends at the next `sol> ` prompt, after its transaction
has finished. Every successful command's output is validated. GPU is disabled;
JIT uses its default setting. Two independent runs each contain three sessions
per workload. Parsed-prelude/library caches are isolated and reused within a
workload; full-program REPL compilation caching is bypassed by the REPL itself.

| Work | Median | p95 | Samples |
| --- | ---: | ---: | ---: |
| Process launch to first prompt, fresh prelude cache | 33.82 ms | 39.70 ms | 10 |
| Process launch to first prompt, warm prelude cache | 28.77 ms | 30.98 ms | 10 |
| Print a short string | 1.61 ms | 2.25 ms | 300 |
| JSON + CSV command, normal library optimization | 13.18 ms | 15.52 ms | 180 |
| Same JSON + CSV command, library slicing disabled | 38.60 ms | 40.72 ms | 180 |
| Command after 100 definitions | 15.33 ms | 16.92 ms | 120 |
| Command after 500 definitions | 60.41 ms | 63.72 ms | 120 |
| Rejected type error | 21.64 ms | 25.65 ms | 30 |
| Valid command after a type error | 1.55 ms | 3.05 ms | 30 |

A separate arithmetic workload (`> print (41 + 1).`, three sessions of 50
commands) measured **11.13 ms median**, 12.15 ms p95.

The JSON/CSV workload renders values with both libraries; normal library
optimization is 2.93 times as fast as the unsliced control. Both modes
run the same current binary and return the same expected output. The saved
`94f699b` binary fails this imported-library REPL workload with unbound aliases,
so timing its errors would be an invalid speed baseline. The pilot transcripts
record that failure and the corrected output from the new compiler.

Print-only commands were already fast after the incremental-prelude change:
`94f699b` 1.64 ms, current 1.61 ms. There is no material print-only command speedup in this update.

The 100/500-definition workloads retain that many ordinary constant bindings,
then run 20 checked queries per session. Definitions are submitted in batches
below the terminal line-size limit. The source still gets reparsed and checked
as a growing program; caching checked libraries does not cache the user's
inference environment. That remains the main response-time limit for large
sessions. Type errors take the diagnostic-preserving full-compile fallback;
the following valid command remains fast.

## Piped session versus separate processes

Each value below is a median of six complete trials, with 50 commands per
trial. Piped-session averages include process startup. Separate-process trials
use distinct source files/content, not repeated whole-program cache hits;
parsed prelude state is allowed to stay warm. Exit status, stdout and stderr
are checked for every invocation.

| Work | Before | Current |
| --- | ---: | ---: |
| REPL session, per command including startup | 2.02 ms | 2.01 ms |
| Separate uncached script, per command | 21.39 ms | 21.76 ms |

## Checks and reproduction

All pass after rebuilding:

- `tools/sol-repl-check.py`: 11 contract checks, including transaction visibility,
  persisted definitions, errors/recovery, continuation and redefinition refusal.
- `tools/sol-library-cache-check.py`: 347 differential cases, with library verdict
  establishment, negative/context-dependent verdicts, edited-library invalidation,
  shared caches and persistent REPL imports.
- `tools/sol-incremental-check.py`: 369 differential cases.

Save the old binary before updating, rebuild the selected new checkout, then:

```sh
python3 tools/sol-repl-benchmark.py --before /path/to/saved-fpr \
  --before-revision 94f699b --output /tmp/sol-repl-timings
```

The output directory must be fresh. The harness keeps raw samples and terminal
transcripts. [Evidence](evidence/2026-10-30-sol-repl-speed/summary.json) records
binary/revision identities, settings, checks and both rounds of measurements.
This is local speed/functional evidence; hosted CI and physical boards were
not part of this run. No user data or external effects are exercised.

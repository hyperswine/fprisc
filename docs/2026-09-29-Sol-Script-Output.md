# Sol script output and initial performance baseline

Date: 2026-09-29

This increment implements the first part of the scripting contract proposed in
`2026-09-29-Sol-Improvements-Needed.md`. It does not add a REPL or a bytecode cache.

## Script contract

- `fpr sol script.sol [args]` reserves stdout for explicit program output and
  forwarded deferred-process output. Bare `> expression.` statements and a
  zero-argument `main` still execute, but their returned values are not displayed.
  Use `print` when a script needs to emit a value. Old examples relying on `=>`
  must add explicit printing.
- Compiler errors, runtime errors, warnings, recovery messages and opt-in debug
  reports go to stderr. Warnings about retries, realtime effects, and failed
  deferred commands remain visible by default.
- `SOL_VERBOSE=1` enables successful transaction receipts, module pin notices,
  native compilation notices, memoization decisions and web-server startup
  notices, all on stderr. `SOL_TYPES`, `SOL_WIDTHS`, `SOL_TABLE_STATS`,
  `SOL_JIT_DEBUG` and `SOL_HJIT_DUMP` retain their individual opt-in controls.
- `fpr sol --asm script.sol` emits the requested disassembly on stdout and does
  not execute the script. It is a compiler-output mode.
- `shq` forwards child stdout and stderr separately, without adding a command
  banner. `Proc.afterCommit` retains its separate channels. Both still capture
  complete text: this change is neither streaming I/O nor an arbitrary-binary
  process API. The regression suite includes a NUL-containing output fixture.
- Successful foreground execution returns 0. Usage, compilation, file access,
  foreground runtime errors, exhausted retries and failed deferred commands
  return 1. A delivered Ctrl-C/UserInterrupt returns 130. Errors are distinguished
  in stderr rather than assigned a larger exit-code taxonomy.

A failed deferred command can follow an already-applied file commit; exit 1 does
not imply rollback. Immediate output can repeat when a transaction retries.
Background actor exception/lifetime semantics are unchanged. The SIGINT check
covers an in-process sleeping evaluation, not process-tree or terminal job control.

## Reproduce

From the repository root:

```sh
make fpr
python3 tools/sol-output-check.py
python3 tools/sol-benchmark.py --warmups 2 --runs 10 --output /tmp/sol-baseline.json
```

The baseline runner measures fresh processes with a warm filesystem, captures and
validates output, shuffles case order using a fixed seed, and records every sample.
It covers startup, one external process, a recursive sum, library imports, and
increasing tuple-pattern dispatch sizes. JIT and GPU are disabled explicitly.
The report includes platform, executable SHA-256, source revision/dirty state,
source hashes and the Cabal package configuration. Rebuild immediately before
recording; source revision alone is not a binary build identity.

These are end-to-end latency baselines, not throughput or speedup claims. Phase
timings, peak memory, allocation profiling, cold-cache runs and optimized release
build comparisons remain follow-up work. No performance thresholds are enforced.

## Validation on macOS arm64

The exact-output suite passes 26 checks. The existing transaction, process/git and
safety suites pass. The general script suite stops at `version-compare.sol:43`
with `case: not exhaustive -- no arm matches Nil`. A separately built, untouched
HEAD snapshot reproduces that failure; it is not introduced by the output change.

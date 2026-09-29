# Sol case fallback compilation

Date: 2026-09-29  
Kind: implementation and measured regression fix.  
Baseline: `8a6b301` (clean script output and baseline tools).  
Applies to: the shared frontend change delivered with this page.

This is the next increment after [script output](2026-09-29-Sol-Script-Output.md),
addressing the pattern-lowering growth identified in
[Sol improvements needed](2026-09-29-Sol-Improvements-Needed.md).

## Change

`compiler/FPRISC.hs` previously copied all remaining case arms into every failure
edge of a nested pattern. For `(i, i)` patterns there are three tests per arm,
so the generated tree could grow exponentially with the number of arms.
Function clauses already shared many such fallbacks; case expressions did not.

Case fallbacks with multiple incoming failure edges now get one delayed helper.
Lambda lifting captures the surrounding lexical bindings and emits saturated
direct calls. Captures are saved outside the current pattern's bindings so a
partially matched arm cannot change what the next arm sees. The dummy argument
keeps capture-free helpers delayed. Direct calls preserve native tail recursion
and use the existing function-entry fuel checks; counts of fuel checks may change.
Lambda lifting also drains helpers enqueued while processing other helpers.

The lexical snapshot fixes a pre-existing wrong-result case:

```sol
shadow x p = case p of (x, 0) -> x | _ -> x.
> print "{shadow 42 (7, 1)}".
```

Before: `7`. After: `42`. The binding made inside a failed pattern must not leak
into the fallback arm. Successful matching still returns the pattern's `x`.

This changes the shared frontend, so it applies beyond Sol. It adds no persistent
bytecode cache, REPL, streaming process support or alternate transaction model.

## Measurements

macOS arm64, the same local development build recipe, JIT/GPU disabled. Two
warmups and five fresh-process samples per case/version, fixed-seed shuffled
order, stdout/stderr captured and expected script output checked. Timing includes
startup, compilation and execution. Disassembly bytes were measured separately
and include the prelude; they are not machine-code or bytecode serialization size.

Each generated case is a sequence of `(i, i) -> i` arms followed by `_ -> -1`,
called with the final matching tuple.

| Arms | Before median | After median | Before disassembly bytes | After disassembly bytes |
| --- | ---: | ---: | ---: | ---: |
| 4 | 66.66 ms | 55.70 ms | 51,810 | 37,438 |
| 8 | 103.04 ms | 55.47 ms | 1,680,120 | 39,614 |
| 10 | 512.75 ms | 65.00 ms | 16,475,844 | 40,702 |

These observations show the focused scaling improvement, not a general speedup
for every Sol script. Host load affects small latency differences. No isolated
phase timing, allocation/peak-memory profile, or hardware-board run is claimed.
The synthetic structural check is the deterministic regression gate: lowered Core
node counts for 4/8/16/32/64 arms are 190/330/610/1170/2290. The old frontend gives
858/65658 for 4/8 arms and fails the same growth bound immediately.

## Acceptance

```sh
make fpr
python3 tests/check_case_growth.py
python3 tests/check_cases.py
python3 tools/sol-output-check.py
sh tools/sol-txn-check.sh
sh tools/sol-proc-git-check.sh
sh tools/sol-safety-check.sh
```

All commands passed on the local macOS arm64 host. The new test runs the same
semantic fixture under Sol and the native Base executable. It checks first/middle/
last/default arms, tag/field failure, lexical shadowing, nested closure captures,
string/list patterns, exact effect order, scrutinee evaluation once, helpers inside
clause fallbacks, and a 20,000-step native tail-recursive loop. A Sol-specific
fixture checks linear vector consumption. Structural and disassembly checks bound
code growth through increasing pattern sizes. The existing 200,000-step
`tests/patguard.fpr` program also passed through Sol with an explicit `main Unit`
entry statement.

The general script suite's previously confirmed `version-compare.sol`
non-exhaustive-case error is outside this change. The source remains unchanged.

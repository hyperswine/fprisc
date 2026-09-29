# Sol improvements: assessment and implementation log

This is the consolidated record of Sol improvements. Sections are historical
snapshots: later entries supersede earlier statements about missing features.
Earlier timestamps are the corresponding commit times; the latest entry is the
verification time, rounded to the minute, in Australia/Sydney (AEST, UTC+10). The initial assessment preserves its local edits.

Current delivered work: clean script output, bounded case lowering, indexed VM
instructions, validated compiler caching, indexed Unicode text access, and
streaming/inherited subprocess interaction. A persistent REPL, PTYs and shell
job control remain separate work.

## 2026-09-29 18:13 AEST — Initial assessment

Recorded with `0cf6d72`.


Date: 2026-09-29
Kind: implementation assessment and proposed work plan.
Source baseline: `ddbb44ba6040078506baa9282ba677834515f3ca`.
Status: open improvements; this document does not implement or promise them.

Sol is already useful for small scripts and structured automation launched from
an existing shell. It is not yet a comfortable interactive shell replacement.
The principal gaps are predictable startup, an actual persistent REPL, process
and terminal integration, clear transaction boundaries, and a polished scripting
contract. The goal is to retain FP-RISC's semantics while making routine scripting
and interactive work natural.

This supplements [What is Sol?](2026-09-19-WHAT_IS_SOL.md). That page's standalone
runner and deployable bytecode architecture remain proposals, not shipped tools.

### 1. Performance: measured startup and execution

On 2026-09-29, the current local `fpr sol` executable was compared with macOS
`/bin/bash` 3.2.57 on arm64. Each case had two warmups and ten measured fresh
processes, with case order shuffled each round, stdout/stderr captured, and Bash
startup files disabled. These are median wall times including process startup,
compilation and execution. They are warm-filesystem measurements, not cold-boot
results or isolated VM throughput measurements. The executable was not rebuilt
for this measurement, so the source baseline is not a verified binary build ID.

| Work | Bash | Sol | Sol / Bash |
| --- | ---: | ---: | ---: |
| Print `hello` | 2.8 ms | 55.5 ms | 20x |
| Run one external `/usr/bin/true`, then print | 4.4 ms | 67.8 ms | 15x |
| Run twenty external `/usr/bin/true`, then print | 31.5 ms | 80.6 ms | 2.6x |
| Sum integers 1 through 10,000, then print | 27.8 ms | 96.1 ms | 3.5x |
| Run an external 100 ms sleep, then print | 108.2 ms | 172.5 ms | 1.6x |

Sol paid roughly 50–70 ms extra for these short command-oriented scripts. That
matters for repeated tiny invocations, prompt integration and one invocation per
file. It matters much less when the external work takes seconds. The arithmetic
case also suggests execution overhead, but one loop does not establish general
numerical performance. Subtracting separate startup measurements is only a rough
estimate, not a VM benchmark.

The tests used `Proc.query (ProcessSpec argv "" [] "" 1000)` for subprocesses;
Bash invoked the same executables. The sum used a measured tail-recursive Sol
function and a Bash arithmetic `for` loop. All runs exited successfully and their
expected final output was checked. The twenty-process Sol case used twenty
explicit top-level statements, so it does not measure a process-spawning loop.
Raw samples and script sources were saved in the local assessment workspace as
`sol-bash-benchmark.json`; the table here is self-contained and does not depend on
that machine-local file remaining available.

#### Startup and large-program compilation

`compiler/Sol/Main.hs` expands imports, checks/transforms the program and prepares
bytecode on each invocation. There is no persistent compiled-program cache in
this execution path. A cache would help repeat invocations, but cannot substitute
for fixing excessive compilation work on a cache miss.

Earlier QRepo prototype measurements were much worse: approximately 7.90 seconds
to import its program and 11.56 seconds for a one-file status operation, with
about 1.4 GB process footprint observed during the investigation. These are
historical application-specific results, not rerun for this document and not a
claim that ordinary Sol scripts take seconds to start.

The subsequent native QRepo port exposed severe compilation growth with a large
nested `case` dispatcher; rewriting it as function clauses substantially reduced
compilation cost. Fallback duplication in pattern lowering is a candidate for a
focused compiler regression test. This does not prove that one compiler pass
explains all of the earlier Sol slowdown.

- [ ] Add repeatable startup, import-heavy, nested-pattern and execution benchmarks.
- [ ] Record phase timings, peak memory, allocations and binary build identity.
- [ ] Fix pathological transformation/lowering growth, with a semantic regression
  test and a size/scaling test for the troublesome pattern shape.
- [ ] Design compiled-program/module caching keyed by source and transitive
  dependencies, compiler/bytecode version, profile options and relevant host ABI.
  Verify invalidation, corruption handling and concurrent cache writers.
- [ ] Avoid reprocessing an unchanged prelude where the compilation model permits it.
- [ ] Measure cold runs, warm runs and cache misses separately; choose numerical
  performance targets after establishing reproducible baselines.

#### Data processing and library costs

Ordinary string indexing in `compiler/Sol/VM.hs` uses Haskell list `length` and
`!!`; substring operations use `length`, `take` and `drop`. Repeated indexed
traversal can therefore become quadratic. Existing linear string buffers do not
automatically make all ordinary String operations or libraries efficient.

The old QRepo implementation additionally used repeated list searches, whole-tree
scans/content retention and one hash subprocess per object. Those are partly
application choices; they should not all be attributed to the VM.

- [ ] Benchmark text traversal, JSON parsing/rendering, binary I/O and collection
  lookup across increasing input sizes, including allocation and peak memory.
- [ ] Provide an efficient, coherent Bytes/text/builder path with explicit Unicode
  and indexing semantics; avoid accidental full copies at API boundaries.
- [ ] Audit Map/Set and hashing availability and performance in Sol specifically.
  Establish which shared modules work before claiming a capability is absent.
- [ ] Provide practical streaming/chunked file processing and efficient hashing
  without a subprocess per small object.

### 2. A real REPL and interactive experience

The current command entry accepts a script; `sol/examples/interactive_script.sol`
is a calculator with an input loop, not a persistent language evaluator. Reading
terminal input is useful, but does not supply a general REPL.

- [ ] Add a persistent session that evaluates expressions and top-level effects,
  accepts definitions/imports and preserves bindings between commands.
- [ ] Support multiline input with clear continuation prompts and incomplete-input
  detection, rather than treating every newline as a syntax error.
- [ ] Add line editing, history navigation/search and symbol/module/path completion.
  Make history persistence optional and define how sensitive commands are excluded.
- [ ] Add type inspection, help/documentation, binding inspection, load/reload,
  reset and exit commands, with useful source locations in diagnostics.
- [ ] Let Ctrl-C cancel the current evaluation without destroying the session;
  recover cleanly from parse, type and runtime errors, and handle EOF predictably.
- [ ] Define redefinition and reload behavior, including existing function values,
  types, linear handles and running actors that refer to older definitions.
- [ ] Bound retained session resources through explicit cleanup/reset semantics;
  test long-running sessions rather than only successful short examples.

The transaction model is part of the REPL design. A whole interactive session
must not silently become one giant retryable script. A proposed default is one
transaction per submitted command, with explicit larger transactions when useful.
Before implementing it, specify which bindings survive failed evaluation, how
linear resources cross command boundaries, and how external effects are reported.

### 3. Process, terminal and shell integration

Sol already has structured argv, cwd, environment overrides, stdin text, timeouts
and exit/stdout/stderr results through `ProcessSpec` and `ProcessResult`.
`Proc.query`, `Proc.afterCommit` and `Proc.runNow` express different effect timing.
These are a useful foundation and should not be replaced by shell-string quoting.

The current process runner in `compiler/Sol/Txn.hs` uses
`readCreateProcessWithExitCode`: it captures complete text output. It does not
provide a complete streaming, pipeline, PTY or shell job-control experience.

- [ ] Add streaming stdin/stdout/stderr with backpressure and bounded buffering.
- [ ] Support inherited terminal I/O and PTYs for interactive subprocesses.
- [ ] Define pipelines, redirection, process groups, foreground/background jobs,
  waiting and cancellation; preserve argv boundaries and each process's exit status.
- [ ] Verify Ctrl-C, timeout and cancellation cleanup for child process trees,
  including subprocesses that spawn grandchildren.
- [ ] Define session cwd/environment changes and command lookup. Decide whether
  direct shell-like command syntax is wanted; it is a product choice, not required
  to make the structured process API useful.

### 4. Transactions and external effects need a clear contract

Whole-script retries are useful for transactional file work, but arbitrary
processes, printed output and interactive input cannot simply be rolled back.
`Proc.query` runs a process; its name does not enforce that the executable is
read-only. Immediate external effects may repeat on retry. Deferred-command
recovery has an at-least-once window if execution finishes before its completion
record becomes durable. Do not describe arbitrary external commands as exactly
once or include them in an unconditional atomicity guarantee.

At the current transaction boundary, remaining actors are cancelled and joined.
A persistent shell or interactive application needs a deliberate lifetime policy,
not an assumption that actors already survive command transactions safely.

- [ ] Document file transaction guarantees separately from external observability,
  realtime escapes, retry behavior and deferred-command recovery.
- [ ] Provide explicit transaction boundaries suitable for long-running programs
  and REPL commands, with clear failure and partial-success results.
- [ ] Define actor/resource ownership across commit, retry, cancellation and reload.
- [ ] Add focused failure/recovery tests for externally visible effects; document
  idempotency requirements instead of implying universal exactly-once behavior.

### 5. Clean scripting output and errors

`compiler/Sol/Main.hs` currently prints several compiler/runtime diagnostics,
transaction receipts and non-Unit expression results to stdout. Earlier smoke
checks also observed module-resolution messages before JSON output. This makes
otherwise successful scripts awkward to use in Unix pipelines.

- [ ] Keep script stdout reserved for intentional program output; send diagnostics
  and receipts to stderr, with verbose/debug output opt-in.
- [ ] Separate REPL value display from noninteractive script output.
- [ ] Define consistent exit statuses for compilation, runtime failure, cancelled
  work, exhausted retries and deferred-process failure.
- [ ] Verify exact stdout bytes with JSON and binary-producing scripts, alongside
  stderr and exit status checks. Avoid tests that only search for an expected line.

### 6. Packaging and everyday library coverage

A standalone Sol runner, deployable/versioned bytecode and a smooth installation
experience remain work to do. The existing library has useful process, JSON, CSV,
math and other pieces; their presence is not evidence of comprehensive Python- or
shell-replacement coverage or consistent performance across backends.

- [ ] Choose and implement the standalone runner/compiler packaging contract,
  including shebang use, script arguments and running outside a source checkout.
- [ ] Define bytecode compatibility and module resolution/versioning independently
  of whether the host also has the full FP-RISC compiler installed.
- [ ] Audit a small practical set of workflows: filesystem traversal, binary/text
  conversion, JSON/CSV, HTTP, hashing, collection processing and numerical arrays.
- [ ] For scientific/interactive use, measure array operations and establish a
  practical plotting/display and library interoperability story. Treat these as
  coverage goals to assess, not verified absence of every underlying primitive.
- [ ] Keep examples and tooling aligned with the actual type/safety checker and
  profile. Older descriptions of Sol as having no type inference are outdated.

### Suggested delivery order

1. Clean stdout/stderr and exit behavior, plus reproducible performance baselines.
2. Fix pathological compilation and implement carefully invalidated caching.
3. Add streaming/inherited process I/O and reliable cancellation.
4. Implement a minimal persistent REPL with explicit per-command transactions,
   error recovery, multiline input and type inspection.
5. Add editing/history/completion, reload and terminal/job-control features.
6. Finish standalone packaging and prioritize library/scientific work from real
   scripts and measured bottlenecks.

This order is a proposal. Every milestone should have a small executable
acceptance example; a working calculator, successful build or collection of
library filenames is not sufficient evidence that the shell experience is done.

## 2026-09-29 18:25 AEST — Sol script output and initial performance baseline

Recorded with `8a6b301`.


Date: 2026-09-29

This increment implements the first part of the scripting contract proposed in
the initial assessment above. It does not add a REPL or a bytecode cache.

### Script contract

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

### Reproduce

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

### Validation on macOS arm64

The exact-output suite passes 26 checks. The existing transaction, process/git and
safety suites pass. The general script suite stops at `version-compare.sol:43`
with `case: not exhaustive -- no arm matches Nil`. A separately built, untouched
HEAD snapshot reproduces that failure; it is not introduced by the output change.

## 2026-09-29 18:34 AEST — Sol case fallback compilation

Recorded with `0fb6047`.


Date: 2026-09-29
Kind: implementation and measured regression fix.
Baseline: `8a6b301` (clean script output and baseline tools).
Applies to: the shared frontend change delivered with this page.

This is the next increment after [script output](#2026-09-29-1825-aest--sol-script-output-and-initial-performance-baseline),
addressing the pattern-lowering growth identified in
[Sol improvements needed](2026-09-29-Sol-Improvements-Needed.md).

### Change

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

### Measurements

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

### Acceptance

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

## 2026-09-29 18:49 AEST — Sol indexed VM and validated startup cache

Recorded with `9f25b10`.


Date: 2026-09-29

This increment follows the output and case-fallback work. Instruction fetch now
indexes an immutable zero-based array instead of traversing a list from its head
for every instruction. Register frames remain maps, and call/return behavior is
unchanged. This is an instruction-fetch improvement, not a complete VM rewrite.

### Startup contract

The runner caches successfully checked and lowered Core, bytecode, layouts, run
order, and compiler warnings. The default location is the platform XDG cache root
under `fpr/sol`; override it with `SOL_CACHE_DIR`. `SOL_CACHE=0` disables the cache.
`SOL_CACHE_TRACE=1` reports hit/miss/disabled and write failures on stderr. Normal
runs remain quiet. `SOL_TYPES=1` and `SOL_WIDTHS=1` bypass the cache to recompute
requested compiler diagnostics.

Root source, prelude, and the expanded dependency AST are part of the exact key,
as are compiler options, script path, platform, schema, and executable identity.
Imports are resolved, read, parsed, and pin-checked on every invocation before
lookup. Transitive source changes and module shadowing therefore cannot silently
reuse a different program. Whitespace-only dependency edits may safely reuse the
same AST. This does not yet cache parsing or the dependency graph.

Executable identity includes path, device, inode, size, nanosecond-resolution
mtime/ctime (as supplied by the filesystem), and compiler/platform metadata.
This avoids scanning the whole executable on every invocation; rebuilding or
replacing it invalidates entries. Cache slots use a small hash, but the complete
input key must match before accepting an entry. Serialized entries have a checksum,
a schema marker and a 64 MiB limit. Corrupt/missing entries are misses; unavailable
cache storage is nonfatal. Writes use a private temporary file and atomic rename.
This is trusted local build storage, not an authenticated portable bytecode format.
Old executable/script slots are not automatically garbage-collected yet.

Values, script arguments, transactions, actors, JIT machine code, file contents,
and effects are never cached. Warnings are replayed on hits. Runtime initialization,
journal recovery, reads, writes, retries and process execution still happen per run.

### Measurement and reproduction

```sh
make fpr
SOL_TIMINGS=1 SOL_CACHE_TRACE=1 ./fpr sol script.sol
./fpr sol script.sol +RTS -s -RTS
python3 tools/sol-startup-check.py
python3 tools/sol-vm-startup-benchmark.py --baseline /path/to/previous/fpr --output /tmp/sol-vm-startup.json
```

`SOL_TIMINGS=1` prints source, parse, imports, compiler stages, cache I/O, startup
and execution wall times to stderr. It forces results at the measured boundaries,
so enabling it adds work and changes evaluation timing. Parent startup time
includes its child phases; do not sum them together. Typecheck includes demand for
preceding surface rewrites. The startup phase ends before runtime initialization;
fresh-process wall time also includes loader, runtime initialization and teardown.
RTS statistics report whole-process allocation/residency, not OS peak RSS.

Local macOS arm64 development build (`-O0`), baseline `0fb6047`, one warmup and
seven shuffled samples per case, fresh processes with a warm filesystem. JIT, GPU
and memoization disabled. These are end-to-end medians, not isolated dispatch costs.

| Workload | Previous | New, cache disabled | New cache miss | New cache hit |
| --- | ---: | ---: | ---: | ---: |
| Hello | 55.89 ms | 65.68 ms | 68.09 ms | 30.71 ms |
| Proc + CSV imports | 68.39 ms | 79.67 ms | 80.73 ms | 43.03 ms |
| 500 calls, 16 arithmetic steps | 68.05 ms | 68.42 ms | — | — |
| 500 calls, 64 arithmetic steps | 80.73 ms | 80.83 ms | — | — |
| 500 calls, 256 arithmetic steps | 205.67 ms | 143.92 ms | — | — |

The wide workload improves about 30%. Warm hello/import invocations improve about
45%/37% relative to the previous binary. Small uncached invocations regress in this
measurement; cache creation also adds work. This does not promise bounded startup
latency or improvement for every program. A separate instrumented warm hello sample
spent 15.6 ms parsing and 5.4 ms reading the cache, pointing to parsing/allocation as
the next startup target. One warm hello RTS sample allocated 192 MB while maximum
sampled heap residency was 786 KB; allocation is not retained memory.

`tools/sol-benchmark.py` now explicitly disables the cache so its historical
compilation baselines remain comparable. The new benchmark records both binary
SHA-256 hashes and raw samples. Performance has no machine-specific pass threshold.

### Verification

The new startup checks cover warm/disabled behavior, root and transitive edits
(including equal-size/equal-mtime edits), missing dependencies, pins, resolution
shadowing, compiler flags and identity, warning replay, runtime arguments/file
reads, writes/retries/rollback, JIT Core restoration, corrupt/truncated cache files,
unavailable storage and concurrent writers. Bytecode disassembly matched the
previous binary for the three arithmetic workloads.

Freshly passed: output contract (26 checks), startup checks (51 plus assembly,
concurrent writers and compiler identity), case-growth and shared case/signature
regressions, transactional properties, structured process/Git wrappers, and
purity/filesystem/lock/actor-retry checks. The previously established unrelated
`version-compare.sol:43` non-exhaustive-case failure in the full scripts suite is
not addressed by this increment.

## 2026-09-29 19:02 AEST — Efficient text and subprocess interaction

This entry consolidates the earlier three implementation pages into this log and
implements the next text/process increment against `9f25b10`. The original local
metadata edits are retained in the initial assessment. Historical checklists
above describe their own snapshot, not current implementation status.

### Ordinary String indexing

`VStr` is now a compatibility pattern over a value with its sequential text,
lazily cached length, and a lazily built immutable character array. Existing Sol
programs gain indexed access without converting to a new Text type. Printing and
sequential transforms do not demand the index. The first length query traverses
the string; the first indexed access builds the array; subsequent length and
character accesses are O(1). A substring copies the selected characters without
walking the preceding prefix. Indexed strings retain extra O(n) array storage.
Length-only access does not allocate that array.

The contract remains 1-based Unicode code points, not UTF-8 byte offsets or
user-perceived grapheme clusters. Combining marks count separately. `charAt`
rejects invalid indices; `substr` clamps starts below 1 and lengths below 0, and
returns empty beyond the end. Very large Sol integers are checked before conversion
to host Int, avoiding wraparound. Embedded NUL and supplementary-plane characters
are covered. Comparisons, rendering, concatenation and library string operations
retain the ordinary String API.

This does not replace strings with packed UTF-8, add streaming transactional file
reads, fix repeated append construction, or complete a Bytes/hash/Map/Set audit.
JSON's indexed parser benefits, but its string builder and Unicode escape grammar
remain separate work. Large source literals also remain a parsing cost; the I/O
regressions use input files instead of embedding hundreds of kilobytes in source.

### Live subprocess I/O

Two new APIs preserve `ProcessSpec argv cwd env stdin timeoutMs`:

| API | stdin | stdout/stderr | Result |
| --- | --- | --- | --- |
| `Proc.query` / `Proc.runNow` | Spec text | Separate captured text | `Result ProcessResult String` |
| `Proc.streamNow` | Spec text, EOF when sent | Direct inherited descriptors | `Result Int String` |
| `Proc.inheritNow` | Inherited descriptor | Direct inherited descriptors | `Result Int String` |

```sol
> r = Proc.streamNow
    (ProcessSpec ["/bin/cat"] "" [] "hello λ\n" 1000);
  case r of
    Ok 0 -> Unit
  | Ok code -> error "child exited {code}"
  | Err message -> error message.
```

Streaming output bypasses Sol text decoding and output capture: arbitrary bytes
flow immediately, and OS pipes provide backpressure. Spec stdin is still a complete
Sol String. Inherited stdin accepts binary data and rejects a nonempty Spec stdin
rather than silently discarding it. Neither live API returns captured output.
A nonzero child exit is `Ok code`; creation/I/O/timeout errors return `Err`.
Signal termination retains the process library's exit-code convention.

Both new operations are realtime escapes: they refuse to run ahead of pending
transactional effects, warn on stderr, survive rollback, and can repeat on retry.
They do not create transaction boundaries. `Proc.afterCommit` retains deferred
captured-text behavior. The older shell-string APIs are not rewritten here.

Structured children now run in their own POSIX process group. On timeout, I/O
failure or asynchronous cancellation, Sol kills that group with SIGKILL, reaps the
leader, joins its I/O workers and closes the pipes. This handles TERM-ignoring
children, ordinary grandchildren, and a leader that exits while descendants keep
capture pipes open. Deliberately detached sessions are outside this group boundary;
successful commands may still leave background descendants. Cleanup is forceful,
so applications do not receive a graceful shutdown interval.

Inherited terminal input temporarily hands the foreground terminal to the child
group and restores it to Sol afterward. Tests use an actual controlling PTY and
require both the child and the resumed parent to read successfully. Sol does not
allocate a PTY for a redirected process, implement a job table, handle suspend/
resume jobs, or define concurrent interactive child sessions in this increment.
The Haskell executable now uses `-threaded` so a process wait cannot stall pipe
writers or cancellation handling.

### Verification and measurements

```sh
make fpr
python3 tools/sol-text-process-check.py
python3 tools/sol-text-benchmark.py --baseline /path/to/previous/fpr --output /tmp/sol-text-processing.json
```

All 34 focused checks passed. They cover Unicode and huge indices, string operations and JSON, exact
argv, separate output channels, invalid-UTF-8 binary streaming, inherited stdin,
working directory, simultaneous large stdin/stdout/stderr, early stdin closure,
live output before exit, stalled-consumer backpressure, pending-effect fences, output-decoding failures, timeout
and SIGINT process-group cleanup, and real terminal handoff/restoration.

The broader output, startup/cache, transaction, process/Git, filesystem/actor and
shared case-growth suites passed on macOS arm64. Linux and other POSIX hosts were
not exercised. The existing full-script-suite failure described above remains
outside this increment.

Final measurements: macOS arm64, development `-O0` builds, one warmup and five
shuffled fresh-process samples. Cache/JIT/GPU/memoization disabled. Execution
phase timing includes transactional file read and output; phase instrumentation
forces boundaries. Input files avoid measuring large literal parsing. The new
binary also enables the threaded runtime. These are workload measurements, not
universal speedup claims or latency thresholds.

| Workload | Previous execution | New execution | Previous wall | New wall |
| --- | ---: | ---: | ---: | ---: |
| scan_1000 | 8.47 ms | 3.94 ms | 67.85 ms | 68.29 ms |
| scan_4000 | 79.05 ms | 14.65 ms | 142.56 ms | 79.92 ms |
| scan_16000 | 843.58 ms | 67.48 ms | 905.80 ms | 130.83 ms |
| json_100 | 11.12 ms | 10.18 ms | 105.79 ms | 115.01 ms |
| json_400 | 54.88 ms | 37.96 ms | 155.85 ms | 141.62 ms |
| json_1600 | 438.11 ms | 151.87 ms | 536.69 ms | 255.15 ms |

The 16,000-code-point scan improves about 12.5x in execution (6.9x end to end);
the 1,600-element numeric JSON array improves about 2.9x in execution (2.1x end
to end). Small programs remain startup-sensitive. Retained index memory is an
explicit tradeoff; these measurements do not include allocation or peak RSS.
The benchmark saves raw samples and both executable SHA-256 hashes.

## 2026-09-29 19:49 AEST — End-to-end cache and transaction costs

This increment builds on `2d2fb0a`. The preceding bytecode cache still parsed the
prelude and all source files before lookup; imports were parsed once for their
pin hash and again for expansion. Warm startup consequently retained substantial
frontend work. Profiling also showed allocation from decoding reread transaction
files purely to compare them at commit.

### Global content cache

The default cache is now `~/.sol/cache`; `SOL_CACHE_DIR` still overrides it.
Compiled-program filenames use FNV-1a over the complete encoded input key instead
of a single slot per executable/script. Restoring a prior source version can hit
its earlier artifact. Keys still include source, expanded dependencies, prelude,
paths, compiler identity, platform/schema and relevant compiler options. Relative
imports and source positions mean identical text at different paths is not assumed
to be interchangeable.

`modules/` stores parsed root/module ASTs and their existing AST pin hashes,
keyed by source contents, path and compiler identity. Source bytes are read on each
invocation and import resolution/pins remain checked. Warm hits reuse parsed ASTs;
the resolved AST is reused directly for expansion. A compiled hit skips prelude
parsing entirely. This is parsed-module reuse plus a whole-program bytecode cache,
not independently linked, typechecked module bytecode.

The fast filename hash is only a lookup aid: saved exact input bytes must match.
Existing entry checksums, 64 MiB per-entry limit, private temporary files, atomic
rename, corruption-as-miss behavior and nonfatal unavailable storage remain.
`SOL_CACHE=0` disables both tiers. Type/width diagnostics bypass compiled artifacts
but may reuse parsed source. Cache checksum/serialization code is now compiled
with `-O2`, including in the otherwise `-O0` development compiler.

No runtime result, external effect, actor or machine-code address is persisted.
Warnings still replay. Cache files are trusted local build products, not an
untrusted interchange format. There is no automatic eviction; source/compiler
versions can accumulate. Old XDG cache entries are not migrated or deleted.

### Transaction validation

Transactions now retain exact byte snapshots alongside the decoded text view.
Commit rereads the bytes under the existing locks and compares them directly;
it no longer decodes and traverses another linked-list String for comparison.
Timestamp-only shortcuts are deliberately absent. Read-your-writes, snapshot
reuse, lock ordering, retries, journal durability and external-effect boundaries
are unchanged. Realtime writes forget both snapshot representations.

This also fixes a conflict-detection bug: different invalid UTF-8 byte sequences
could previously compare equal after lossy decoding. A regression replaces FF
with FE while preserving size/mtime and requires a retry. Text APIs still reject
invalid UTF-8 rather than exposing it as valid text.

`SOL_TIMINGS=1` now includes `transaction-commit`. It is a subphase of execution,
not an additional time to add to the total. Initial text decoding and its linked
String allocation remain significant. Retaining raw bytes can increase residency;
reducing allocations does not imply reducing maximum live heap.

### Validation and measured results

```sh
make fpr
python3 tools/sol-startup-check.py
python3 tools/sol-cache-txn-check.py
python3 tools/sol-e2e-benchmark.py --baseline /path/to/previous/fpr --output /tmp/sol-e2e.json
```

Passed 52 startup checks plus assembly/concurrent-writer/compiler-identity checks;
root/module cache corruption and invalid-source tests; exact-byte transaction
conflicts; 26 output checks; transaction, structured process/Git, filesystem/actor
suites; and 34 text/live-process/PTY checks. Verification is local macOS arm64.

The benchmark records both binary hashes, five shuffled fresh-process samples per
case following one warmup, separate warm/miss/disabled modes, phase traces and one
RTS allocation/residency sample per binary. Filesystem caches are warm. Misses
remove both cache tiers. JIT/GPU/memoization are disabled. Wall measurements do not
enable phase instrumentation. This is a development-build comparison; cache code
alone changes to `-O2`, not the entire compiler/runtime.

| Workload | Previous warm | New warm | Previous miss | New miss |
| --- | ---: | ---: | ---: | ---: |
| hello | 29.29 ms | 17.86 ms | 68.27 ms | 67.61 ms |
| imports | 66.24 ms | 30.49 ms | 116.26 ms | 103.69 ms |
| read_65536 | 43.14 ms | 28.62 ms | 68.32 ms | 68.34 ms |
| read_262144 | 55.78 ms | 43.19 ms | 93.27 ms | 93.12 ms |
| read_1048576 | 143.83 ms | 117.88 ms | 169.06 ms | 153.47 ms |

Warm hello improves about 39%, three-library imports about 54%, and the 1 MiB
transactional read about 18%. First-run hello is essentially unchanged. Separately
instrumented samples put root parse/cache lookup around 0.26 ms rather than
18.3 ms of root+prelude parsing, and import preparation around 3.3 ms rather than
24.0 ms. Full startup includes other phases; these samples must not be added to
the uninstrumented medians.

The 1 MiB warm-read RTS sample allocated 784,178,360 bytes before and 412,332,976
after (about 47% less). Sampled maximum heap residency was 52,266,424 vs 48,154,152
bytes in that run, but intermediate runs showed higher new residency: the sampled
peak is sensitive to GC timing, and this is not a general peak-memory reduction
claim. Neither figure is OS peak RSS. The new commit phase took 0.811 ms while
execution took 87.008 ms; initial decoding/allocation is now the larger remaining
cost for that workload. Cache deserialization still dominates tiny warm startup.

The actual default `~/.sol/cache` location was smoke-tested with a cold miss then
a warm hit. A changed source/compiler creates another artifact; disk retention
policy and a standalone compact bytecode format remain follow-up work.


## 2026-09-29 20:12 AEST — runtime timer and optimized cache serialization

### Implementation

The Cabal and direct-GHC builds now link the threaded runtime with
`-with-rtsopts=-V0.001`. The runtime timer stays enabled, with a 1 ms interval;
threaded subprocess I/O, scheduling, cancellation and timeouts remain enabled.
The old 10 ms interval can be selected with `+RTS -V0.01 -RTS`. `-V0` was useful
for diagnosis, but is not the shipped default. The setting applies to the shared
`fpr` executable, including native compiler invocations, not only Sol.

On macOS arm64/GHC 9.8.2, a minimal threaded Haskell program and `fpr --version`
reported approximately 1 ms INIT and 14 ms EXIT in separate RTS samples. Thus
much of the apparent startup floor was process shutdown waiting on the runtime
timer. This does not mean first output takes that entire interval. The executable
lists four direct dynamic dependencies (libSystem, libiconv, libffi, libcharset);
these measurements do not attribute the latency to a large dynamic-library set.

`FPRISC.hs` and `Sol/Bytecode.hs` now opt into `-O2`, alongside the already
optimized `Sol/Cache.hs`. Their generic Binary/NFData instances otherwise remained
unoptimized despite an optimized cache caller. Module-wide optimization also
improves the shared parser/lowering and bytecode compiler: this is broader than
serialization alone. Other development modules retain `-O0`. Cache schema,
checksums, exact key validation, eager forcing and transaction semantics are
unchanged. Executable identity automatically invalidates artifacts on rebuild.

`make fpr` now depends on Makefile and fp-risc.cabal so build-option changes
trigger its recipe. The end-to-end benchmark clears inherited GHCRTS and accepts
`--rts-tick 0.001` to compare both binaries with the same timer setting.

### Measurements

Comparison against commit `8b88c79`: one warmup and nine shuffled fresh-process
samples per workload/mode, warm filesystem, isolated caches, JIT/GPU/table off.
Wall measurements are uninstrumented; phase samples are separate. Binary hashes
and raw samples are recorded in the JSON report.

| Workload | Previous warm | New warm | Previous miss | New miss |
| --- | ---: | ---: | ---: | ---: |
| hello | 20.37 ms | 11.33 ms | 65.52 ms | 35.53 ms |
| imports | 20.31 ms | 18.92 ms | 109.60 ms | 56.76 ms |
| read_65536 | 20.52 ms | 16.06 ms | 65.42 ms | 38.74 ms |
| read_262144 | 35.62 ms | 33.97 ms | 90.58 ms | 55.35 ms |
| read_1048576 | 110.93 ms | 107.35 ms | 149.80 ms | 129.55 ms |

Warm hello improves about 44%; the three-library warm import case about 7%.
Misses improve about 46% for hello and 48% for imports. The 1 MiB transactional
read is essentially unchanged; this increment targets startup and compilation.
Separate phase samples show cache-read falling from 5.576 to 4.492 ms (hello)
and 11.668 to 9.386 ms (imports), roughly 20%. These are individual phase samples,
not median wall-time attribution.

A second comparison (five shuffled samples) fixes both binaries at 1 ms:
warm hello 12.83 to 11.36 ms; warm imports 20.54 to 18.86 ms;
miss hello 58.35 to 35.62 ms; miss imports 98.72 to 56.61 ms.
This confirms compiler/cache gains independently of the timer change. The same
comparison's warm 1 MiB read varied from 102.40 to 106.77 ms; no general execution
throughput improvement is claimed.

A same-binary timer experiment (nine shuffled samples) measured:

| Workload | 10 ms timer | New 1 ms timer |
| --- | ---: | ---: |
| `fpr --version`, wall | 18.05 ms | 6.59 ms |
| 5,000 iterations of a 64-add VM function, wall | 140.38 ms | 137.90 ms |
| Same VM workload, child user + system CPU | 135.84 ms | 135.85 ms |

The timer retains user override support. More frequent ticks may affect power
or other workloads; this short CPU check is not a battery/power study. Results
are local macOS arm64, not verified Linux/Windows performance. A persistent
`sol >` would amortize process initialization/shutdown, while module resolution,
source validation and cache decoding would still have their own costs.

### Validation

Built with `make fpr`. Passed 52 startup checks plus assembly/concurrent-writer
and executable-identity coverage; parsed-cache corruption/invalidation and
exact-byte transaction conflicts; 26 output checks; transaction, structured
process/Git, filesystem/actor suites; and 34 text/process checks including
backpressure, timeout, cancellation and real PTY foreground restoration.
`cabal exec -- runghc -icompiler tests/CaseGrowth.hs` passed the 4–64 arm growth
check (190–2,290 Core nodes). Direct runghc first failed to resolve Megaparsec;
Cabal supplies the dependency environment. The growth harness is interpreted;
the CLI suites exercise the rebuilt optimized frontend.

Reproduce comparisons with:

```sh
python3 tools/sol-e2e-benchmark.py --baseline /path/to/saved/fpr --runs 9 --output /tmp/sol-runtime.json
python3 tools/sol-e2e-benchmark.py --baseline /path/to/saved/fpr --runs 5 --rts-tick 0.001 --output /tmp/sol-same-timer.json
```


## 2026-09-29 20:24 AEST — Item 6 library audit and shell roadmap

### Scope and evidence

Item 6 is “Packaging and everyday library coverage.” This audit covers the
14 modules in `sol/lib`, selected shared `std/*.fpr` modules, the injected
prelude, VM/HAL, transaction implementation, entrypoint, and representative
scripts. The target is a dependable scripting library and a POSIX-first `sol >`
shell. This is a proposed roadmap, not an instruction to implement every item
now or a claim that existing examples constitute a supported standard library.

Audited source: `e3b1c58`. Fresh macOS arm64 probes used the rebuilt binary with
normal type/safety checking, interpreter execution, and a temporary cache.
The report contains 44 probes: 30 import checks, 13 selected behavior probes,
and one existing script check. Import success establishes compilation only.
No network, interactive shell, scientific backend, or comprehensive library
conformance suite was executed. Historical QRepo experience prompted checking
shared digest/OS compatibility again; current findings below are from live source
and fresh probes, not old performance claims.

### What exists today

| Area | Current implementation | Audit result and boundary |
| --- | --- | --- |
| Small helpers | `sol/lib/base.sol` | Import fails: `removeAt` case lacks an explicit Nil arm under the current checker. Guard reasoning does not establish exhaustiveness. |
| Processes | `sol/lib/proc.sol`, prelude `Proc.*`, `Sol/Txn.hs` | Builders and captured/deferred/immediate/live/inherited execution exist. Prior process suites cover cancellation/backpressure/PTY foreground handoff. No Sol-visible pipeline graph, owned spawn/wait handle, or shell job table. |
| Git | `sol/lib/git.sol` | Imports; structured process wrappers exist. Import probe did not execute Git operations. Keep as an optional integration, not the foundation of the shell. |
| JSON | `sol/lib/json.sol` | Imports and useful accessors exist; acceptance/escaping and representation gaps confirmed below. |
| CSV | `sol/lib/csv.sol` | Imports and quoted-field parsing exist; lossy round trips confirmed below. Whole input and rows are retained. |
| Fixed point / random | `sol/lib/fix.sol`, `rand.sol` | Both import. Fixed-point helpers and deterministic LCG are useful specialized tools; no fresh numerical-accuracy or randomness tests here. |
| Matrices / plots | `sol/lib/matrix.sol`, `plot.sol` | Both blocked at import by `base.removeAt`. Matrix uses Vec; plotting emits SVG/SMIL. Matrix CSV helpers split lines/commas independently of the actual CSV parser. |
| Logic / parser | `sol/lib/logic.sol`, `plparse.sol` | Both fail checking, including nonexhaustive cases. Specialized libraries rather than shell essentials. |
| UI / web | `sol/lib/ui.sol`, `web.sol`, `auth.sol` | UI and explicitly legacy web vocabulary import. Auth fails nested `ui.Style.*` resolution. Its source is a demonstration account flow, not a supported authentication contract. Keep separate from shell core. |
| Collections | Prelude List plus `std/map.fpr`, `std/set.fpr`, `std/list.fpr` | Shared Map/Set import and basic insert/ordered entries/membership work. Reuse these implementations. Scaling and full behavioral coverage remain to establish. |
| Paths | `std/path.fpr` | Imports; `/a/../b` normalizes to `/b`. Reuse pure lexical path functions, distinguishing normalization from filesystem canonicalization and symlink resolution. |
| Directories | Sol `ls`/`exists`/`isDir`/`stat`; shared `std/dir.fpr` | Sol has transactional primitives. Shared Dir imports but `Dir.list` panics on missing `Os.listDir`. An adapter is required, not a duplicate traversal implementation by default. |
| Shared process API | `std/proc.fpr` | Imports but `run ["/usr/bin/true"]` panics on missing `Os.run`. Different result/env/effect contracts from Sol Proc must be reconciled explicitly. |
| Binary/encoding/digest | `std/encoding.fpr`, `std/digest.fpr`; Sol BStr | Encoding/digest imports fail on bit primitives and native dependencies. BStr is a linear UTF-8 text buffer, not a general arbitrary-byte file/process API. |
| Streams / files / HTTP / terminal / clock / config | Shared `std/stream`, `file`, `http`, `term`, `clock`, `config` | All fail the selected import probes on missing hosted primitives or transitive dependencies. Existing native implementations are reuse candidates, not working Sol APIs. |
| Runner / interactive session | `compiler/Sol/Main.hs`, Makefile `sol` target | File-based `fpr sol` dispatch; no persistent no-argument REPL. Make target reports the subcommand. No standalone Sol installation contract established by this audit. |

Overall, **8 of 14 Sol libraries import successfully; 6 fail**. Of the 16 selected
shared modules, 8 import successfully; two of those fail the basic runtime call
probes. These fractions measure this probe set, not percentage completeness.

### Concrete correctness and performance gaps

1. **JSON accepts and produces invalid forms.** Fresh `sol/lib/json` probes accept
   the unknown escape `"\q"` as `q`, and the number `01` as 1. Rendering a String
   containing code point 1 emits the raw control character. Source also decodes
   individual `\uXXXX` units without combining surrogate pairs. Define number
   fidelity, duplicate-key behavior, limits, and exact error locations before
   declaring the API stable.
2. **Two JSON implementations cannot simply be substituted.** Shared `std/json`
   rejects an unknown escape and has a richer number/value model, but in Sol its
   escaped `\u03bb` becomes `Î»`, while literal `λ` stays `λ`. Its UTF-8 byte
   construction assumes the native String contract. Reconcile the encoding layer
   before choosing a shared implementation and a compatibility adapter for the
   existing `JNum/JObj` interface.
3. **CSV round trips lose data.** `parse(render([["a\rb"]]))` produces `[["ab"]]`;
   a single empty field row becomes no rows. Define empty document vs empty field,
   CR/LF preservation, quoting, post-quote syntax, duplicate headers, and ragged-row
   policy. `records` currently zips headers/fields and can silently truncate.
4. **Filesystem metadata operations can read entire files.** `txExists` and
   `txStat` call `snapshot`; traversal must not inherit whole-content reads for
   every stat. Separate metadata observations from content dependencies with
   explicit validation guarantees. Current `mv` is text read/write/delete, not a
   binary-safe filesystem rename. `ls` treats missing directories as empty.
5. **Text and collection building still have expensive paths.** JSON/CSV append
   growing Strings character by character; prelude `collect` appends singleton
   results; `List.find` filters before selecting the first result. Existing BStr
   should be benchmarked for the intended operation, not assumed to solve every
   builder/indexing cost. Standardize linear-time accumulation and early stopping.
6. **Shell I/O is incomplete.** `input` snapshots all stdin; realtime line input
   returns the same empty String for EOF and an empty line. `print` adds a newline.
   There is no cohesive hosted raw stdout/stderr, binary stream, environment,
   current-directory, arbitrary exit-status, and terminal API. Do not implement
   stderr by transactional writes to `/dev/stderr`.
7. **Examples are not release gates yet.** `version-compare.sol 2.10 2.9` freshly
   fails the exhaustiveness check. `sol/scripts/text/shell.sol` interpolates an
   argument into `sh "ls -l {dir}"` and parses display columns; it mishandles shell
   metacharacters and filenames with spaces. Replace it with structured directory
   metadata, or clearly keep it as an explicit shell-interpretation example.
   Regex/grep/awk/sort scripts are useful seeds, not maintained library contracts.

Source anchors: `compiler/Sol/Preamble.hs`, `VM.hs`, `Val.hs`, `Txn.hs`, `Main.hs`,
`Mod.hs`; `sol/lib/{base,json,csv,proc,matrix,auth}.sol`;
`std/{path,map,set,json,encoding,digest,os,osfs,proc,dir,stream,term}.fpr`.

Format acceptance references: [RFC 8259, JSON numbers and strings](https://www.rfc-editor.org/rfc/rfc8259.html#section-6) and [RFC 4180, common CSV quoting and record rules](https://www.rfc-editor.org/rfc/rfc4180.html#section-2). CSV dialect choices should be documented explicitly; these references do not substitute for round-trip tests.

### Proposed public library design

Keep **one documented public module per responsibility**, with shared pure code
and profile-specific host adapters. The names below are proposed API areas, not
new files that already exist. Avoid importing every subsystem into the prelude;
keep heavy libraries explicit and startup-sensitive.

| Layer | Proposed areas | Implementation policy |
| --- | --- | --- |
| Pure core | Result/Option, List, Map, Set, Path, Text, Bytes, Encoding | Reuse checked shared algorithms; make byte/code-point distinctions explicit. Map ordering and equality contracts stay documented. |
| Script host | Env, Cli, IO, Fs, Temp, Clock, Log | Thin typed adapters over the hosted runtime. OS errors remain distinguishable from missing values and EOF. |
| External work | Process, Stream, Terminal, Signal | Host-owned handles, bounded buffering, cancellation and deterministic cleanup. Explicit immediate effects. |
| Formats/integrations | Json, Csv, Digest, Http, Config, Git, Archive | Build on Bytes/Streams/Process. Keep external-tool requirements visible. |
| Interactive shell | Session, completion, history, jobs | Reuse Process/Fs/Terminal; keep parsing and session state separate from the VM evaluator. |
| Optional scientific/UI | Vector/Matrix, Random, Plot, UI | Separate acceptance gates and backend parity; not a prerequisite for a useful shell. |

Recommended foundational contracts:

- Bytes is exact octets; Text is Unicode code points. UTF-8 encode/decode is
  explicit, with strict and explicitly named replacement policies. BStr is not
  silently redefined as Bytes. Decide the non-UTF-8 POSIX filename policy; the
  first release should return an explicit unsupported-encoding error if it cannot
  preserve a name, never silently replace bytes.
- Fallible APIs use structured errors (operation/kind/path or status/context),
  preserving existing String-error wrappers during migration. EOF is an Option
  or explicit end marker. Nonzero child exit is a process result; spawn failure,
  timeout and cancellation remain distinguishable. Provide an explicit checked
  helper for scripts that require status 0.
- File effects say whether they are transactional or immediate. Streams, terminal
  input, network requests and process execution are not silently retryable.
  Scoped handles close on success, failure and cancellation; unbounded captured
  output is never the only process API.
- A pure value pipeline and an OS byte pipeline are different APIs. Require
  explicit encode/decode/line adapters. Preserve argv boundaries; shell parsing
  is an explicit opt-in. Avoid claiming Bash/POSIX-shell syntax compatibility.

### Delivery plan and acceptance gates

#### A. Repair and certify the existing surface — first increment

- [ ] Add a versioned library capability matrix and executable import **and call**
  probes. Mark legacy, experimental, hosted-supported and native-only modules.
- [ ] Repair base exhaustiveness and nested UI-name qualification; enumerate and
  repair or explicitly quarantine remaining logic/parser failures. Do not turn
  off the checker to obtain a green catalog.
- [ ] Add JSON/CSV conformance and round-trip fixtures for the demonstrated failures,
  Unicode, escapes, numeric boundaries, empty rows, multiline fields and headers.
  Decide consolidation with shared JSON through a tested encoding adapter.
- [ ] Make the advertised scripting examples run with default checking and correct
  argv/output behavior; clarify the shell-interpolation example.

Gate: every advertised hosted library compiles and performs a representative call;
known expected failures have explicit ownership/status rather than being hidden.
No malformed JSON emission or silent CSV round-trip loss in the agreed fixtures.
This stage is mostly library/frontend work, not a shell implementation.

#### B. Essential script host APIs and collections

- [ ] Ship documented Map/Set/Path/List entrypoints using existing shared code,
  with basic semantic and scaling tests. Improve accumulate/find/group paths where
  evidence shows quadratic work. Extract reusable CLI option parsing from scripts.
- [ ] Provide Env lookup/missing/unset semantics, script args, session cwd, exit
  status, exact stdout/stderr writes, and EOF-aware line input. Keep a minimal
  `sol` launcher contract in view so applications do not hardcode repo paths.
- [ ] Add metadata-only Fs stat/lstat, symlink policy, sorted traversal, walk limits,
  path errors, temp files/directories with scoped cleanup, rename/copy/remove
  semantics, and glob rules (dotfiles, unmatched patterns, recursive traversal).
  Prevent symlink cycles and accidental whole-file metadata scans.

Gate: a directory inventory and CLI filter work outside the checkout, preserve
spaces/newlines in names, distinguish missing/denied/empty, and do not reread every
file's contents merely to enumerate metadata. CLI prints data to stdout, diagnostics
to stderr, and returns a selected status. Cross-device rename behavior is explicit.

#### C. Bytes, bounded streams and reliable formats

- [ ] Add immutable Bytes and explicit UTF-8 conversions; reuse a validated builder
  for text. Add bounded chunk reads/writes, stream folds and line framing with
  incremental decoding across chunk boundaries. Use scoped resource ownership.
- [ ] Define a transaction policy for streamed file reads: bounded immediate scans
  first, with explicitly designed validation/spooling if replayable transactional
  streams are later required. Do not retain every chunk as an accidental snapshot.
- [ ] Implement binary-safe copy and hex/base64; repair/port digest support with
  streamed SHA-256. Decide a host-backed digest implementation versus reuse using
  measured throughput and correctness, not availability of an import alone.
- [ ] Finish JSON/CSV streaming interfaces, parser limits, and deterministic output.
  Treat record-at-a-time formats separately from whole-document parsers.

Gate: all 256 byte values round-trip, split UTF-8 sequences decode correctly,
blank lines differ from EOF, standard digest vectors pass, and a 100 MiB streaming
copy/filter has memory bounded by configured buffers rather than total input.
Disk snapshot semantics must not be silently weakened to meet the memory gate.

#### D. Structured pipelines and process lifetime

- [ ] Extend existing raw-argv ProcessSpec with explicit stdin/stdout/stderr sources
  and sinks, capture limits, environment removal, and executable lookup rules.
- [ ] Add pipeline construction, per-stage statuses and pipefail policy; concurrent
  draining, kernel backpressure, early consumer exit, timeout and cancellation.
- [ ] Add owned process/job handles with wait/poll/terminate and one cleanup path.
  Separate file redirection performed by a child from Sol transactional writes.
  Offer an explicit staging/publish mechanism if atomic final-output publication
  is desired; arbitrary child effects cannot be rolled back.

Gate: a multi-stage binary pipeline exceeding pipe buffers does not deadlock;
early consumers and Ctrl-C leave no owned children, zombies or leaked descriptors.
Empty/quoted/metacharacter argv values survive unchanged. Failure of any stage is
inspectable. Prior capture/live/PTY tests remain green.

#### E. Minimal persistent `sol >`, then shell polish

- [ ] Refactor load/compile/evaluate into a reusable session interface. Separate
  persistent definitions/module cache/cwd/env/last-status from per-command TxState.
- [ ] Add multiline input, expression display only in interactive mode, type/help
  inspection, error recovery, reload, and explicit process invocation.
- [ ] One command owns its transaction and temporary resources. Publish persistent
  bindings only after successful evaluation/commit. Classify immediate effects
  before execution; refuse an unsafe automatic replay or require an explicit
  effect boundary. A command is not magically atomic because it was typed once.
- [ ] Then add editing/history/completion, resize handling and terminal restoration.
  Job control is a later gate: jobs/fg/bg, process groups, stop/continue signals,
  terminal foreground ownership and cleanup on shell exit. PTY allocation is a
  separate capability from existing inherited-terminal support.

Gate: failed commands leave the prompt usable; cwd/env changes affect later
commands intentionally; no whole-session transaction accumulates. A forced conflict
cannot silently replay an interactive external command. Ctrl-C cancels foreground
work and returns to the prompt; EOF exits cleanly. Measure prompt-ready and
per-command latency separately from fresh-process startup.

#### F. Distribution, integration and optional scientific coverage

Start the runner design during B; certify distribution alongside E rather than
waiting for every optional library.

- [ ] Ship a versioned `sol` command, help/version/script args and tested shebang
  forms; resolve bundled libraries independently of cwd and source checkout.
  Installation should work offline from the release bundle.
- [ ] Separate disposable local cache from deployable artifacts. Existing cache
  files contain compiler identity and are **not** a portable bytecode ABI. Decide
  whether v1 distributes source plus runner first; add deployable bytecode only
  with format/VM version, validation, target-feature and compatibility contracts.
- [ ] Define module names/search order, pin/lock behavior, explicit upgrades,
  reproducibility, offline resolution and cache retention. Resolve local shadowing
  predictably. A package registry is not required for the first release.
- [ ] Add HTTP with deadlines, bounded/streamed bodies, header/status handling,
  certificate validation and explicit redirect policy. A documented external-tool
  adapter can be an interim bridge, not an invisible claim of a built-in client.
  Build Config/Git/Archive conveniences on the stable lower layers.
- [ ] Restore Matrix/Plot imports; compare interpreter/native numerical results,
  dimensions and resource ownership, deterministic PRNG, SVG escaping/output, and
  larger-array throughput. Defer broad scientific/Python interoperability until
  these foundations and realistic workloads have acceptance evidence.

Gate: installed scripts run from an unrelated directory with no compiler checkout;
missing dependencies and incompatible artifacts fail clearly. HTTP fixtures cover
redirect/error/timeout/TLS handling; no live service is required for core CI.

### Recommended first implementation slice

**A: library compatibility and JSON/CSV correctness**, then **B: script host APIs
and metadata-safe filesystem traversal**. Reuse Map/Set/Path now; avoid spending a
milestone reimplementing collections that already work. Bytes/Streams is the
shared dependency for robust text filters, file copying, hashing, pipelines and
HTTP. Build the first persistent prompt on these explicit effect/resource rules,
then add jobs and terminal polish.

Maintain acceptance examples for: recursive inventory; UTF-8/CSV-to-JSON transform;
binary copy plus digest; bounded log filtering; raw-argv process pipeline; and a
session that survives failure/cancellation. Record exact bytes/status and memory
scaling, not only successful compilation or attractive demos. Full native/hosted
parity is a per-module decision, not a prerequisite for every Sol-specific feature.


## 2026-09-29 20:43 AEST — Stage 1 library compatibility and format correctness

### Delivered

Stage 1 repairs the advertised hosted library surface and adds executable
contracts without disabling type or safety checking. `tools/sol-library-check.py`
contains 110 checks, including five explicit compatibility-gap checks.
`tools/sol-library-capabilities.json` is the version-1 capability catalog: hosted,
experimental, legacy and native-only are distinct states, with the required gate
and limitations recorded per module. Adding a Sol library requires updating the
catalog and representative-call fixtures.

- `base`, `logic` and `plparse` now use explicit exhaustive list cases. Matrix and
  Plot imports recover through Base. Empty parser input gets a named error.
- Module renaming now recognizes the longest declared struct prefix, including
  `ui.Style`, instead of inspecting only the first dotted segment. Prefixes are
  computed once per module. Renaming remains restricted to actual declared
  structs; ordinary canonical cross-module references retain their identity.
  Nested and diamond imports are checked in both orders, warm/disabled caches,
  and with the JIT enabled as well as the interpreter.
- The version-compare example now parenthesizes its nested case, keeping the
  outer argument fallback at the correct scope. The existing general scripting
  suite passes again.
- `sol/scripts/text/shell.sol` now lists through structured filesystem operations
  and lexical Path joining rather than interpolating argv into `ls -l` and
  parsing columns. A directory containing spaces and a semicolon is tested.
  Current metadata operations still snapshot file contents; Stage 2 addresses
  that separate limitation.

### Library status after repair

| Surface | Result |
| --- | --- |
| 13 standalone `sol/lib` modules | Each imports and executes a representative call with normal checking |
| `auth` | Experimental app helper: works with a concrete caller record containing user/pendu/pendp/note; standalone import remains unsupported by record-update lowering |
| `std/map`, `set`, `path`, `list`, `string` | Representative hosted calls pass; shared implementations retained |
| `std/dir`, `proc`, `digest` | Explicit hosted-gap fixtures remain: unavailable OS or bit primitives |
| `std/json` | Explicitly native-byte-string only until an encoding adapter exists; use `sol/lib/json` for hosted code |
| Other audited OS/stream/HTTP/terminal/config modules | Catalogued native-only; no new hosted support claimed |

The auth source now states its model requirement. This stage does not redesign
its account flow or certify it as a production authentication library. Scientific
and UI modules have representative construction/call coverage, not comprehensive
numerical, browser or GPU certification. The five gap checks verify the documented
unsupported boundaries; they are not successful feature tests.

### JSON contract

The hosted module preserves the existing Json constructors and public
parse/render/accessor API. Parsing now enforces JSON integer/fraction/exponent
syntax, rejects leading zeros and unknown/incomplete escapes, rejects raw control
characters and isolated surrogates, and combines UTF-16 escape pairs into a
Unicode scalar. Numeric overflow to a nonfinite value returns Err; rendering a
nonfinite number or surrogate value fails explicitly instead of emitting invalid
JSON. All control characters are escaped on output.

String parsing accumulates fragments and joins once. Tests compare parsed/rendered
output against Python's JSON reader, including controls 0–31, Unicode, large
integers, fractions/exponents, paired/unpaired surrogates, duplicate keys and
20,000-character fields. Numeric and string error positions are code-point
positions; this is not a new line/column diagnostic framework.

Limits are explicit: decimal/exponent values retain Numeric's inexact precision;
negative zero is not textually preserved; duplicate object keys remain ordered
and `get` selects the first occurrence. Parsing is whole-document, with no
configurable size/depth limit yet. These are not claims of canonical JSON or
lossless decimal-number text preservation.

Consolidation decision: retain the hosted JSON implementation for now. Shared
`std/json.fpr` constructs UTF-8 bytes using native String semantics and produces
incorrect escaped Unicode in Sol. Its source and catalog now say so. A common
implementation requires an explicit byte/code-point adapter and cross-profile
conformance tests; silently substituting it would regress correctness.

### CSV contract and compatibility changes

The dialect accepts comma-separated fields, doubled quotes, and LF/CRLF record
separators. Quoted CR/LF and Unicode are preserved. Empty input yields no rows;
a blank line is one empty field; a final separator newline does not invent an
extra row. Bare CR outside quotes, embedded quotes in unquoted fields, and text
or whitespace after a closing quote return Err. Field accumulation joins once.

`render` quotes empty fields and fields containing CR, LF, commas or quotes.
A zero-field row has no faithful representation and now errors explicitly.
`recordsChecked` returns a Result and rejects duplicate headers or ragged rows.
The existing `records` shape is retained as its unwrapping convenience wrapper;
malformed tables now fail rather than silently truncating through zip. `table`
still fills missing named columns with empty fields. Independent Python CSV
round-trip checks cover the supported dialect.

These stricter choices intentionally change formerly permissive or lossy input
behavior. Streaming readers, configurable delimiters, dialect options and bounded
memory are later stages, not part of this release.

### Validation and performance

Fresh checks passed on macOS arm64:

- New library suite: 110 checks, including five explicitly catalogued gaps.
- Startup/cache suite: 52 checks plus assembly/concurrent writer/executable identity.
- Parsed-cache corruption and exact-byte transaction conflicts.
- Output contract: 26 checks.
- General scripting, structured process/Git, transactional properties, and
  filesystem/actor safety suites.
- Text/process suite: 34 checks including cancellation, timeout and real PTY use.

The final prefix-hoisting rebuild reran the library suite; the broader suites
passed before that behavior-preserving refactor. No native platform or browser
coverage is implied.

A separate same-binary comparison loaded old JSON/CSV sources from `4d4b1ab`
versus the new libraries, with warm caches, JIT/GPU/table disabled, one warmup and
five shuffled fresh-process samples. Binary/library hashes and raw samples are
in the saved benchmark report. This benchmark predates the final compiler-only
prefix-hoisting refactor; the format-library hashes are unchanged.

| Workload | Old library | New library | Effect |
| --- | ---: | ---: | --- |
| JSON array of 1,600 numbers | 173.19 ms | 210.46 ms | 22% slower from stricter validation |
| JSON string, 16,000 characters | 1,250.05 ms | 327.48 ms | 3.8× faster |
| CSV field, 16,000 characters | 1,269.21 ms | 215.94 ms | 5.9× faster |

Correctness is the gate for Stage 1. Number parsing remains an optimization
candidate; this is not an across-the-board speedup. Metadata-safe filesystem and
script-host APIs are the next stage; Bytes/Streams remain the later shared
foundation for pipelines, hashing and network clients.

Reproduce acceptance with `make fpr`, `python3 tools/sol-library-check.py`, and
`sh tools/sol-scripts-check.sh`; use the existing focused runtime suites when
changing the VM or module pipeline.

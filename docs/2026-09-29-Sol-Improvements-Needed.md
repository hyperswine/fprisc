# Sol Improvements Needed

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

## 1. Performance: measured startup and execution

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

### Startup and large-program compilation

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

### Data processing and library costs

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

## 2. A real REPL and interactive experience

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

## 3. Process, terminal and shell integration

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

## 4. Transactions and external effects need a clear contract

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

## 5. Clean scripting output and errors

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

## 6. Packaging and everyday library coverage

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

## Suggested delivery order

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

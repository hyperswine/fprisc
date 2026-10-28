# Sol: dependable daily scripting

Date: 2026-10-27.
Kind: implementation plan with a verification baseline.
Scope: Sol / HostedBytecode (`fpr sol`) for daily file, text, data and process
automation on POSIX hosts.
Source baseline: `e6fadfb`; the checkout was clean during the assessment.
Status: proposed work, not an implementation or a claim of release readiness.

## Outcome and scope

Make Sol a dependable choice for the maintenance scripts a developer would
otherwise write in Bash or Python: directory inventories, file changes,
JSON/CSV transforms, log filters, checksums, command pipelines and HTTP calls.
Success means predictable failures and resource use as well as correct output.

Keep the existing checked language, structured argv and file transaction model.
Reuse shared pure libraries and add explicit hosted adapters where needed.
Do not disable type, safety or linearity checking to make examples pass.

A persistent REPL, shell syntax compatibility, job control, general process
compensation, a package registry, portable bytecode and broad scientific-library
parity are outside this milestone. A useful installed scripting runner does
not depend on finishing those projects.

This plan follows the [consolidated improvements record](2026-09-29-Sol-Improvements-Needed.md)
and the [delivered deferred-effect contract](2026-10-27-SOL-DEFERRED.md).
It supersedes the delivery order in the older shell-oriented roadmap for this
daily-scripting scope. Earlier records retain their historical meaning.

## Verified starting point

The assessment used the current local macOS arm64 executable; `make fpr`
reported it up to date. It did not perform a clean rebuild, hosted CI or Linux
validation. Binary SHA-256:
`d562fa66b0ecfada7f94e238457c497df55bf9e0c3d3f9ac541746b89dfccec4`.

Already delivered, and to be preserved:

- Intentional stdout, separate diagnostics and meaningful failure exits.
- Checked types, safety and linear resource ownership.
- Compiler caching with invalidation/corruption checks.
- Structured process argv, capture/live/inherited I/O and cancellation.
- Stricter hosted JSON/CSV handling and explicit library capability status.
- Transaction conflict handling, redo recovery, deferred result dataflow,
  durable path logs and guarded immediate Git commit compensation.

Fresh local results from the assessment:

| Check | Result |
| --- | --- |
| `tools/sol-output-check.py` | 26 checks passed |
| `tools/sol-library-check.py` | 117 checks passed, including expected unsupported cases |
| `tools/sol-startup-check.py` | 52 checks plus assembly/concurrent-writer checks passed |
| `tools/sol-text-process-check.py` | 34 checks passed |
| `tools/sol-examples-check.py` | 21 checks passed |
| `tools/sol-txn-check.sh` | Passed |
| `tools/sol-safety-check.sh` | Passed |
| `tools/sol-effects-check.py` | Passed, including disposable local Git recovery scenarios |
| `tools/sol-cache-txn-check.py` | Passed |
| `tools/sol-scripts-check.sh` | Stopped at system-report: OS process inventory returned `Operation not permitted` |

The last result is an environment limitation, not evidence that the remaining
script checks passed or that the language regressed. Re-run that workflow on a
host granting the required observation permission; keep its permission-denied
case as a separate expected-error fixture.

Confirmed gaps:

| Gap | Evidence / consequence |
| --- | --- |
| Directory metadata | Direct probes of `exists` and `stat` on an existing directory panic because `snapshot` attempts to read it as a file (`compiler/Sol/Txn.hs`). |
| Missing versus empty | `ls` of a nonexistent directory returns `[]` successfully. |
| Metadata cost | `txExists`/`txStat` take whole-content snapshots for existing files. |
| File moves | Prelude `mv` is text read/write/delete, not a binary-safe filesystem rename. |
| Bounded I/O | Input, captured process results and existing JSON/CSV parsing retain complete inputs/results. Live forwarding is available, but a general owned binary stream/pipeline surface is missing. |
| Retry exposure | Immediate processes/input/output can repeat; a deferred external action can repeat between execution and its durable receipt. Later command failure does not undo committed files. |
| Hosted library gaps | The capability catalog marks shared stream, HTTP, encoding, digest and several OS modules native-only; representative imports are insufficient evidence of support. |

A small hello-script measurement gave medians of approximately 27 ms for warm
Sol cache hits and 59 ms with caching disabled, versus 5 ms for Bash and 20 ms
for Python. These were sequential fresh-process samples, two warmups and ten
measured runs, default JIT and GPU disabled. They are orientation only: raw
samples were captured in the assessment conversation, not committed benchmark
artifacts. Establish a saved baseline before imposing performance thresholds.

## Delivery order

| Phase | Deliverable | Dependencies |
| --- | --- | --- |
| 1 | Predictable metadata, path errors and safe directory traversal | Existing transaction regressions |
| 2 | Exact bytes, bounded streams and script host I/O | Phase 1 path/error contracts |
| 3 | Explicit retry policy and owned command pipelines | Phase 2 streams; existing deferred recovery |
| 4 | Practical data/network libraries | Phase 2; Phase 3 for any external-tool adapters |
| 5 | Installed runner and repeatable daily-workflow gates | Packaging design begins in Phase 1; final acceptance requires Phases 1-4 |

Each phase should land in small reviewable changes: contract and reproducer,
implementation, compatibility migration, then measured acceptance. Check boxes
below remain open until linked implementation and executable evidence exist.

## Phase 1: filesystem correctness first

Implementation owners: `compiler/Sol/Txn.hs`, `VM.hs`, `Preamble.hs`,
`Infer.hs`, plus a focused filesystem suite and public library adapters.

- [ ] Add regression cases for the directory panics and missing-list ambiguity
  before changing the implementation.
- [ ] Define one hosted filesystem result/error model: operation, path and
  distinguishable missing, denied, wrong-kind, symlink-loop and other OS errors.
  Add fallible entrypoints; retain convenience wrappers that fail clearly.
- [ ] Separate metadata observations from content snapshots. `exists` checks
  existence without opening the file; stat/lstat expose file kind and link
  policy. Distinguish a dangling link from a missing directory entry.
- [ ] Make directory listing distinguish missing/denied/wrong-kind from an
  empty directory. Preserve sorted results and the transaction's own pending
  mkdir/write/remove view.
- [ ] Specify metadata validation separately from exact-byte content validation.
  Record/recheck the metadata fields actually promised, under the existing lock
  protocol; do not claim content equality from size/mtime. Content reads retain
  exact-byte validation. Document concurrent non-Sol writers and TOCTOU limits.
- [ ] Add bounded recursive walking with explicit depth/entry limits, a default
  of not following directory symlinks, an opt-in cycle-safe follow policy and
  documented non-UTF-8 filename behavior. Unsupported names must fail explicitly
  rather than be silently replaced.
- [ ] Define safe temp-file/directory ownership and cleanup. Specify replacement,
  permission, symlink and cross-device behavior for later copy/rename APIs.
  Preserve current executable-mode handling and symlink-write refusal.

Acceptance gate:

- A directory inventory handles empty/missing/denied paths, directories, files,
  dangling links, link cycles, spaces, Unicode and newline-containing names.
- Metadata works on a stat-able file whose contents cannot be read. An instrumented
  test proves inventory does not open file contents; a sparse large file does
  not make metadata work scale with its content size.
- Mutation-between-observation-and-commit cases exercise the declared metadata
  dependencies, while exact-byte conflict and recovery suites remain green.

First implementation slice: fix `exists`/`stat` on directories and missing `ls`,
with focused regressions. Review the transaction dependency model before
expanding this into recursive traversal or changing snapshot storage.

## Phase 2: bytes, bounded streams and script I/O

Implementation owners: hosted values, inference/linearity, VM/host adapters,
`sol/lib` interfaces and a new binary/stream acceptance suite.

- [ ] Add immutable Bytes with explicit UTF-8 encode/decode. Keep existing String
  and BStr meanings; provide strict decoding and separately named replacement
  decoding. Test all 256 octets, NUL and malformed UTF-8.
- [ ] Add owned/scoped chunk readers and writers with caller-visible buffer
  limits, cleanup on success/error/cancellation, and a distinct EOF result.
  Incremental decoding must retain partial code points between chunks.
- [ ] Separate streaming immediate scans from transactional snapshot reads.
  Immediate scans declare that they are not a stable snapshot. Any replayable
  transactional stream needs explicit spooling/admission and recovery rules;
  do not retain every chunk while advertising bounded memory.
- [ ] Add exact byte/text writes to stdout/stderr, EOF-aware line reads, env
  lookup/override/removal, cwd inspection, and deliberate script exit status.
  Specify cwd relative to invocation versus script/module location. Define how
  requested exit interacts with commit/abort and later deferred failure; an
  explicit status must not mask failed effects. Keep `print` as newline output.
- [ ] Provide binary copy and an explicitly immediate same-filesystem rename
  with clear cross-device failure. Offer copy-then-publish as a separate operation
  with its own overwrite and cleanup contract.
- [ ] Migrate examples away from the current text-only `mv`. Do not silently
  turn a buffered transactional helper into an immediate rename; deprecate or
  version the old spelling with a documented migration. Transactional binary
  publication requires staged payload durability, replay and orphan cleanup.

Acceptance gate:

- Binary copy round-trips all byte values, preserves exact output, and has
  deterministic failure behavior for existing destinations and interruptions.
- Empty lines differ from EOF; split UTF-8 sequences and malformed sequences
  follow the selected policy. stdout/stderr and requested status are checked
  independently, including abort and deferred-failure paths.
- A streaming copy and log filter process 100 MiB and 1 GiB fixtures with fixed
  buffers. Record peak RSS; after subtracting an equivalent idle-runner baseline,
  the 1 GiB case may add at most 32 MiB over the 100 MiB case. Record the measuring
  method and investigate failures rather than increasing the allowance silently.
- Repeated failure/cancellation leaves no owned descriptors, live actors,
  temporary files or untracked staged payloads.

## Phase 3: external effects and process pipelines

Implementation owners: `Main.hs`, `Txn.hs`, `Effects.hs`, `VM.hs`, process
library/reference, and the existing effects/text-process regression harnesses.

- [ ] Publish a short operation table: when it runs, what can repeat, what can
  be rolled back/recovered, and what exit failure means after partial success.
  Cover print/input, direct queries, live commands, deferred commands, path logs,
  child modules and the bounded Git inverse separately.
- [ ] Add an explicit execution policy that refuses automatic whole-script replay
  after an unrepeatable immediate effect starts. In that policy, a later conflict
  reports partial external execution and fails; it does not rerun the command.
  Preserve the existing retry policy as an explicit compatibility mode during
  migration. Settle the public spelling and future default in a decision record.
- [ ] Treat arbitrary `Proc.query` executables as external work: the name is not
  proof of read-only behavior. Require an explicit replayability/idempotency
  choice to repeat them in the stricter policy. Distinguish this choice from
  validation of their output, which is not currently a transaction dependency.
- [ ] Keep `Proc.later`/SOLJ2 recovery and its at-least-once window explicit.
  Do not promise exactly-once remote effects or general process compensation.
- [ ] Add byte-stream process sources/sinks and bounded stdout/stderr capture.
  Overflow must return a distinct failure and clean up owned processes; no
  silent truncation or unlimited growth. Define bounded result storage and
  durable receipt/spool cleanup for deferred captures as well as live captures.
- [ ] Add owned pipeline execution with per-stage statuses and an explicit
  aggregate failure policy, concurrent drain/backpressure, timeout, cancellation
  and deterministic reaping. Preserve raw argv and make shell parsing opt-in.
- [ ] Define file redirection and staging/publication separately from buffered
  Sol writes. Retain the current ordering fence unless an explicit boundary
  settles pending work. Preserve foreground terminal restoration.

Acceptance gate:

- A forced conflict after a side-effect counter runs executes it once in the
  stricter policy, exits nonzero and reports the conflict/partial execution.
  The explicit legacy policy retains its documented retry behavior.
- Failed deferred work names the failed/skipped steps and any committed files;
  crash/retry tests preserve saved producer results and failure fences.
- A binary pipeline exceeds pipe-buffer capacity, drains both channels, handles
  an early consumer exit, and exposes every stage's status without deadlock.
- Capture overflow, Ctrl-C and timeout clean up owned children and descendants
  within the documented process-group boundary. Detached sessions remain outside
  that guarantee; test terminal restoration and repeated descriptor use.

## Phase 4: everyday library coverage

Implementation owners: `sol/lib`, reusable pure `std` modules, hosted adapters,
`tools/sol-library-capabilities.json` and executable call/contract probes.

- [ ] Keep one public entrypoint per responsibility. Reuse working Map/Set/Path
  algorithms; update the catalog with supported operations, limits, dependencies
  and actual call coverage. Do not mark an entire native module hosted-supported
  after implementing one adapter.
- [ ] Add hex/base64 and streamed SHA-256 on Bytes. Choose shared algorithms or
  host-backed digest operations after correctness and measured throughput checks;
  native digest vectorization alone does not establish Sol support.
- [ ] Add configurable input/depth/record/field limits to JSON/CSV and document
  numeric precision, duplicate keys and Unicode semantics. Provide record-at-a-
  time CSV and JSON Lines workflows; whole-document JSON can remain a separate
  bounded operation. General incremental JSON is not required for this milestone.
- [ ] Add CLI option parsing and a documented configuration workflow using a
  supported format, explicit environment overrides and useful errors. Additional
  formats can follow actual demand.
- [ ] Add HTTP with deadlines, response/body limits, status/header access,
  validated TLS, redirect limits/policy and streamed bodies. Prefer a hosted
  adapter; any interim external-tool adapter must name and check its dependency.
  Requests follow Phase 3's immediate-effect/retry contract.

Acceptance gate:

- Standard digest/encoding vectors, malformed-input cases and chunk-boundary
  cases pass independently checked fixtures.
- CSV-to-JSON and JSON Lines filters preserve supported Unicode/field semantics;
  configured limits fail clearly without partial destination publication.
- Local HTTP fixtures cover success, non-2xx, redirects, timeout, oversized and
  chunked bodies, invalid certificates and cancellation. Core checks need no
  public service, account or live credentials.
- Every advertised hosted capability has import-and-call plus relevant failure
  tests; expected unsupported fixtures remain separately reported.

## Phase 5: installation and daily-workflow release gate

Implementation owners: runner/Makefile/install tooling, module/home resolution,
cache/journal placement, documentation and test registry/CI configuration.

- [ ] Ship a versioned source-plus-runner bundle with `sol` launch/help/version,
  script arguments and supported shebang forms. Resolve bundled libraries from
  installation metadata, independent of cwd and the compiler source checkout.
- [ ] Put caches and per-run recovery state in documented writable locations.
  Installed scripts may be read-only. Preserve dead-owner recovery from another
  script/cwd and provide an inspect/repair path for retained recovery fences.
- [ ] Define supported host/dependency versions, offline library availability,
  module search/shadowing/pinning, cache cleanup and API migration policy.
  Existing local compiler cache files are not a portable distribution format.
- [ ] Create a daily-scripting acceptance suite and register it with the shared
  Base/CI registry where appropriate. Use isolated temporary directories and
  disposable local repositories, bounded timeouts and exact outputs/statuses.
- [ ] Run it on macOS arm64 and Linux x86-64 for the claimed initial support
  matrix; leave untested hosts explicitly unverified. Report missing environment
  permissions separately from source/test failures.

Required workflows:

| Workflow | Required evidence |
| --- | --- |
| Recursive inventory | Metadata-only traversal; missing/denied/link/name cases |
| Config update | Explicit schema errors, mode preservation, rollback/conflict/crash behavior |
| CSV/JSON transform | Independent expected data, Unicode/malformed/limit cases |
| Binary copy plus checksum | Exact bytes, standard digest, bounded memory, interrupted publication |
| Large log filter | EOF/line framing, bounded memory, distinct stdout/stderr/status |
| Raw-argv pipeline | Metacharacters/empty arguments, per-stage failure, cancellation/reaping |
| Local HTTP fetch/transform | TLS/deadline/body-limit/error behavior and publication policy |
| Controlled Git automation | Local bare remote, deferred dataflow, retry/crash/foreign-writer cases |
| Installed scheduled-style run | Unrelated cwd, read-only installed scripts, minimal env, writable recovery state |

Measure fresh-process startup with cache disabled/miss/hit separately; benchmark
data throughput and peak memory separately. Save samples, executable identity,
source revision, build settings, host and command lines with release evidence.
The older `tools/sol-benchmark.py` disables caching; do not label its results hits.

## Completion and verification rules

For every implementation change, run the focused checks appropriate to the
changed contract and the affected existing Sol suites listed above. Shared
frontend/inference changes also require relevant native/backend coverage.
Use the repository's Base/CI machinery for broader integration at milestones;
passing local checks does not establish that hosted CI ran.

Every completed phase records its implementation revision, exact check commands,
results, host and remaining limits here or in a linked dated delivery record.
Promote adopted behavior into the authoritative API/semantic references with
test links, and update this plan's checkboxes. Do not rewrite historical
assessments to imply the feature was available earlier.

The daily-scripting milestone is complete when all five phase gates and the
workflow matrix pass on the claimed hosts, installation works outside a source
checkout, remaining exclusions are explicit, and the failure/retry contracts are
usable without reading runtime implementation code. This is the acceptance bar
for recommending Sol as a default daily scripting tool.

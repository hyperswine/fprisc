# Sol Phase 3: guarded retry and owned processes

Kind: decision, API reference and local delivery record. Applies to the working
tree based on `27a4cdc`; includes the uncommitted Phase 2 byte APIs. This advances
[the daily-scripting roadmap](2026-10-27-SOL-DAILY-SCRIPTING-PLAN.md). Linux and
hosted CI evidence are still required by Phase 5.

## Retry decision

`guarded` is the default now. Select `--retry-policy=guarded|legacy` before the
script path, or set `SOL_RETRY_POLICY`; the CLI overrides the environment.
`--` ends runner options. Arguments after the path belong to the script. Invalid
policies fail before running source. Child modules inherit the selected policy.

An attempted immediate external effect marks the attempt before it starts. A
later validation conflict under guarded policy discards buffered file work,
rolls back an armed bounded Git inverse, closes owned resources and exits 1.
The diagnostic names the conflict, the effect classes and possible partial
external execution. There is no whole-script replay in that case. Failed spawn
or I/O does not prove that no external work occurred, so marking is conservative.

`Script.replayable (fn u -> work)` asserts that the caller accepts repetition of
all effects issued by that callback. Scopes nest and are thread-local; they do
not bless effects in another actor. `Proc.queryReplayable spec` is the specific
process convenience. Neither spelling validates command output at commit,
enforces read-only behavior, supplies an idempotency key, or compensates a command.
`legacy` explicitly restores the older whole-script replay behavior. Prefer
transactional `log` for progress that should only appear after a successful run.

| Operation | When it runs | Conflict/repeat contract | Rollback, recovery and failure |
| --- | --- | --- | --- |
| Buffered file writes/removes/mkdirs | Commit, after validation | Safe to discard/rebuild before commit | Redo journal for interrupted file replay; failure names landed files |
| `print`, exact stdout/stderr | Immediately | Guarded conflict stops; replay assertion/legacy may duplicate output | Output survives failure; cannot be retracted |
| `input Unit` | First read snapshots all stdin in this process | Retries reuse the snapshot | Whole-input text API; use bounded streams for large/live input |
| Live stdin/streams, `readNow`, immediate Fs/Env APIs | Immediately | Guarded conflict stops | Streams/scratch swept; Env restored; external writes/publications survive |
| `sh`, `Proc.query` | Immediately, bounded capture | Arbitrary executables mark external work; no output dependency | Process failure is Result (sh insists); external changes survive |
| `shNow`, `Proc.runNow/streamNow/inheritNow`, pipeline/start | Immediately | Guarded conflict stops | Owned groups cleaned on timeout/cancel; immediate work survives failure |
| `shq`, `Proc.afterCommit`, `Proc.later` | Ordered commit replay | Discarded queue before commit; SOLJ2 after commit | Saved failure fences later commands; applied files remain; crash window is at-least-once |
| `log`, `logTo` | After successful ordinary effects | Once per successful committed run | Failed runs withhold logs; path logs save complete post-images for redo |
| `run module value` | Immediate child transaction | Guarded parent conflict stops; child uses selected policy | Child commits are independent; bounded capture; overlap refusal retained |
| Native read-only Git query | Immediately | May replay; no arbitrary executable accepted | Observation is not isolation from foreign Git writers |
| `Git.commitNow` bounded inverse | Immediately | Retry can apply journaled CAS inverse | One inverse, reference compare-and-swap, foreign-head refusal; not general compensation |
| `Git.pushNow` | Immediately | Guarded conflict stops | Remote publication cannot be rolled back |

## Byte pipelines

The public types are preprovided:

```sol
PipeInput = Type (PipeBytes Bytes | PipeFile String | PipeInputInherit).
PipeOutput = Type (PipeCapture Int | PipeFileNew String |
                   PipePublish String Bool | PipeOutputInherit | PipeDiscard).
PipePolicy = Type (PipeLast | PipeFail).
PipelineSpec = Type (PipelineSpec (List (ProcessSpec String))
                      PipeInput PipeOutput PipeOutput Int PipePolicy).
PipelineResult = Type (PipelineResult Int (List Int) Bytes (List Bytes)).
ProcessError = Type (ProcessError String Int String Int).
```

`PipelineSpec stages input stdout stderr deadlineMs policy` connects raw byte
streams. Each stage retains its raw argv, cwd and environment overrides. Its
`ProcessSpec` stdin must be empty and timeout zero: the pipeline owns those
choices. Executables without `/` are found using that stage's effective PATH
and cwd, with `/usr/bin:/bin` if PATH is absent. Empty PATH entries mean cwd.
No shell expansion occurs; use an explicit `/bin/sh -c` stage when intended.
NUL and invalid Unicode argv/env are refused rather than silently truncated.

`Proc.pipeline : PipelineSpec -> Result PipelineResult ProcessError` waits for
the whole pipeline. A nonzero stage is a successful observation of failure:
`Ok (PipelineResult aggregate statuses stdout stderrs)`. Every stage's exit
status is retained in declaration order. `PipeLast` selects the last status;
`PipeFail` selects the rightmost nonzero status, or zero. Signals retain the
host process package's negative signal status. Spawn, capture overflow, timeout,
validation and I/O failures return Err. Error fields identify reason, one-based
stage (zero for a whole-pipeline failure), channel and relevant limit. A timeout
uses its milliseconds in the limit field. There is no silent truncated success.

Each edge has a 64 KiB relay buffer. Concurrent workers drain all stderr pipes,
the final stdout pipe and input while waiting for children. Kernel pipes supply
backpressure; an early consumer closes its upstream read edge and does not
deadlock the producer. Captures admit 0..16 MiB per stream and at most 32 MiB
combined across final stdout plus each stage's stderr. There are 1..16 stages.
Deadline 0 is unlimited; otherwise 1..86,400,000 ms applies to execution/I/O.
Caller-supplied Bytes and retained result values remain caller-owned memory.

`PipeFile` admits a regular non-symlink input. `PipeFileNew` exclusively creates
a direct 0600 destination: partial data remains on failure. `PipePublish path
replace` uses a private same-directory stage and publishes only after aggregate
status zero and successful I/O. No-clobber uses link publication; replacement
requires a regular non-symlink target and preserves existing mode bits. Stage
cleanup runs on error/cancellation/nonzero aggregate. Publication is immediate,
outside Sol file rollback and journal recovery, with no fsync durability promise.
Stderr supports capture, inherit or discard; results retain one Bytes per stage
(empty for uncaptured streams). Non-Sol path replacement races retain POSIX
path-based limits, as with Phase 2 publication.

Starting a pipeline refuses pending buffered effects using the existing ordering
fence. Waiting/cancelling an existing owner remains allowed. `PipeInputInherit`
borrows non-terminal stdin directly; it does not read ahead into the parent.
Terminal input requires `Proc.inheritNow`, whose foreground handoff/restoration
remains covered by the PTY regression suite. This pipeline API allocates no PTY.

## Owned jobs and cancellation

`Proc.start` returns `Result ProcessJob ProcessError`; this acknowledges an owned
worker, not successful spawn of every stage. `ProcessJob` is linear and carries
an unforgeable attempt identity. `Proc.wait` consumes it and returns the same
result as synchronous execution. `Proc.poll` returns `(Result Bool ProcessError,
ProcessJob)`, retaining the owner. `Proc.cancel` consumes it, cancels, joins and
returns `Result Unit ProcessError`. All remaining jobs are swept before commit,
on retry/abort/error and Ctrl-C, including when Script.exit skips syntactic close.

Each stage owns a process group. Cleanup kills those groups with SIGKILL, waits
for direct children and joins I/O workers before closing pipe handles. Pipeline
cleanup also runs after successful completion to remove inherited-group
background descendants. A descendant that deliberately changes process group
or session is outside this guarantee; Sol does not act as a system subreaper.
Ctrl-C retains runner status 130. Explicit job cancel returns after owner cleanup.
Hard process crashes cannot perform language-level cleanup.

## Text compatibility and durable results

`sh`, `shq`, `Proc.query/runNow/afterCommit/later`, and child-module `run` now
capture at most 1 MiB on each stdout/stderr stream. Incremental strict UTF-8
validation cancels malformed text producers immediately, including sleeping
producers that have already closed stdout. Use pipelines for binary results,
configurable bounded captures or file/inherited sinks. `Proc.streamNow` and
`Proc.inheritNow` still forward bytes without capture.

SOLJ1/2 plan decoding and SOLR2 receipt decoding remain compatible within the
new limits. A plan admits at most 4096 external result entries. A completion
admits at most 2 MiB; ordinary captures share 15 MiB total, with 1 MiB reserved
for failure receipts. Exceeding that budget saves a failure, reports that the
external work may already have occurred, and fences consumers. Receipts are
inline rather than unlimited spool files; a read admits at most 192 MiB encoded
receipt bytes and validates a 16 MiB decoded payload budget before reuse.
Receipts are cleared with their journal after normal completion/recovery; retained
fences keep both. The crash window between external execution and durable receipt
remains at-least-once, including calls to a remote service.

## Local verification

macOS arm64, GHC 9.8.2, development `make fpr` (`-O1`, existing module overrides),
GPU disabled. Focused checks:

- `python3 tools/sol-retry-policy-check.py`: 17 checks, real side-effect counter,
  CLI/environment policy, scope boundaries, explicit assertion, output/log and
  deferred behavior. Registered Base job.
- `python3 tools/sol-pipeline-check.py`: 35 checks, binary/raw argv, 16 MiB two-stage
  flow with both channels beyond pipe capacity, early exit, stage/aggregate
  status, capture/UTF-8 failure, cwd/PATH/env, publication modes/fences, job
  ownership, timeout/cancel/Ctrl-C descendants, 40 sequential pipelines under a
  96-descriptor limit. Registered Base job.
- Existing filesystem 103, byte I/O 84, module-cache/transaction, effects/Git
  crash/recovery and transaction suites pass. Historical replay fixtures select
  legacy explicitly; the recovery reader uses transactional log so guarded
  retries remain safe.

The [saved validation report](evidence/2026-10-29-sol-phase3/validation.json)
records the executable SHA-256, all Sol runtime source hashes, build settings,
host, exact commands, output, status and elapsed time. All 16 recorded commands
passed on the final binary: the seven registered Sol Base jobs, text/PTY 34,
output 26, library 117, startup 52, cache/transaction, txn, safety, process/Git,
general scripts, native automation with empty PATH, examples 21, registry 8,
and interpreter-mode byte I/O 84 / pipeline 35 / retry 17.

The registered receipt-budget job independently runs real producers: 14 MiB is
retained, the next 2 MiB becomes a saved failure, the following process is skipped,
queued files commit, and completed receipts are removed. The retry suite also
verifies that a replay assertion in one actor does not bless a spawned actor.

The system-report acceptance requires OS process observation permission; its
restricted run failed with Operation not permitted, and the permitted rerun
passed. Non-UTF-8 APFS filename creation and native EXDEV remain unexercised.
This is local macOS evidence, not full Base, hosted CI, Linux or board evidence.
Colima was installed but stopped during environment discovery; no Linux check
was run. The roadmap goal remains active through Phase 4 libraries and Phase 5
distribution and cross-host workflow gates.


## Later Phase 5 verification (2026-10-29)

The [installation and release record](2026-10-29-SOL-INSTALLATION.md) supersedes
this delivery snapshot's open Linux/installation gate. Its complete daily-workflow
matrix passes on macOS arm64 and an emulated Linux x86-64 Debian trixie guest,
with exact source/executable identities and explicit remaining exclusions.
The older measurements above retain their original executable identity and scope.

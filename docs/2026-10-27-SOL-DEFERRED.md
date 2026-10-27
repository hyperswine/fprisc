# Sol deferred dataflow and guarded Git compensation

Date: 2026-10-27. Implements the closed deferred-plan vocabulary from
[SOL-EFFECTS](2026-09-30-SOL-EFFECTS.md), persistent transactional log
appends, and the first immediate-effect inverse adapter.

## Deferred values

`ProcessSpec a` is now parameterized by its argument type. Existing
unannotated constructor calls with string lists still work. Direct APIs
and the compatibility `Proc.afterCommit` use `ProcessSpec String`;
`Proc.later` uses `ProcessSpec Arg`:

```text
Arg = Lit String | From (Deferred String)
Proc.later : ProcessSpec Arg -> Deferred ProcessResult
Deferred.out : Deferred ProcessResult -> Deferred String
Deferred.trim : Deferred String -> Deferred String
Deferred.line : Int -> Deferred String -> Deferred String
Deferred.field : String -> Int -> Deferred String -> Deferred String
```

Indices are one-based. Field separators must be nonempty. Missing lines
or fields fail the consuming step and fence later external effects.
Deferred handles are opaque VM values scoped to one transaction attempt;
the serialized plan contains only earlier-step references and projection
data. There is no arbitrary deferred `map`, closure, bind or branch.
`Proc.later` forwards stdout/stderr at commit and also captures them for
consumers and recovery. `Proc.afterCommit` keeps its existing Unit result
and stream behavior.

```sol
> producer = Proc.later
    (ProcessSpec [Lit "/usr/bin/printf", Lit " version: v1 \n"] "" [] "" 1000);
  version = Deferred.trim (Deferred.field ":" 2 (Deferred.out producer));
  Proc.later (ProcessSpec [Lit "/usr/bin/printf", Lit "%s", From version] "" [] "" 1000).
```

Both steps execute and forward their streams at commit. A consumer can
use its resolved argv to write a file or call another tool; constructing a
deferred value does not force its process early. For a result needed by ordinary script logic or transactional
file contents, use an appropriate immediate adapter instead.

## Journal and Git piping

New journals use `SOLJ2`. Atomic `SOLR2` completion snapshots retain the
step index, captured process code/stdout/stderr or native result, and
failures. Recovery can resolve dependent argv without rerunning a completed
producer, and a recovered failure still fences its consumers. Legacy
`SOLJ1` plans and integer completion receipts remain readable; those older
receipts do not contain captured results. External
effects retain the existing at-least-once crash window between action and
durable receipt; a later failed external action does not undo committed
files.

New file/Git effects capture absolute paths; deferred processes and shell
commands capture their working directory. Journal identities in lock-owner
records are absolute as well, so another script can recover a dead owner
from a different directory. Lock keys deduplicate aliases, directory
validation recognizes its own protocol artifacts after normalization, and
child-transaction overlap checks use the same file identities. File paths
resolve parent aliases while retaining leaf-symlink policy. The existing
archive member-name interpretation is preserved.

`Git.push` now queues a terminal publication and returns the Repo for
piping. Its former guarded immediate API is named `Git.pushNow` and keeps
its Result. Existing examples/tests of that immediate ordering fence use
the explicit spelling. `Git.headLater` yields a trimmed deferred commit id,
and `Git.tagAt` consumes that id:

```sol
Git = use "sol/lib/git.sol".
> committed = Git.repo "." |> Git.add Git.all |> Git.commit "release";
  sha = Git.headLater committed;
  tagged = Git.tagAt "v1" sha committed;
  Git.push "origin" "main" tagged.
```

Another queued world effect after push is refused. Transactional audit
records may follow publication, since they record its successful outcome.
Tests push only to a disposable local bare repository.

## Path logs and file policy

`logTo path value` buffers a rendered line until successful commit. Its
path joins the transaction's sorted lock set. Under those locks, appended
lines become a complete file post-image in the redo plan. Replaying that
post-image cannot append a line twice. The log runs after ordinary effects
and is withheld after a file or external failure. Concurrent appends
serialize without lost lines; retries and pre-commit panics discard their
pending entries. Like `log`, these are commit-time outputs, not an
intermediate update of the script's file view.

`log` continues to print after a clean live commit. Use `logTo` for durable
records: stdout is not a recoverable audit destination.

File mode preservation and explicit refusal of symlink writes were already
implemented in `writeAtomic`; this work verifies both, including executable
bits. `logTo` also refuses symlinks. Writing through a referent would need
its own lock/snapshot policy and is not the chosen behavior.

## Immediate Git commit with an inverse

`Git.commitNow message repo : Result String String` returns the new commit
id during script execution. It requires an existing attached branch and
already staged changes. This first adapter permits one compensable commit
per attempt and refuses pending queued effects or an earlier immediate
pivot. Immediate pivots are also refused while its inverse is armed;
queue subsequent processes or a terminal push for commit.

Libgit2 prepares an unpublished commit object first. Before publishing its
reference, Sol writes a durable `SOLUNDO1` token with the absolute repository,
captured reference name, old id and new id. Forward publication and undo
both use reference compare-and-swap. Abort and validation retry restore
old only when the reference still names new; an already-restored old value
is harmless. The index and worktree are preserved. A foreign reference
movement refuses compensation and retains the journal/fence for repair.
No relative `HEAD~1` reset is used.

At the file transaction's durable redo point, ownership transfers from
undo to forward recovery. The undo marker is marked committed before the
redo journal can be cleared. An existing redo bridges a crash between the
two durable writes. Recovery after that point finishes the forward plan
rather than reverting the commit. This is compensation, not isolation:
other processes can observe the immediate commit. `Proc.query` remains a
direct query and does not enforce read-only behavior; using it for mutation
is outside this inverse's coverage.

Arbitrary process inverses, multiple compensable commits per attempt and
a general multi-step saga/pivot API remain future work. This adapter is the
concrete Git use case, not a claim that all immediate effects are undoable.

## Focused validation

`tools/sol-effects-check.py`, registered in Base, checks closed projections,
retry discard, saved-result recovery, recovered failure fences, SOLJ1
compatibility, exact/concurrent/idempotent path logs, failed-removal audit
withholding, executable modes and symlinks. Disposable Git tests cover
commit/head/tag/push, crash-recovered Git dataflow, terminal publication,
CAS abort/retry, crashes before/after reference publication and before/after
file-commit completion, and a foreign writer whose head must be preserved.

The existing transaction, structured process/Git, output (26 checks),
safety, exact-byte/cache, text/process (34 checks, including PTY behavior)
and hosted-library (117 checks) suites passed. The text test's old oversized
literal also fails on the saved baseline compiler; it now constructs the
same runtime Integer using `parseInt`, preserving large-index coverage.

## Broad validation

The complete 147-job Base run passed in 785 seconds with four workers.
After the final Sol path-context, stream-forwarding and diagnostic
follow-ups, the relevant registered Sol/stdlib actor checks passed again
(four jobs), as did the transaction, process/Git and output suites, the
general-purpose scripts and the native extbase digest golden output. The
expanded effects regression also passed on the final compiler, including
different-directory and different-script recovery, lock aliases and nested
directory validation. Native compiler/runtime code did not change during
those Sol follow-ups. Hosted CI and physical-board execution were not run.

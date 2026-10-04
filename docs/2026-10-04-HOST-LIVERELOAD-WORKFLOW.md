# Host MVU LiveReload workflow — 2026-10-04

## Intended behavior

A running Base-profile MVU application should stay alive while a developer
commits a compatible new version of an explicitly subscribed module into its
local `.fpr` store. The host builds the committed immutable source closure,
publishes only a complete image, and delivers a typed `EReload` notification.
The runner adopts a rebuilt environment between events while retaining its
model. A failed check, build, attachment or compatibility gate leaves the
current environment and its old function values usable.

Static `use "module#hash"` imports remain frozen. A logical reload subscription
is a deliberate dynamic boundary; it does not rewrite pinned imports or all
functions in the running program. The shared host runner accepts an explicit module/export binding declaration;
compiler-generated environment descriptors are later work.

## Previous gap

`fpr watch module.fpr` watched one scratch file and published its saves. It did
not start a program, inspect dependency commits, or infer reload subscriptions.
`fpr commit module.fpr` wrote checked source and a version binding only. The
runtime watcher read a ready-image publication journal, not `versions.db`.
The original host tests covered publication, notification and MVU adoption in
separate stages, without committing a dependency while that same app ran.

## First implementation

```
fpr commit math.fpr
fpr watch app.fpr --module math
# In another terminal, in the same workspace:
fpr commit math.fpr
```

Repeat `--module NAME` for multiple explicit subscriptions. The supervisor:

1. Publishes each subscription's latest committed source before launching.
2. Builds and starts the app once, supplying `FPR_RELOAD_JOURNAL` in its environment.
3. Polls `versions.db` every 300 ms and builds newly committed subscribed roots.
4. Atomically announces ready images; failed builds retry the committed binding.
5. Exits with the application's status and removes its temporary executable.
6. Stops and reaps its application when interrupted during the running session.

`fpr publish --stored NAME` publishes an existing source binding without reading
or recommitting the mutable scratch file. The frozen root and its closure are
identity-checked before building. Existing `fpr watch module.fpr [--once]`
retains its save-publisher behavior.

The app uses `Watch.session Unit` to get the journal, and
`Watch.latest journal name` to bootstrap a candidate and cursor from the same
snapshot. Commits arriving after that snapshot remain visible to its owned
watcher. It uses `MV.runWatched` with `Watch.watchFrom`, loads the initial image,
and explicitly binds exports into its environment.

The example in `examples/livereload/` checks a candidate against its actual
loaded table/hash rather than blindly using the previous journal row's hash.
Thus an incompatible intermediate publication can be refused without stranding
a later compatible version. Runtime type/contract/ABI and identity checks
remain authoritative. The example retains an old function value to demonstrate
that adopting a new environment does not invalidate it. Create a file named
`stop` in the workspace to quit it normally.

## Acceptance and delivery order

- [x] Continuous host test passes on one and four harts: launch MVU, commit new
  dependency while it runs, observe changed behavior with retained model.
- [x] Invalid commit produces no notification; explicit incompatible major
  publication is refused and the next compatible candidate can be adopted.
- [x] Failed image build is not announced; unchanged committed binding retries.
- [x] Normal exit and interruption stop the supervisor/application cleanly.
- [x] Existing publication and runner-ownership suites remain green.
- [x] Extend the example toward a normal interactive MVU app.
- [x] Define explicit dynamic module/environment bindings and reduce adapter boilerplate.
- [ ] Generate typed export descriptors in the compiler and compose multiple
  dynamic modules into one environment.
- [x] Add an opt-in whole-program restart policy for corresponding app edits, keeping restart
  separate from compatible model-preserving reload.

## Boundaries

Only selected logical module names are observed, in the launch workspace's
local store. Editing an uncommitted scratch dependency has no effect. Root app
edits trigger restart only with `--restart-on-change`. Transitive changes require a newly committed root
with updated pins. Missing subscriptions or an initial build failure refuse
startup. Rapid commits may coalesce to the latest binding; intermediate versions
need not run. Loaded-image reclamation and state migration remain unfinished.

The publication lock serializes publishers; standalone commits retain their
existing single-writer convention. The supervisor reads complete binding rows
and builds immutable blobs, but it does not make concurrent standalone commits
transactional. The journal is host/codegen-specific. Linux execution and QOS
repinning are separate validation steps.

## Verification

Apple Silicon macOS: compiler rebuild succeeded. `tests/check_watch_app.py`
runs the complete store-commit workflow on one and four harts, including an
ordinary compatible commit, refused invalid source, refused explicit major
version, recovery after an intermediate refusal, injected linker failure and
retry, retained accumulator state and an old callable function, and normal exit.
A separate termination case checks the application PID is gone and the temporary
executable is removed. Startup tests refuse missing subscriptions and invalid
app builds without leaving a temporary executable or publication lock. The test is registered in `tests/check_base.py`.

`tests/check_publication.py` and `tests/check_owned_watchers.py` passed again.
The full Base suite subsequently passed for the shared-runner follow-up below.
Linux execution and QOS suites were not rerun for this step.

## Shared runner and interactive follow-up

`std/livereload` centralizes startup, image identity checking, notification
ownership, adoption against the actual loaded baseline, export rebinding and
registry rollback. A declaration is `{name = "math", bind = bindings}` where
`bindings table -> Result env String` constructs the environment the app sees.
`Live.function table name` returns a missing-export error rather than panicking.
`Live.run me cfg app spec` owns the watcher and projects that environment into
normal MVU init/update/view callbacks. `cfg` contains mt/tick/input/render;
the helper supplies its private session environment. Binding callbacks must not
attach or detach registry tables themselves; the runner is the attachment writer.
A callback refusal removes the candidate table and retains the old environment.

The binding callback is still explicit, including the intended function types.
This is not compiler-generated verification of the initial module's exports.
Images and bindings remain trusted native code. The helper currently represents
one dynamic module boundary; a list of declarations and automatic typed export
descriptors are unfinished.

`examples/livereload/interactive.fpr` is a terminal calculator. Type `+` then
Enter to add the currently loaded step, `r` to reset, or `q` to quit. Input uses
readiness polling and one-byte reads instead of blocking for a line, so reload
still works while the user is idle on one hart. The existing automatic accumulator
example also uses the shared runner; its retained old function lives in the model.

```
fpr watch interactive.fpr --module math --restart-on-change
```

The optional flag rebuilds on root source-byte changes. A failed build leaves
the current app running; another edit retries. A successful build is atomically
installed before stopping and reaping the old process and launching the new one.
This is a cold restart: model state resets, and runtime startup of the replacement
is not staged or rolled back. Compatible module publications still use ordinary
model-preserving adoption. An incompatible module publication alone never triggers
a restart; update the app/binding for that new interface to opt into the restart.
Without the flag, root edits remain ignored. Automatic migration is not provided.

`tests/check_live_runner.py` exercises interactive input, reload during input
idle, candidate binding failure and registry rollback, subsequent compatible
adoption without a PID change, invalid root build refusal with the app still
responsive, incompatible publication refusal followed by a corresponding checked
app edit and cold restart, old PID cleanup, and normal quit on one/four harts.
A startup fixture checks missing exports refuse without leaking a registry table.
This suite is registered in Base alongside the earlier continuous store workflow.

Final follow-up verification: the complete `python3 tests/check_base.py` suite
exited successfully on Apple Silicon macOS. This includes both new continuous
host suites, earlier publication/ownership/MVU tests, module interface gates,
typed vector checks, actor admission and runtime stress. Evidence is recorded in
`/tmp/fpr-live-runner-base.log` for this session. Linux execution and QOS repinning
remain separate; this does not certify those targets.

## Real application follow-up

The existing browser POS now has a reloadable pricing module, exercised through
two continuing cashier connections and a real browser UI checkout. Its std/live
subscription adopts at the model writer's event boundary and preserves sessions,
mirrored carts and receipt history. See [POS LiveReload](2026-10-04-POS-LIVERELOAD.md)
for the implemented boundary, tests and browser screenshot.

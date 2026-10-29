# Sol installation and daily-workflow release gate

Kind: delivery and operating guide. Applies to the source changes after
`27a4cdc` identified by the release evidence's source and executable hashes.
Implements Phase 5 of the [daily-scripting roadmap](2026-10-27-SOL-DAILY-SCRIPTING-PLAN.md).
The runner reports `Sol 0.12.0 (scripting API 1)`.

## Build, bundle and install

From the source checkout:

```sh
make fpr
make sol-bundle                         # build/sol-bundle.tar.gz
make sol-install SOL_PREFIX="$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
sol --help
sol --version
sol /absolute/path/to/task.sol argument
```

`tools/sol-install.py --prefix PREFIX --output ARCHIVE` can do both steps.
It requires Python 3 and Git in a checkout, stages the complete version before
activation, and refuses to replace an unrelated `PREFIX/bin/sol`. The installed
command invokes the native runner directly through a relative symlink to a versioned directory under `libexec/sol/`;
activation replaces that link atomically. Old versions remain available for
explicit rollback. A running process keeps the runner and library directory it
started with. Move the entire prefix to relocate an installation.

Each bundle contains the executable, a native runner alias, `core`, `std` and
`sol` libraries, the distributable Git-listed source snapshot, and `manifest.json`.
The manifest records exact source SHA-256 hashes, executable SHA-256, host and
API version; the bundle name includes their combined content identity. Dirty
source is included and identified. Ignored build outputs and caches are excluded.
This is an identity record, not a signed build attestation.

An extracted archive can run directly with `BUNDLE/launch-sol task.sol`.
To install it under a new prefix, run:

```sh
python3 BUNDLE/source/tools/sol-install.py --binary BUNDLE/fpr --prefix PREFIX
```

To roll back, run that installer from the retained older bundle with its own
`fpr` binary and the existing prefix. Activation uses the same atomic link switch.

The shipped source list supports repackaging without Git. To rebuild, copy the
source to a writable directory, install build dependencies, and run `make fpr`.
No GHC, Python, Git executable, shell startup files, source checkout or Internet
connection is required for ordinary installed Sol execution. Scripts that launch
other programs still require those programs. HTTP links libcurl directly.

This is a host-specific dynamically linked bundle. It does not carry system
libraries. Build dependencies are GHC/Cabal, a C compiler and pkg-config, with
`unix >= 2.8`, libgit2 >= 1.9, libarchive >= 3.6 and libcurl >= 8.4 with TLS and
HTTP(S), plus the existing platform graphics dependencies of `fpr`. Runtime
dependencies must remain available at the linked paths (`otool -L fpr` on macOS,
`ldd fpr` on Linux). In particular the macOS build uses Homebrew libgit2 and
libarchive; relocating a bundle does not relocate those libraries.

The initial target matrix is macOS arm64 and Linux x86-64. Tested toolchains are
GHC 9.8.2 on macOS and GHC 9.6.6 on Debian trixie. The Linux environment is an
x86-64 QEMU guest on an arm64 Mac: functional architecture coverage, with
emulated timings. Other hosts, static distribution, Windows and hosted CI are
unverified by these local records. Consult the evidence section for actual
completed checks; a configured CI job is not evidence of a hosted run.

## Arguments, shebangs and scheduled runs

`sol [--asm] [--retry-policy=guarded|legacy] SCRIPT [ARGUMENTS...]` preserves raw
argument boundaries. `sol -- SCRIPT ...` allows a script name beginning with a
hyphen. Runner options precede the script; subsequent options belong to it.
Guarded retry is the default. See the [process contract](2026-10-29-SOL-PROCESS-PHASE3.md)
before selecting legacy replay or marking external work repeatable.

Supported executable-script first lines are `#!/usr/bin/env sol` when the
installation is on PATH, and `#!/absolute/prefix/bin/sol` when that interpreter
path contains no spaces. `#!/absolute/path/to/fpr sol` is also supported.
Use `sol script.sol` for interpreter paths containing spaces. The source parser treats the
shebang as a comment. No shell quoting or expansion is applied to script arguments.

For a scheduler, set an explicit HOME, PATH and writable state/cache locations;
invoke an absolute script path. The script and bundled libraries may be read-only.
Relative file and process paths (`readPath`, `writePath`, `ls`, `exists`,
`Try.*`, `sh`, `Proc.*` with an empty cwd) resolve against the **current working
directory of the process**, exactly like bash or Python, for checkout runs and
installed `sol` alike. They are *not* relative to the script's directory. A
scheduler usually starts in `/` or `$HOME`, so `cd` first or use absolute
paths, and choose absolute output paths when the cwd is read-only. Only `use`
imports resolve relative to the importing source file (see below).
`tools/sol-cwd-check.py` pins this by running a script from a different cwd.
The installation checks use an unrelated working directory and a minimal
environment.

## Libraries, shadowing and pins

The real executable directory determines the bundled library home, independent
of cwd and the launcher link. `FPR_HOME` explicitly overrides that home.
Imports first search relative to the importing source, then the toolchain home,
then explicit `FPR_PATH` roots. An extensionless import tries the importer's
extension first (`.sol` or `.fpr`), then its sibling extension. Within each
extension, home precedes `FPR_PATH`. Local files can intentionally shadow bundled
modules; a scheduler should use a controlled script tree and environment.

`use "sol/lib/json"` accesses the installed library without network lookup.
`SOL_VERBOSE=1` prints the pin spelling for unpinned imports.
Sol's `use "name#HASH"` checks a 16-hex-digit FNV-1a hash of that module's parsed
AST, ignoring positions, whitespace and comments. It is a drift check, not a
cryptographic digest or a transitive dependency lock. Pin dependencies individually
or keep the exact bundle/source manifest. This Sol file-import behavior differs
from the native immutable package store described elsewhere in the semantics.

Scripting API 1 is the compatibility line for these documented names and
contracts. Additive APIs may ship under the same line; incompatible changes must
declare a new scripting API line and migration notes. Keep the old bundle until
application checks pass against its replacement. Compiler version alone does not
identify a dirty development build; use the manifest hashes as well.

## Writable cache and recovery state

The compiler cache uses `SOL_CACHE_DIR`, else `XDG_CACHE_HOME/sol`, else the
compatible `~/.sol/cache` default. `SOL_CACHE=0` disables it and
`SOL_CACHE_TRACE=1` explains lookup results. Entries are disposable local build
products, checked against exact inputs and executable identity. They are not
portable bytecode distribution files. Missing, unwritable or corrupt caches
fall back to compilation. After stopping Sol processes, delete only the cache
directory you selected to reclaim space; never substitute a recovery directory.
There is no automatic cache eviction. The parsed prelude is cached once per
executable under `prelude/` in the same directory.

Compiles check a script against only the prelude declarations it can name
(docs/2026-10-29-SOL-INCREMENTAL-PRELUDE.md). `SOL_INCREMENTAL=0` compiles
against the whole prelude, as before; `SOL_INCREMENTAL=trace` reports slice
sizes and fallbacks on stderr.

New state-directory entries use the same platform sync policy as journals; this
is crash-recovery testing, not physical power-loss proof. `SOL_NOSYNC` explicitly
disables those syncs as described in the transaction contract.

New per-run journals use `SOL_STATE_DIR`, else `XDG_STATE_HOME/sol`, else
`~/.local/state/sol`. Overrides must be absolute paths. The final state root and
script groups must be owned directories, not symlinks, and are made mode 0700.
Each script base path hashes to a group containing a `script` descriptor and
`run.soljournal.PID.NONCE` files, with completion and inverse sidecars as needed.
No journal is written beside a new installed script. State is durable recovery
data and must survive crashes; use stable local storage, not a periodic tmp purge.
Target lock directories still live beside the target paths and record absolute
journal paths, so target writers need permission there.

```sh
sol state       # state location and retained journal paths, live/dead owner
sol recover     # finish dead-owner work across the selected state root
```

Startup recovers the current script's dead journals and older sibling-layout
journals. A different script or cwd can recover a dead writer when acquiring its
target locks. `sol recover` also covers deferred-only journals with no target
lock, even when the original script has been removed. Live owners are left alone.
The group's `script` file identifies its original source path for inspection.
Keep the same state selection when running maintenance.

Recovery completes work that passed the durable commit point. An external
command without a completed durable receipt may execute again (at least once).
A recorded failure fences later external work in that commit; completed redo
may then clear its journal and receipts. Recovery is
not permission to repeat later commands or to erase that receipt. Incomplete
pre-commit journals are discarded. A replay I/O error or refused Git compensation
retains its journal and target fences and returns failure. Inspect the diagnostic,
repair the underlying cause (for example an unavailable target directory), then
run `sol recover` again. Never delete target locks, journals, inverse records or
completion receipts merely to make an error disappear. A deliberately refused
foreign Git ref change requires an application-specific reconciliation before
the retained inverse can be resolved; there is no blind force-repair switch.

Empty groups containing only their source descriptor may be removed after all
Sol processes using that state root have stopped. Retain any group with journal,
receipt, inverse or lock artifacts until recovery is resolved. Legacy sibling
journals remain beside their original source until successfully recovered.

## Release checks and evidence

Run the matrix with:

```sh
python3 tools/sol-daily-check.py --output build/sol-daily.json \
  --build-description 'make fpr; record the actual GHC/build options here'
```

It runs the nine required workflows through isolated focused suites, plus retry
and receipt-budget checks. Every command has a bounded timeout and exact-output
assertions in its suite. It saves executable/source identity, host, command,
status, stdout/stderr, raw startup samples and separate cache traces. Startup
disabled/miss/hit samples use fresh processes and a warm filesystem; every miss
removes both module and program cache tiers. Throughput and peak-memory measures
are separate in `sol-io-benchmark.py` and the HTTP benchmark, with independent
byte verification. Installation is registered with the shared Base/CI registry;
the constituent workflow suites are also registered there.

Release evidence is collected under
[`docs/evidence/2026-10-29-sol-phase5`](evidence/2026-10-29-sol-phase5/).
The Phase 2–4 delivery records retain earlier local benchmark snapshots and their
exact executable identities. Cross-host completion is recorded only after the
matrix finishes on each claimed host.

## 2026-10-29 completed release matrix

All nine required workflows pass on both initial target environments. The
[macOS full matrix](evidence/2026-10-29-sol-phase5/macos-release.json) and
[Linux full matrix](evidence/2026-10-29-sol-phase5/linux-release.json) record
11 commands each, including guarded retry and aggregate receipt bounds.
The final installer additionally has a
[macOS follow-up](evidence/2026-10-29-sol-phase5/macos-install-followup.json):
its identity is derived from the staged source bytes, so unrelated live evidence
writes cannot make the manifest describe different bytes from its archive.
The runner is unchanged between that follow-up and the full macOS matrix.

| Workflow | macOS arm64 | Linux x86-64 guest |
| --- | --- | --- |
| Recursive inventory | 103 checks; invalid-byte name unavailable on APFS | 104 checks, including invalid-byte names |
| Schema/config update | 33 checks | 33 checks |
| Bounded CSV/JSON transform | 94 checks | 94 checks |
| Exact binary copy and script I/O | 84 checks; native EXDEV fixture unavailable | 85 checks, including native EXDEV |
| SHA-256/hex/base64 | 132 checks | 132 checks |
| Large log filter | I/O suite and 100 MiB/1 GiB memory probe | I/O suite; bulk memory probe recorded separately |
| Owned raw-argv pipeline | 35 checks | 35 checks |
| Local HTTP/TLS | 61 checks | 61 checks |
| Controlled Git and durable dataflow | Deferred local push, CAS compensation, crash/failure/foreign-writer cases pass | Same cases pass |
| Installed scheduled execution | 43 checks, including native absolute shebang, relocation, minimal env, read-only scripts, recovery, corrupt-bundle refusal and 16 concurrent starts | Same 43 checks pass |
| Guarded retry / aggregate receipt budget | 18 retry checks; admitted receipts and failure fence pass | Same cases pass |

The [registered macOS Sol Base selection](evidence/2026-10-29-sol-phase5/macos-base-final.json)
passes all 12 jobs. [Final affected regressions](evidence/2026-10-29-sol-phase5/macos-final-regressions.json)
cover 52 startup/cache checks plus assembly/concurrent writers, exact-byte cache
invalidation, transaction recovery/serialization, actors, read-only scripts and
native Git/archive automation. The earlier
[broader regressions](evidence/2026-10-29-sol-phase5/macos-regressions.json)
also preserve 125 library checks, 26 output checks, 34 text/process checks and
21 examples. This is a focused Base selection, not a full repository Base run
or a hosted CI result.

The [cross-host comparison](evidence/2026-10-29-sol-phase5/cross-host-source.json)
confirms exact equality of 1,297 execution-source files across the final macOS
installation follow-up and Linux matrix. Build metadata records the actual
[macOS](evidence/2026-10-29-sol-phase5/macos-build-identity.json) and
[Linux](evidence/2026-10-29-sol-phase5/linux-build-identity.json) toolchains,
Cabal/Makefile inputs, linked dependencies and executable identities. Linux's
Git HEAD identifies a disposable verification snapshot; the source hashes and
original `27a4cdc` working-tree baseline identify the delivered implementation.

Fresh-process startup medians, one warmup and five samples, warm filesystem,
interpreter mode, with a small digest import:

| Cache mode | macOS | Linux guest |
| --- | ---: | ---: |
| Disabled | 53.4 ms | 666.5 ms |
| Miss, both artifact tiers removed | 55.6 ms | 714.5 ms |
| Hit | 21.8 ms | 214.4 ms |

These are observations on different systems, not a speed comparison. The JSON
reports preserve raw samples and separate diagnostic runs proving disabled,
miss and hit behavior. The Linux guest is emulated and shared the host with
other verification work.

The final macOS [copy/filter/digest/CSV memory report](evidence/2026-10-29-sol-phase5/macos-io-memory-final.json)
passes every 32 MiB growth gate from 100 MiB to 1 GiB: approximately 6.4 MiB,
0.02 MiB, 0.02 MiB and 5.0 MiB growth respectively. Its
[HTTP report](evidence/2026-10-29-sol-phase5/macos-http-memory-final.json) also
passes the 32 MiB sampled parent/worker family-growth gate, approximately 7.3 MiB.
Throughput, raw RSS and byte-validation commands are saved separately from
startup samples; there is no claim of a cross-version optimization or hard
instantaneous family RSS maximum.

Retained failure records explain earlier attempts rather than replacing them
with successes: the macOS absolute-shebang failure led to the native alias; a
module-child fixture needed the language's top-level import syntax; a parallel
source-copy check led to hashing staged bytes. The first Linux receipt fixture
hit its former 90-second test timeout under QEMU; the identical assertions/data
pass with a bounded 600-second allowance (171.3 seconds observed). None of these
failed attempts counts as passing coverage. Actual power loss, physical x86-64
performance, hosted CI and hosts outside the declared matrix remain unverified.


The final [Linux bulk-memory report](evidence/2026-10-29-sol-phase5/linux-io-memory.json)
also passes all four 32 MiB growth gates at 100 MiB and 1 GiB. Copy, filter,
digest and CSV growth is approximately 6.2 MiB, 0.5 MiB, 1.4 MiB and 1.2 MiB
respectively. The largest CSV run completed in 169.3 seconds under QEMU with
102.4 MiB peak guest-process RSS. Linux RSS is the guest process accounting,
not total host QEMU memory. The benchmark overlapped part of receipt verification;
use these emulated throughput observations as reproducibility data, not native
hardware performance or a controlled comparison with macOS.


Both host-specific archives were built and independently extracted and verified.
Every manifest source/executable digest matched (2,537 source files per archive),
and the extracted native alias ran its version and a bundled digest-file script
from an unrelated directory with an empty PATH and private writable state.
The script emitted the expected immediate-I/O diagnostics on stderr.
[Archive identities and validation](evidence/2026-10-29-sol-phase5/bundles.json)
record the workspace artifact paths and SHA-256 values. These receipts follow
archive creation and are external to those immutable source snapshots.

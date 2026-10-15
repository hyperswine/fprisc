# Native report, archive and Git automation

The report examples, hosted system-report/archive scripts and `sol/lib/git.sol`
no longer invoke tools. FP-RISC owns the workflows, rendering, selection and
budgets; the hosted runtime uses kernel APIs, libarchive and libgit2 mechanisms.
This completes the automation item in the [pure-application audit](2026-10-15-PURE-APPLICATIONS.md).

## Revision reports

`std/gitrevision.head directory` returns `Option String` through native file APIs.
Both report examples use it. It discovers a repository upwards, understands
`.git` directories/gitfiles, bare repositories, linked-worktree `commondir`,
loose/packed refs and detached HEAD. Reference cycles and missing/malformed
metadata return `None`. Discovery/reference following has explicit measures and
bounds. The JSON revision is now a full 40- or 64-character object id, avoiding
ambiguous fixed-length abbreviations. This is metadata inspection, not object
verification; reftable storage and Git environment overrides are not supported.

## Host reports

`sol/lib/system.snapshot Unit` returns a typed tuple of UTC date, hostname, OS
identity, uptime seconds, mounted filesystem facts and process identities.
`snapshotWith limit` supplies an observation admission limit. macOS uses `uname`,
`sysctl` and `getmntinfo`; Linux uses `uname`, `sysinfo`, `statvfs`, and `/proc`.
All headings/rows are rendered by `system-report.sol`. Disk values are exact
bytes, and process rows are pid, parent pid and executable name; they are not
`ps` CPU/memory percentages or command-line arguments. Permission/API failures
return `Err`; there is no command fallback. These are live observations, not
transactional snapshots of a changing operating system. Kernel process access
may require leaving a desktop sandbox.

## Archives

`sol/lib/archive.create source target` queues a native gzip-compressed pax/tar
writer. `createWith (Limits entries bytes)` selects the limits; defaults in
FP-RISC are 100,000 source entries and 1 GiB of regular source-file contents.
The native writer streams data, retains binary bytes, preserves physical
symlinks, rejects special files and unsafe member paths, and refuses a target
inside its source. Libarchive handles format and platform metadata (which is
not included in the regular-content byte budget).

Output is staged beside the destination, flushed and atomically renamed after
successful completion, then the containing directory is synced before Sol
records completion. Failures before publication preserve an existing destination
and remove the staging file; a directory-sync failure after publication reports
that the complete archive was published but durability could not be confirmed. A hard process crash can leave a uniquely named
`.sol-archive.*` staging file; it is never published as a completed archive.
The deferred operation reads live source content at commit, after earlier file
effects. Metadata/size changes detected during a read fail the archive; this is
not a filesystem-wide snapshot or a defense against adversarial path races.

## Git

`sol/lib/git` retains compositional repo/identity, init, add/unadd, commit,
uncommit, branch/delete/switch, tag/untag, status/diff/log/head and push workflows.
It sends typed `GitOperation` values to libgit2, with an 8 MiB response budget
defined in FP-RISC. `rawSpec`, arbitrary argv queries and arbitrary environment
overlays were removed; `identity` sets native commit author/committer signatures.
No executable hooks, external diff/filter drivers or credential helpers run.

Queries read the pre-commit repository immediately and return `Result`.
`head` and `log` keep full ids; status has branch headers followed by numeric
libgit2 status flags and quoted paths, rather than promising Git porcelain-v2
compatibility. Empty explicit path selections are no-ops. Checkout is safe and
branch deletion refuses unmerged commits.

Mutations remain ordered deferred effects in Sol's existing durable journal.
They and archive outputs acquire path locks and use durable completion records.
Panics/validation retries discard uncommitted effects; a failed native operation
fences subsequent native/command operations while later ordinary file effects
still apply. Native operation counts appear in the deferred-operation receipt.
As with the former subprocess implementation, recovery has an at-least-once
window between an operation and its completion record. Git operations are not
an atomic multi-operation repository transaction and may need operator repair
after partial failure or interrupted non-idempotent operations. Ordinary Git
clients/editors do not honor Sol's path locks.

Push remains a realtime publication capability and refuses all pending effects.
Native local/file remotes work directly. SSH authentication uses libgit2's
SSH-agent API with a username in the remote URL; TLS/SSH verification stays
with the library and is not disabled. A libgit2 build that selects an
executable SSH backend is explicitly refused; use libssh2. SSH config host
aliases are not expanded, so remote URLs must name the actual host. HTTPS
token/password authentication,
interactive credentials and external helpers are not provided by this API;
authentication fails explicitly instead of launching a tool. Network transport
and library allocations are not a whole-operation resource/deadline guarantee.

## Build and acceptance

The compiler links libgit2 >= 1.9 and libarchive >= 3.6 using pkg-config.
`make fpr` locates the standard Homebrew libarchive keg on Apple Silicon/Intel;
`NATIVE_PKG_CONFIG_PATH` can override that location. Cabal users can set
`PKG_CONFIG_PATH` directly. Linux needs the corresponding development packages.
The linked [libgit2 native backend API](https://github.com/libgit2/libgit2/blob/v1.9.0/include/git2/common.h)
and installed library headers define the native mechanism contract.

`tests/check_native_automation.py` runs applications with `PATH=/nonexistent`
in disposable fixtures, using Git/tarfile only as independent test oracles. It
covers Git mutations/queries/local pushes, refusal to push pending changes,
output limits, failed-effect fences, rollback, retries and journal recovery;
binary/directory/symlink archives, output preservation and source/target bounds;
and both revision reports on one/four harts across loose/packed/detached/bare/
linked-worktree and malformed/cyclic metadata cases. The source boundary guard
also audits these automation paths and native adapters for process calls.

Acceptance here is local macOS AArch64. Linux implementations are source-present;
this change does not claim a Linux runtime pass, authenticated SSH/HTTPS remote
acceptance, a long-duration memory bound, or any printer-host redeployment.
Development reload/build/test/device tooling and explicit process demonstrations
remain intentional external-tool users. The compiler's separate package-store
push/pull implementation still invokes curl; it is outside these application
and Git-automation paths.

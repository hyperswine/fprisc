# Logging ownership and bounded turns

The physical QOS Pi investigation found retained log request tuples and
snapshot lists. The log server did not explicitly drop incoming roots, and
`logAsk` returned a received root to callers even though `Sys.logSnap` promised
fresh copies in the caller's pool. Passing that snapshot whole to a helper
could retain it indefinitely. Pool reclamation cannot release undropped
message roots.

`logAnswer` now keeps the reply into the caller's pool and drops its received
root. `logStep` explicitly drops each request. The persistent log server uses
`Sys.loopWith` to transfer its rings between request arenas, so intermediate
states and staged-log temporaries do not accumulate. An empty linear buffer
satisfies loopWith's buffer contract; the ring state contains no vectors.
The configured ring length and actual retained line contents determine live
state size. This is reclamation of request history, not a byte quota on logs.

`tests/base/logmemory.fpr` keeps an old snapshot, passes new snapshots whole
to a helper, and performs 2,000 log/snapshot/sequence cycles in scratch
arenas. The old prelude leaves 8,000 additional message roots. The repaired
prelude leaves zero on macOS Base and on the physical AArch64 Pi with one
and four workers. The existing wide-line, staged-C-log, ring-resize, console
rate-limit and dead-logger fixtures retain their behavior. The logger fixture
also links and runs on RV64 QEMU; nested arena/migration checks pass.

The investigation also exposed a Portable Base-host startup issue: qosp's
own one-hart runtime validated `FPR_HARTS=4` against its own cap before the
loaded application could start. A weak `fpr_posix_harts_env` link hook lets
an embedding host reserve that environment setting for its guest. Ordinary
Base programs retain the existing validation. QOS Portable overrides the
hook, and its real GL shell passes the four-worker, two-boot checks.

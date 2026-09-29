# Sol indexed VM and validated startup cache

Date: 2026-09-29

This increment follows the output and case-fallback work. Instruction fetch now
indexes an immutable zero-based array instead of traversing a list from its head
for every instruction. Register frames remain maps, and call/return behavior is
unchanged. This is an instruction-fetch improvement, not a complete VM rewrite.

## Startup contract

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

## Measurement and reproduction

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

## Verification

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

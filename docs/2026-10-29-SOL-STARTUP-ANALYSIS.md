# Sol startup analysis (2026-10-29)

Scope: what `fpr sol script.sol` spends before and around a one-line script. Also, what PR C changes.

**Host.** Linux x86_64 box, 8 vCPU at 2.4 GHz, GHC 9.10.3, `fpr` 24.7 MB, dynamically linked against 56 shared objects.

**Baseline.** `main` @ `b8865bd`.

**Harness.** Wall time measured with Python `subprocess.run`; median of 30 runs after 3 warm-ups. The `p10` column is the 10th percentile. Phase times come from the built-in `SOL_TIMINGS=1` (medians of 22 runs).

**Not measured.**
- `strace`, `ltrace` and `perf` are not installed on the box (apt is broken), and fetching a static strace was not possible in this session. There is therefore no syscall-level breakdown.
- A true cold cache (drop_caches) is not possible on the box. "First run" below means a cache miss: new script content every run, with the binary already in the page cache.

**One-liner mode.** There is no `-e` one-liner mode: `fpr sol --help` lists only `<script.sol>`, `state` and `recover`, and `docs/2026-09-08-SOL-TEXT.md` says "There is no one-liner mode". All numbers below run a file, `hello.sol` = `> print "hi".`

## 1. End-to-end (ms, median / p10)

| Case | before (main) | after (PR C) |
|---|---|---|
| `fpr sol --version` (exec + dynamic link + RTS + exit, no Sol work) | 9.9 / 9.1 | 8.6 / 8.3 |
| hello, warm cache, default env | **65.3 / 60.5** | **11.9 / 11.1** |
| hello, warm cache, `SOL_GPU=0` | 27.3 / 26.2 | 12.1 / 11.2 |
| hello, warm, `SOL_GPU=0 SOL_JIT=0` | 27.7 / 26.0 | 11.9 / 11.1 |
| hello, `SOL_CACHE=0` (full compile every run) | 103.3 / 96.8 | 95.8 / 93.4 |
| hello, first run (cache miss, new source), default | 137.5 / 126.7 | 99.6 / 93.6 |
| hello, first run (cache miss), `SOL_GPU=0` | 98.2 / 85.9 | 95.9 / 87.8 |
| `use` json + csv libs, warm, `SOL_GPU=0` | 43.2 / 41.6 | 19.9 / 17.1 |
| `use` json + csv libs, `SOL_CACHE=0` | 142.5 / 137.3 | 134.7 / 130.0 |
| peak RSS, hello default / `SOL_GPU=0` | 113 MB / 44 MB | 23 MB / 23 MB |
| reference: `perl -e 'print "hi\n"'` | 1.3 | |
| reference: `python3 -c` / `python3 -S -c` | 8.5 / 6.3 | |
| reference: `bash -c 'echo hi'` | 1.0 | |

The "before" and "after" columns are separate runs, so treat differences under about 1 ms as noise.

## 2. Where the warm one-liner time went (before, `SOL_GPU=0`, about 27 ms)

| Phase | ms | Evidence |
|---|---|---|
| Process floor: exec, loading 56 .so files, RTS init, exit | ~9 | `fpr sol --version` = 9.3–9.9 |
| of which shared-library loading and constructors | ~6.1 | An empty C `main` linked against the same libs (`-lEGL -lGL -lgit2 -larchive -lcurl -lgmp`, which pulls in the same 56 objects) runs in 6.5 ms. An unlinked one runs in 0.4 ms. Per library alone: curl 3.9, git2 2.4, archive 1.2, GL 0.9, EGL 0.6, gmp 0.4 (they overlap). `LD_DEBUG=statistics` reports only ~1.4 M cycles (~0.6 ms) for relocation, so the rest is mapping and the libs' init code (inferred) |
| of which RTS `-A64m` nursery | ~1 | `--version +RTS -A1m` = 8.2 vs 9.3. `hello +RTS -A1m` = 23.0 vs 26.2 (noisy) |
| **Cache entry decode** (`Data.Binary` of the whole compiled prelude) | **8.3–8.9** | `cache-decode` phase. The entry for a hello script was 320 KB: the whole prelude's Core and bytecode, of which hello uses a few functions |
| Cache entry deep force (`NFData`) | 2.1 | `cache-force` |
| Canonicalizing the trusted-library allow-list (~65 `canonicalizePath`) | 4.3 | `library-paths` (new phase). It runs on every script, even one without `use` |
| Cache key: binary-encode prelude text + source + AST, then FNV hash | 1.3 | `cache-key` (forced) |
| Source read + user parse + imports | ~0.8 | `source`, `parse`, `imports` |
| Journal recovery scan, JIT init, txn setup | ~0.2 | `journal-recover` 0.16, `jit-init` 0.01 |
| Execute + commit (`print`) | ~0.5 | `execute` (commit 0.07) |
| **GPU init (default env only)** | **~31–35** and +70 MB RSS | `gpu-init` 31.1 ms. Default vs `SOL_GPU=0` is 65 vs 27 ms. It also printed `[gpu] init: ...` on stderr every run |

## 3. Where a first run (cache miss) goes (`SOL_CACHE=0`, about 96–103 ms)

| Phase | ms |
|---|---|
| process floor | ~9 |
| `prelude-parse` (the 400-line `Preamble.hs` text, re-parsed every compile) | 29.9 |
| `typecheck` (prelude + script, inferred together) | 38.9 |
| `bytecode` | 9.0 |
| `lower` + `specialize` + `layout` | 1.6 |
| source / parse / imports / execute | ~1.5 |

A typecheck split between prelude and user code was **not measured**. For hello, the user part is one statement, so nearly all 39 ms is presumably prelude work (inferred).

## 4. PR C: what changed (cheap, safe wins)

1. **Lazy, silent GPU.** `Sol.Gpu.initGPU` no longer creates the EGL/Mesa context. The first `gpuMapF64` that clears every other gate probes it once per process, with the result memoized, and falls back to the CPU on failure. `[gpu] init:` prints only with `SOL_VERBOSE=1`. `sol/examples/dispatch.sol` still takes the GPU tier (verified with `SOL_VERBOSE=1`: `[gpu] vecmap<poly> n=120000`). Its stdout is identical to main, and its stderr is now empty.
2. **Tree-shake the cached program.** Before `Prepared` is stored, Core and bytecode are restricted to the functions reachable from the run roots through `Call`, `TailCall` and `MkPap`. The hello cache entry drops from 320 KB to 27 KB, and decode+force from ~11 ms to 0.2 ms. The cache `schema` is bumped 3 → 4.
3. **Lazy trusted-library set.** `trustedLibraryPaths` (read-only filesystem queries) is deferred with `unsafeInterleaveIO`; only `use` resolution asks it anything. Saves ~4.3 ms for scripts without `use`.
4. **More `SOL_TIMINGS` phases:** `library-paths`, `cache-key`, `cache-file-read`, `cache-checksum`, `cache-decode`, `cache-force`, `jit-init`, `journal-recover`, `gpu-init`.

**Result.**
- Warm one-liner: 65 → 12 ms in the default env, and 27 → 12 ms with `SOL_GPU=0`.
- Peak RSS: 113 → 23 MB.
- `use json + csv`, warm: 43 → 20 ms.
- All 22 Sol suites that were run passed; 2 were skipped as before. `sol-examples-check.py` now passes (21 checks), because the GPU line is gone from stderr.

## 5. What is left, and why it is structural

After PR C, a warm one-liner takes ~12 ms: ~8.6 ms process floor plus ~3.4 ms of Sol work (cache-key 1.3, source+parse 0.8, cache read 0.5, execute 0.5, journal scan 0.2). Perl is 1.3 ms and Python 8.5 ms.

| Option | Targets (measured) | Est. gain | Est. effort / risk |
|---|---|---|---|
| A. `dlopen` libcurl, libgit2, libarchive and EGL/GL on first use, via function-pointer shims in `compiler/cbits/*.c` | ~6 ms library loading | −5 to −6 ms every run (→ ~6 ms warm) | 1–2 days. cbits + cabal/Makefile link flags + a clear "library missing" Result. Medium risk (packaging, macOS paths) |
| B. Smaller RTS nursery for Sol (`-A64m` → `-A4m`/`-A8m`, or `-n` chunks) | ~1 ms | −1 ms | 0.5 day. Must re-run the throughput benchmarks (`sol-benchmark.py`, the 20k-line log), since `-A64m` was presumably chosen for throughput. Not done |
| C. Precompute the cache key's prelude part (constant hash at build time) | 1.3 ms | −1 ms | 0.5 day, low risk |
| D. Typed/compiled prelude artifact: store the prelude's parsed + inferred environment and bytecode separately (or embed it at build time), so a miss only parses and typechecks the user script | prelude-parse 30 + most of typecheck 39 + part of bytecode 9 | first run ~96 → ~25–35 ms (estimate) | 3–5 days. `Infer`, safety and linearity take prelude + script as one program, so this needs an incremental-environment API and a stored-env schema. Medium-high risk. **Not started** |
| E. Faster prelude parse (`Text` input or a hand lexer instead of megaparsec over `String`) | part of the 30 ms | maybe −10 to −20 ms on misses (estimate) | 1–2 days |
| F. `fpr sol -e 'expr'` one-liner mode, cached by content | feature | a repeated one-liner hits the cache (~12 ms); a new one pays the miss (~96 ms today) | 0.5–1 day |
| G. Static link, or a slim `sol` binary without the native compiler | part of the floor | not measured | large |

**Suggested order for Perl-like one-liners:**
1. F and A together: warm ~6 ms, estimated.
2. Then D: new one-liners at ~30 ms, estimated.

Getting below ~5 ms would also need a faster RTS start. That is not measured.

## 6. Caveats

- The box is a shared VM. Medians move by ±1–2 ms between sessions.
- The GPU context is bound to the OS thread that first uses it. Main initialised it on the main thread, which is where maps run. If the first GPU map ran in an actor thread, the context would bind there instead; a failing map falls back to the CPU.
- The cache dir had grown to 46 MB of ~320 KB entries, and nothing evicts entries (no eviction code found in `Cache.hs`). Shaken entries are ~10x smaller, but there is still no eviction.
- The harness is in `/workspace/out/startup/` (`bench.py`, `b2.py`, `phases.py`). The raw results are in `bench-before.json` and `bench-after.json`.

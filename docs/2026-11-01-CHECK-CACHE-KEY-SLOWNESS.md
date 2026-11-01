# Why `fpr check` takes 18 s on vecwide.fpr and minutes on clientstate.fpr

Date: 2026-11-01. Kind: finding (#39 item D). Nothing here changes behaviour.

## Measurements (box, 8 cores, one at a time, cold cache)

| Input | `fpr check` | `fpr compile --check-only` (the real checker) |
| --- | --- | --- |
| `use "std/view"` | 2 s | 1 s |
| `use "std/ui"` | 1 s | n/a |
| `use "std/live"` | 8 s | 4 s |
| `use "std/lens"` | **214 s** (214 s mutator, 3 GB alloc) | **1 s** |
| `use "std/program"` | 0 s | n/a |
| `use "std/json"` | 0 s | 1 s |
| `tests/base/vecwide.fpr` | 10-19 s (load dependent) | 6 s |
| `tests/std/clientstate.fpr` | > 120 s; `fpr run` 10.5 min | n/a |

The checker is not where the time goes. It goes to computing the cache key.

## Cause (verified by reimplementation; root cause read from source)

`Build.sourceClosure` (`compiler/Build.hs:461`) walks the `use` graph to hash
inputs for `checkKey` and for the build cache key (`Build.hs:402,406`, so
twice per build). It has three problems that compound:

1. `usesIn` matches `use "` on **every line, comments included**. Std modules
   carry a usage example in their header, for example `std/actor.fpr:23`
   `#   AC = use "../std/actor".` and `std/lens.fpr:23`. Each one reads as a
   self-import.
2. Paths are not normalised: `std` </> `../std/actor.fpr` gives
   `std/../std/actor.fpr`, then `std/../std/../std/actor.fpr`, and so on.
   Each string is new, so the `seen` check never matches. The chain only
   stops when the path passes PATH_MAX (about 4 KB) and `doesFileExist`
   fails.
3. `seen` is a list searched with `elem` over strings up to 4 KB that
   share long prefixes, and the queue grows with `rest ++ deps`, so the
   walk is quadratic in the number of path strings.

A Python copy of the walk (`/workspace/out` notes) counts:

| Input | path strings visited | real files | longest path |
| --- | --- | --- | --- |
| view | 9 | 9 | 40 |
| live | 617 | 38 | 4090 |
| lens | 3481 | 7 | 4091 |
| vecwide | 581 | 2 | 4090 |
| clientstate | 4094 | 41 | 4091 |

The real compiler (Modules.hs) skips comments, and so does `Project.localImports`.
That is why `--check-only` on the same file takes about 1 s.

## Fix (proposed, not in this PR)

Skip `#` comment lines in `usesIn`, as `localImports` does. Normalise each
resolved path (collapse `..`, or use `canonicalizePath`). Keep `seen` in a
`Data.Set`. Expected result: `fpr check` time drops close to the
`--check-only` time. Hypothesis until measured.

## Tracking

`tests/check_compile_budget.py --tracked` reports `fpr check` time on
vecwide (every run) and clientstate (`--nightly`). It is report-only.
`tests/reliability/compile_time_tracking.py` runs it in the reliability job,
with clientstate only in the nightly run.

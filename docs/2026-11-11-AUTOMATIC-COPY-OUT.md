# Automatic copy-out for declined loops

Date: 11 November 2026. Kind: implementation record with measurements.
Branch `bench/apps`, after the [copy-out fixes](2026-11-11-COPY-OUT-FIXES.md).
This implements item 2 of [the app-workload page](2026-11-11-APP-WORKLOADS-AND-GARBAGE.md):
copy-out is now on by default for every pure loop that stage 2 used to
decline for unbounded state (List, String, recursive types, std/map).

## Summary

Apple M4. The machine was under load during these runs (load average 5-9), so
instructions retired are the stable figure. Outputs are byte-identical.

| Workload | Peak RSS: off -> on | Instructions on/off |
|---|---|---|
| csv | 1356 -> 233 MB | 0.98 |
| wordfreq | 1795 -> 512 MB | 1.08 |
| format | 1026 -> 914 MB | 1.05 |
| records | 209 -> 133 MB | 0.94 |
| treemap | 614 -> 614 MB | 1.09 |
| sim | 3054 -> 97 MB | 1.02 |

What changes, in the compiler and the runtime:

- **Admission.** `FPR_PERSISTENT_LOOP` unset now means every pure loop (`"*"`).
  - `FPR_PERSISTENT_LOOP=<name>` still restricts copy-out to one loop.
  - `FPR_NO_PERSISTENT_COPY_OUT=1` turns it off, and the build cache follows each setting.
  - Placement notes name the loops admitted only because of copy-out.
- **Functions inside loop state.** A pure copy-out loop may hold functions inside its data, as a
  `std/map` value holds its comparator (`Region.copyableWithFunctions`).
  A function-typed loop parameter was already admitted ("copied as it is").
  Receive turns keep the first-order rule.
  This is what admits the `List.fold` over a `Map` in csv and wordfreq, and
  treemap's `inserts`.
- **Survival gate (runtime).** A cycle copies only when at most 1/`FPR_REGION_SURVIVAL`
  (16) of what the arena bumped since its reset would survive.
  - A builder keeps everything it allocates, as `String.lines`, `split` and `words` do. It now pays a sizing walk and never a copy.
  - A loop that keeps just over the threshold used to re-walk its state at every slab, which was quadratic: csv went from 1.0 s to 7.6 s before this fix.
  - After a declined copy, the next attempt waits until the arena has doubled, then 4x, then 8x, and a copy resets the backoff.
  - In a run of declines, the walk stops as soon as it passes the limit.
- **Sharing before declining.** A full walk that would decline re-sizes with the sharing table first. A state of versions that share tails looks like high survival when walked as a tree.
  Counted once, it may be mostly garbage. The `history` fixture is this case.
- **Cycled loops close by adoption.** A pure loop region that cycled used to copy its whole result out at exit, because it held state in a transfer slab.
  When the result is at least half of what the region holds, the state slab and the arena slabs now join the caller's pool (`region_adopt_state`), as an uncycled region already did.
  Before this, one early copy made `String.lines` re-copy every line of the file.
- **Empty region copy (bug fix).** When everything a region copy reaches lies
  outside the region, `need` is 0. The old fallback then called `dc_dup` with no
  context on a heap cell: a segfault (the digest check's `check` loop). This was
  also reachable through the opt-in mode in the previous commit. The copy now returns the state as it is.
- **The sizing pass takes its context as a parameter** instead of thread-locals: a
  `_tlv_get_addr` call per cell on macOS.

## The survival divisor

Instructions relative to copy-out off, and peak RSS:

| | off | S = 4 | S = 8 | S = 16 (default) |
|---|---|---|---|---|
| csv | 1356 MB | 1.13x / 220 MB | 1.11x / 224 MB | 0.98x / 233 MB |
| wordfreq | 1795 MB | 1.35x / 292 MB | 1.24x / 345 MB | 1.08x / 512 MB |
| treemap | 614 MB | 1.70x / 445 MB | 1.29x / 600 MB | 1.09x / 614 MB |
| sim | 3054 MB | 2.12x / 41 MB | 1.06x / 57 MB | 1.02x / 97 MB |

- S = 16 keeps the extra work under about 10% on the app suite.
- The cost is the bound: a steady state's arena reaches about 16x its live size before a copy.
- Copying a large `Map` costs more per byte than building it, because the copy walks the state twice. A cheaper copier would let S come down.
- treemap gains nothing at 16: its live map grows the whole run.

## Tests

- **`check_persistent_reclamation`**: modes are now default (automatic), one named loop, off, and default again. New `drain` case: the state lies entirely outside the region (the segfault).
  `history` now makes per-step scratch, so it exercises sharing and garbage together. A pure builder correctly never copies.
- **`check_consuming_reuse`**: the exact reuse ledger is pinned to copy-out off. Copy-out cycles pack their state into a tuple of their own; the next block checks copy-out together with reuse (2052 requests, 0 copies).
- **Passing**: check_digest_vectors (1/4 harts), check_state_generations, check_receive_turns, check_loop_state, check_arena_migration, check_static_arena.
- **`check_compile_budget`**: within budget (+1.1% hello, +4.7% std-live, +2.7% pos1 allocation against the recorded baseline).
- **`check_base.py`**: every job passes except four that fail identically on the unmodified `57201f0`:
  - `check_x64_scalar` and `check_x64_qos` (the x86-64 `rotate63` store assertion);
  - `check_trmc_arc` (no TRMC worker in the builtin `values` case);
  - `check_trust` (`std/mutmap`, `std/fixedmap` and `std/vector` are not on the safety allow-list).

  `check_live_runner` once hit its 20-second timeout under the suite's parallel load and passes alone.
- **`check_compiler_options`**: the default build keeps an empty cache tag. Copy-out off is tagged `-nopersist`, and one named loop `-persist<hash>`.
  `FPR_NO_PERSISTENT_COPY_OUT` is now in the cache-control list the unit test checks.

## Open

- **A cheaper copier.** One pass instead of size-then-copy, and a cheaper outside test. This would let S drop toward 4.
- **Loops still declined:** polymorphic state, as in std helpers not specialised at their use, and loops with an unknown call as their only allocation.
- **`region_close`'s copy path** still re-copies caller-pool cells.
- **No RSS gate exists.** The app suite records RSS but nothing enforces it.

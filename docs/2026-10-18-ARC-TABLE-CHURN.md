# ARC table churn: compaction instead of doubling, and a lock-free decref miss

Date: 2026-10-18. Kind: runtime fix with measurements. The table is the one in
`runtime/runtime.c` (`arct`, `arc_cap`, `arc_live`, `arc_used`, `arc_grow`,
`arc_slot_for`) that counts cross-actor shares; every `send` promotes the copied
message root into it and every `drop` of a shared root tombstones its slot.

## The two questions

1. `arc_slot_for` grows the table when `(arc_used + 1) * 10 > arc_cap * 7`, and
   `arc_used` counts tombstones. Does steady send/drop traffic with almost
   nothing live keep doubling the table, each doubling a memset and a rehash of
   the whole table under `arc_lock` with every hart stalled?
2. `fpr_arc_decref` of a value that was never shared takes `arc_lock`, probes,
   finds nothing and returns. Is there a sound lock-free pre-check?

## How it was measured

`tests/arc_churn/arcprobe.c` is a `--with` file (the `tests/bench/costprobe.c`
pattern: a benchmark surface, not a language primitive) that reads the table's
C gauges: `fpr_arc_cap`, `fpr_arc_grows_count`, the new
`fpr_arc_compactions_count` and `fpr_arc_used`, `fpr_arc_hwm`, `fpr_arc_live`.
In an `FPR_COST_PROBE` build it also sums two new per-hart ledger fields,
`xr_drop_hit_n` and `xr_drop_miss_n`: decrefs that found an entry and decrefs
that had none.

```bash
./fpr build tests/arc_churn/churn.fpr --with tests/arc_churn/arcprobe.c -o /tmp/churn && FPR_HARTS=1 /tmp/churn
```

Programs (the first is in the repo, the others were built the same way):

- **churn** (`tests/arc_churn/churn.fpr`): one sender, one sink, 200,000
  messages, each a list of 0..299 cells whose length comes from an LCG so the
  size sequence has no short period; the sink drops each message on receipt.
  At most two entries are live at any time.
- **fanin**: 64 senders with their own packing slabs, one sink, 192,000
  messages of the same shape, each acknowledged with an Int (by value).
- **pp-drop**: `tests/bench/pingpong.fpr` with an explicit `drop` in the ponger,
  1,000,000 round trips.
- **pingpong**, **xpingpong**: the benchmarks as they are, with the probe
  appended to `main`.
- **localdrop**, **localdrop4**: a never-shared two-cell list allocated and
  dropped by hand 5,000,000 times on one hart; four actors on four harts doing
  2,000,000 each.

The before numbers are from a detached worktree at `3e44148`, the after
numbers from the same compiler with the changed runtime. Apple Silicon Mac,
`FPR_HARTS` as shown; wall and user times are single runs and indicative only.

## What the churn actually does to the table (before)

| program | harts | arc_cap | arc_grows | arc_hwm | arc_live at exit | arc_used at exit |
|---|---|---|---|---|---|---|
| churn | 1 and 4 | 4,096 | 2 | 2 | 1 | 2,719 |
| fanin | 1 | 8,192 | 3 | 129 | 1 | 3,242 |
| pp-drop | 1 | 4,096 | 2 | 1 | 0 | about 2,800 |
| pingpong | 1 | 2,097,152 | 11 | 1,000,000 | 1,000,000 | 1,000,000 |
| xpingpong | 4 | 2,097,152 | 11 | 1,000,000 | 1,000,000 | 1,000,000 |

Two findings, neither the one the question assumed.

**The doubling under churn is real but bounded.** With one or two entries
live, churn and pp-drop still doubled twice and fanin three times, every one
of them driven by tombstones alone. But the table then stops: `arc_used` sits
at 40-66% of capacity for the rest of the run. The reason is the pair of
mechanisms that already existed. `arc_probe` reuses the first tombstone on a
key's probe chain, and message roots live in packing slabs that the recycler
hands out again, so a long-running two-actor exchange cycles through a bounded
set of root addresses; once each address has tombstoned its own home slot, a
new message at that address reuses it and `arc_used` does not move. Even the
LCG-sized messages and the 64 senders only widened that set (a slab has 4,096
possible 16-byte offsets, times the handful of slabs in rotation). Unbounded
doubling needs an unbounded supply of distinct addresses, which the slab
recycler does not provide in steady state. So the stall the question worried
about happens a few times at startup, not forever; what compaction buys is that
it does not happen at all when nothing is live, and that the table's size
follows live entries rather than the address spread of the churn.

**The benchmarks' growth is a leak, not churn.** `pingpong.fpr` and
`xpingpong.fpr` end with 1,000,000 live entries: not one message is ever
dropped. Their ponger is `ponger self = case receive self of (who, n) -> ...`,
a bare `case` as the whole function body. Autodrop's shape 5 (`case receive me
of ...`) is matched only when the `case` is the final expression of a block
(`goStmts n [] fin` in `compiler/FPRISC.hs`); a function body that is the
`case` itself, with no preceding statements, is never visited. The same ponger
written as `m = receive self; case m of ...` gets `drop m` inserted and ends
with zero live entries. Consequences for the two benchmarks: 101 MB resident
(3.3 MB with the drop), a 32 MiB table, and eleven doublings under the lock.
This is a compiler fix, left as a follow-up; it is why the compaction change
cannot and does not move these two benchmarks.

## Fix 1: compaction at the same size

`arc_grow` now rehashes into a table of `arc_next_cap(cap, live)` slots:

```c
static uw arc_next_cap(uw cap, uw live) { return live * 4 < cap ? cap : cap * 2; }
```

When fewer than a quarter of the slots are live, the rehash keeps the size and
is counted in `arc_compactions`; otherwise it doubles and is counted in
`arc_grows`. Live below a quarter leaves at least 45% of the slots free after a
compaction, so the next rehash is at least that many new keys away; the same
holds after a doubling. `arc_reserve` (the pre-lock reservation of the next
table) uses the same rule, reading `arc_live` relaxed. A spare of the wrong
size, because live moved between the reservation and the rehash, is returned
so the next reservation can take the right one; after a compaction the OLD
table becomes the spare for the next one, so same-size rehashing in steady
churn allocates nothing; when live later crosses the quarter, the reservation
retires that same-size spare off the lock and takes a double-sized one, so the
doubling still finds its table waiting. The static first table `arct0` is
never freed and can serve as such a spare.

| program | harts | arc_cap before | arc_cap after | grows before | grows after | compactions after |
|---|---|---|---|---|---|---|
| churn | 1 | 4,096 | 1,024 | 2 | 0 | 151 |
| churn | 4 | 4,096 | 1,024 | 2 | 0 | 151 |
| fanin | 1 | 8,192 | 1,024 | 3 | 0 | 167 |
| fanin | 4 | 8,192 | 1,024 | 3 | 0 | 164 |
| pp-drop | 1 | 4,096 | 1,024 | 2 | 0 | 1,099 |
| pp-drop | 4 | 4,096 | 1,024 | 2 | 0 | 1,099 |
| pingpong | 1 | 2,097,152 | 2,097,152 | 11 | 11 | 0 |
| xpingpong | 4 | 2,097,152 | 2,097,152 | 11 | 11 | 0 |
| plateau | 1 and 4 | (not measured) | 2,048 | | 1 | 65 |

**plateau** is the transition case: 50,000 churn messages, then 720 small
messages parked in six holders that never drop them (466 stay live after the
holders' mailboxes and the churn's own entries settle), then 50,000 more. The
table compacts at 1,024 through the first half, doubles once when live passes
a quarter (the compaction's same-size spare is retired, the double-sized one
is reserved and used), and compacts at 2,048 from then on.

The table stays at its 1,024-slot start whenever live entries stay under 256;
pp-drop compacts once per about 900 sends, each compaction a 16 KiB memset
and at most one reinsertion under the lock, which is below the noise of the
run (0.47 s user before, 0.47 s after). Resident memory of churn and fanin is
unchanged within 0.3 MB: the tables it saves are 48 KiB and 112 KiB. Nothing
grows silently: `arc_grows` and `arc_compactions` are both readable through
the C gauges, and the growth path is otherwise what it was (the 70% rule, the
counted gateway `fpr_grow_counted` site 5, the probe's panic as the last word
when allocation fails).

## Fix 2: the decref pre-check

The pre-check is a per-slab flag, `fpr_slab_t.promoted`: set under
`arc_lock` at every insertion into the table (the two `arc_live++` sites,
`fpr_arc_incref` and `fpr_arc_promote_share`), cleared only where a slab is
reissued (`fpr_slab_new`, `msg_slab_new`, `fpr_entry_copy_try`), read with
acquire by `fpr_arc_decref` before the lock. A slab whose flag is clear has
never held an entry, so the drop returns at once.

Why it is sound against a concurrent incref of the same object:

1. Only a holder of `v` drops it, and a value has one holder until it is
   handed to another actor.
2. The handoff is a send or a share. Both insert the pointer the receiver will
   see into the table under `arc_lock`, setting the flag, BEFORE the mailbox
   push that publishes the pointer (a release store); the receiver's pop is an
   acquire load. So the flag's store happens-before every decref that has an
   entry to find, whichever hart it runs on. A same-actor drop after its own
   send is ordered by program order.
3. The flag is set by every insertion path and never cleared while any object
   in the slab is referenced: a slab is reissued only when `escaped` and
   `holds` are zero and it is ownerless, or at pool teardown, which is already
   the contract under which its memory is reused.
4. A decref that sees the flag clear is therefore one the old code would have
   answered at `if (!found)` having done nothing else: the fixed-heap park and
   the slab bookkeeping both sit after that check. A flag seen set takes the
   old path unchanged, so a false positive (a slab that once held a promoted
   object, now dropping an unshared one) costs only the lock it always cost.

A per-object bit was considered and rejected: the 16-byte block header's two
words (`total`, slab pointer) are read in a dozen places (the deep copier
derives field counts from `total`, `fpr_free` and the bucket recycler compare
it, `slab_of` dereferences the pointer), and a stolen low bit would need a
mask at every one of them. The slab flag needs one new field; `fpr_slab_t`
grows from 48 to 64 bytes (a pad word keeps `sl + 1`, where the first block
header sits, 16-aligned; a `_Static_assert` pins that), paid once per 64 KiB
slab.

What it is worth. In every message program above the ledger shows
`drop_misses = 0`: each `drop` is of a message root and finds its entry, so
nothing changes there. The miss path is a `drop` of a value that was never
sent, which the lock serialized across harts for nothing:

| program | harts | before | after |
|---|---|---|---|
| localdrop, 5,000,000 drops | 1 | 0.07 s user | 0.06 s user |
| localdrop4, 4 x 2,000,000 drops | 4 | 0.33-0.81 s wall, 1.2-1.5 s user | 0.06-0.34 s wall, 0.12-0.17 s user |

Uncontended, the lock was already a few nanoseconds; contended by four harts
it was most of the run.

## Verification

- `python3 tests/check_base.py`: exit 0 in the main checkout against the
  changed runtime (the `arc_reserve` refinement that retires a wrong-sized
  spare landed while that run was at `check_pos_core`, so every step from
  there on ran the final code). In the branch worktree the final code also
  passed every step up to and including `tests/check_x64_vectors.py` and
  `check_trust.py`, and the suite's inline block (admission, string
  primitives, confined processes, heap nil, bit ranges, I64 and the rest, 53
  checks); the two `cabal exec runghc` compiler tests (`check_specialization`,
  `check_workers`) were not rerun there for want of a cabal build directory;
  they do not touch the runtime.
- `python3 tools/runtime-costs.py --quick --runs 1`: exit 0; the paired
  ledgers are exact as before (256 messages at 16/256/4096 bytes: 512 copies,
  `copy_bytes = n * (size + 32)`, 0 message slabs below 4 KiB payloads; the
  uninstrumented builds report all-zero ledgers).
- `python3 tools/bench.py pingpong xpingpong --runs 5`, before (worktree at
  `3e44148`) and after, same session, same machine:

| FPR_HARTS | pingpong before | pingpong after | xpingpong before | xpingpong after |
|---|---|---|---|---|
| 1 | 447.0 ms | 449.3 ms | panics: `spawnOn: no such hart` | same |
| 4 | 446.7 ms | 458.0 ms | 1061.9 ms | 1068.0 ms |

  The change is within run-to-run noise. Both benchmarks were already 2.65x
  (pingpong) and 4.2x (xpingpong) over `bench/baseline.json` at `3e44148`, as
  [COMPILER-BUILD-OPT](2026-10-18-COMPILER-BUILD-OPT.md) also found; that
  regression predates this change and is not explained by the table (the
  leaking 32 MiB table costs the same before and after) nor by the leak itself
  (pp-drop, with the drop, runs in the same time). `xpingpong` on one hart
  fails by construction (`spawnOn 1`).


## Follow-ups

- **Autodrop misses a bare `case receive ... of` function body.** The two
  message benchmarks leak every message (1,000,000 live entries, 101 MB
  resident). Fixing it is a compiler change in `autoDrop` (`goE` should treat a
  top-level `SCase` whose scrutinee is receive-origin as shape 5), after which
  `bench/baseline.json` for `pingpong` and `xpingpong` should be re-recorded.
- The churn's bounded address set is a property of the slab recycler, not a
  guarantee. A workload that keeps many slabs in rotation (a hub with many
  senders at a high in-flight count) still grows by tombstones until the
  doubling rule's live threshold is reached; compaction now caps that at four
  times the live high-water mark rounded up to a power of two.

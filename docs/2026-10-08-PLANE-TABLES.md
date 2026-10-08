# The plane in two tables: the actor contract and the memory contract

Kind: a decision and its first step, 2026-10-08. Paths: `runtime/` is
this repository, `Q/` is `../qos`.

## The question

The repository split (`Q/docs/2026-09-18-REPOSITORY-SPLIT.md`) left one
thing owned by nobody: who defines what an actor IS, and who runs it.
`2026-09-19-HAL.md` puts "actors and scheduler" in the language's runtime;
`Q/docs/2026-10-02-QOS-AUDIT.md` lists per-hart ACB scheduling as a QOS
principle; `SEMANTICS.md` section 10 says "(decide)" next to scheduling.

The intended shape, stated by the owner: the Base profile defines that
actors exist and what `spawn`, `send`, `receive` and `kill` mean. QOS owns
the mechanism, a per-hart scheduler over actor control blocks, with an API
any program may link, FP-RISC or not. A Base program compiled for a QOS
system reaches that API through its own `runtime/qos` mapping.

## What existed

One table, `fpr_sched_t` in `runtime/fpr.h`, filled by `fpr_sched_export`
with the kernel's own copies of actors.c functions and handed to a loaded
process at entry (`Q/loader/process.c`, `Q/qos/native/proc_entry.c`). A
null table meant "this image is the plane". So the "QOS API" was fprisc's
actors.c compiled into the kernel, and the header let a second copy of
the same runtime defer to the first. Three things made it a runtime-to-
runtime bridge rather than an operating system API:

- every entry spoke in tagged values (`V`);
- one table mixed three contracts: scheduling (send, receive, spawn),
  memory (slab growth, ARC, the heap span, pool reset, stack growth) and
  failure (fail, the cleanup hook);
- Base semantics did not survive the crossing: `spawnCap Static n` was
  silently the plane's default ring of 64 for a process
  (`2026-09-07-MAILBOX.md`, `2026-10-05-SUPERVISION-AND-ADMISSION.md` A6),
  so `tests/mailbox.fpr` meant one thing as a boot image and another as a
  process.

## The decision

Two contracts, two tables, two versions, apart from each other and from
`FPR_NATIVE_ABI` (which now covers only the shared struct layouts and the
boot block that carries the tables):

| Table | Owner | Entries |
| --- | --- | --- |
| `fpr_plane_actors_t` (`FPR_PLANE_ACTORS_ABI` 1) | the scheduler | `send_as`; `receive`, `receive_now`, `receive_from`, `receive_from_res`, `receive_res`; `spawn`, `spawn_at`, **`spawn_cap`** (new: placement and mailbox policy), `spawn_pid`, `spawn_heap`; `fuel`; `sleep_us`; `cleanup_set`, `cleanup_clear`; `fail` |
| `fpr_plane_memory_t` (`FPR_PLANE_MEMORY_ABI` 1) | the memory plane | `arc_incref`, `arc_decref`, `arc_live`; `slab_new`, `slab_release`; `pool_reset`; `stack_grow`; `heap_lo`, `heap_hi` |

Each table carries its version in its first word. `fpr_plane_export`
fills both. Every "am I on the shared plane" test in the runtime now names
the table it uses: `fpr_in_heap`, slab growth, ARC and the conservative
copy path test `fpr_plane_memory`; spawn, send, receive, yield, sleep,
fail and the `Sys.spawnApp` refusal test `fpr_plane_actors`.

The failure entries (`fail`, the cleanup hook) stay with the actors: they
are the actor lifecycle's exits (`2026-10-07-STATES.md`, Reaping).
`stack_grow` went to memory: it hands the current actor a segment from the
shared heap. `spawn_heap` is admission and stays with the actors, though
it draws on memory.

## Versioning at the boundary

`Q/qos/native/shared_boot.h` carries both tables and a `refused` field.
`FPR_NATIVE_ABI` is 5 (the boot block changed shape; the loader refuses
older images before placement, as before). At entry the process compares
each table's version with the one it was compiled against and, on a
mismatch, spawns nothing and writes the reason; the loader frees the image
and answers the refusal by name ("plane actors ABI mismatch: rebuild the
process with tools/build-process-app.sh"). So a table can change version
without the layout changing, and a stale process is refused rather than
run.

Later the same day: the two plane versions are also stamped into the
archive's LOAD section (`planeactors N`, `planememory N`, by
`Q/tools/build-process-app.sh` through `Q/tools/mkqa.py`), read back by
`Q/programs/mods/qaimg.fpr` (`nativeNums m load` now carries eight
numbers) and refused by `check_image` BEFORE placement, by name: "plane
actors ABI mismatch", "plane memory ABI mismatch", "plane contract
versions missing". `Q/tools/native-integrity-check.py` drives all three.
The entry-time check stays as the last line.

## The acceptance test

`Q/tests/mailboxproc.fpr` is `tests/mailbox.fpr` as a loaded native
process; `Q/tests/mailboxnative.fpr` is the kernel that launches it and
compares the result line with the one the plane's own run prints;
`Q/tools/mailbox-process-check.sh` runs it on one and two harts and is a
`check-all.sh` leg. Before `spawn_cap` it would have reported "static 8
queued 20 of 20 (0 refused)".

## What this step does not do, and what is next

- **The boundary still speaks `V`.** A C program cannot call either table
  without becoming an FP-RISC runtime. The next step is a plain-word
  scheduler API: a control block handle, a pid, an owned block; park and
  unpark with a CAS-able state word; kill; current; a reap hook; spawn.
  The mailbox (rings, Static/Dynamic, payload ownership) stays on the
  language side above it: it is what `send` means. Linear send already
  has move semantics and maps straight onto owned blocks; ordinary send
  would copy into a block first, a cost to decide on.
- **Two implementations, one suite.** Bare-metal and posix Base programs
  need a scheduler too. The reference implementation stays in this
  repository's runtime; the QOS kernel links it today and may replace it
  behind the same API. The mailbox test above is the first test that runs
  the same contract through both the direct path and the routed one.
- **The mailbox has its register entry** (`2026-10-07-STATES.md`
  section 2, written the same day): the states a message passes through,
  and two leaks found and closed on the way (mail queued on a dead actor,
  and the body's result pinning its slab).
- **Memory policy is still C.** The memory table names what a process
  needs from the memory plane; `2026-10-03-MEMORY-ADMISSION.md` still
  leaves the policy owner as the C memory actor, and there is no total
  budget (A4).

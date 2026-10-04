# Reducing the C, second round: a measured plan

Kind: plan, with what has landed. Started 2026-10-04. Follows
`2026-09-19-C-REDUCTION.md` (the three tiers, the first round); that page's
goal stands: no policy and no limit lives in C.

## The line

C keeps what is mechanism: device registers, bit operations, loads, stores
and copies, atomics and fences, CSRs and trap tables, the context switch,
thin wrappers over a host's system calls, and tier 1 -- the allocator's fast
path, run-queue linking, channel rings, message transfer, ARC counts. Every
decision, table, format, protocol and limit is FP-RISC. The primitives the
FP-RISC side needs for drivers already exist
(`2026-09-18-MACHINE-PRIMITIVES.md`: `Word.*`, `Mem.read/write`, `Mem.fence`,
atomics, `CPU.csrRead/Write`, `CPU.irqSave/Restore`, `CPU.wait`).

## What the C is (2026-10-04, read function by function)

About 18,600 lines of C and assembly that are ours (vendored ESP-IDF
components, `minimp3.h` and `font_sdf.h` excluded).

| Area | Lines | Stays | Can move | What moves |
|---|---|---|---|---|
| `runtime.c`, `vec.c`, `sstr.c`, `bits.c`, `mod.c` | 4,300 | ~1,950 | ~2,200 | render/show, `==` and deep copy (compiler-generated per type, ~690); string, number and float formatting; transcendentals; logging API; module lookup |
| `actors.c`, `buddy.c` | 3,400 | ~2,080 | ~1,100 | irq routing, sleep, the fail path, admission, spawnApp (~330, as actors); the scheduler's choices and the buddy allocator (~680, need the raw profile on every host) |
| `machine/*` | 3,900 | ~3,870 | ~60 | already thin |
| QOS `hal/virt`, `hal/unix` | 4,300 | ~2,500 | ~1,800 | the TCP/ARP stack in `net.c`; gfx scene walker, text layout, compositing; tty/evdev key decoding; the pins simulator |
| QOS loader, portable, appside | 2,650 | ~1,900 | ~750 | plugin IMPORT parsing (`entry.c`), the kv record format (`store.c`), capability scoping (`process.c`), `sha256.c` |

About a third can move, not half: the scheduler core (send, receive, rings,
switch, stack growth) is ~2,000 lines of real mechanism, and `machine/` is
already thin.

## What the language and compiler need first

1. **A raw/builtin lowering for x64 and a64.** The biggest unlock: anything
   shared with the hosted systems (buddy, the image registry, `sha256.c`, the
   plugin pokes in `entry.c`, the scheduler's pick) waits for it.
2. **Compiler-generated `eq`, `show` and `copy` per type** (~790 lines of C
   that guess field counts from headers; also the faster path, as long as the
   generated copier keeps the C slab-bump primitives).
3. **A synchronous raw policy call from the hart loop.** Victim choice,
   ageing and backlog selection run with no current actor, so they cannot be
   messages: a pure, non-allocating function over an acb layout, called from C.
4. **`str`, `^` and float elaboration that can name a prelude function.**
   Found in this round: `Infer.hs` rewrites `str` of an F64 and `^` straight
   to the `F64.str`/`F64.pow` primitives, and the builtin profile's `Arc.hs`
   tables name them too, so the float formatter and the transcendentals
   cannot leave C until that rewrite can target FP-RISC. The transcendentals
   also need two bit-level primitives to stay (split a float into exponent and
   mantissa, scale by a power of two) -- the bit-cast kind of mechanism.

## Phases

Each one as `heap.fpr` was done: one file at a time, the same tests, the C
and the FP-RISC version held to each other.

1. **Library with no blocker.** String search and order, parse, module
   lookup and compatibility (landed, below). Then the log service is phase
   3 (the rings stay in C for panic's last words; the rate limit, prefixes
   and ring sizes become an actor), and floats wait on item 4.
2. **QOS drivers and protocols (~1,200 lines).** The TCP/ARP stack as an
   actor over `rxFrame`/`txFrame`/`kick`; one `virtio.fpr` layout unit
   instead of the probe and queue setup copied into `net.c` and `blk.c`;
   `blk.c`'s deadline and offline policy; `pins.c` whole. rv64 raw units,
   rv32 keeps the C.
3. **Runtime services as actors (~330 lines).** An irq router (C keeps
   claim and one post; `irq_act[IRQ_MAX]` goes), a timer/sleep service, a
   supervisor for `fpr_actor_fail`, an admission actor over C reserve,
   commit and rollback, a loader actor for spawnApp, and the log service.
   Bootstrap rule: actor 0, the memory actor and these services never need
   one another to start.
4. **QOS Portable, app side (~700 lines).** Plugin IMPORT parsing, the kv
   format and tty/evdev decoding move into the app, which is FP-RISC; they
   are C today because they run on app threads where the host's FP-RISC is
   dormant. The W^X range checks stay in C: they are the security boundary.
5. **gfx (~600 lines).** FP-RISC builds the flat instance buffer, lays out
   text and computes sort keys; C keeps the window, shaders, uploads, the
   instanced draw and present (~500 lines). Floats are not the obstacle;
   per-frame cost is.
6. **Generated walks** replace `dc_dup`, `veq` and `render` (after item 2).
7. **buddy and the scheduler's pick** (after items 1 and 3).

What stays C: send, receive and switch, the allocator fast path and ARC
counts, panic and deadlock diagnostics (no scheduler to run on), audio
callbacks (the OS audio thread), the DRM blit and the mixer's per-sample
loop, pre-actor boot.

## Landed

### Strings: order, search and parse (2026-10-04)

`strCmp`, `strIndexOf`, `strIndexFrom` and `parseInt` are FP-RISC in
`core/prelude.fpr` (`charAt` loops), with Sol's names and contracts; their
C bodies and type-environment entries are gone. `strJoin` stays a
primitive -- it is one allocation and a copy, which repeated `strcat`
cannot be. `tests/base/strprims.fpr` prints 40 cases (empty strings, a
negative or past-the-end start, an empty needle, overflow at
`9223372036854775807`) and `tests/base/strprims.expected` is what the C
primitives printed: byte-identical on posix (a64) and on rv64 bare metal.

### Bits: mechanism only, and no undefined shifts (2026-10-04)

`runtime/bits.c` is the bitwise primitives on Int and nothing else. The
Array Bit tier (`bitsLE`, `bitsBE`, `bitlen`, the polymorphic `toInt`)
had no user but `tests/demo.fpr` and is deleted. The C bodies are what a
closure, a generic call and the inline guard's slow path reach, and they
computed `1L << k` with no range check; an index or shift outside 0..63 is
now a named panic (`tests/base/bitrange.fpr`, inline and as a value).
`BITSET`/`BITTEST`/... stay C: they are bit operations, and an all-caps
name cannot be defined in FP-RISC anyway.

### Panic text is printed whole (2026-10-04)

`fpr_panic` copied a user's `error` String into a static 160-byte buffer:
cut silently, and shared by every hart. `fpr_cpanic_n` takes (bytes,
length) and prints the String's own bytes (`tests/base/longpanic.fpr`, 310
bytes). The `[ERR]` echo is still cut at 95 bytes by the log ring's line
width -- that is the log service's to fix. The apply panic's stale "arity >
24" says 64 now.

### Module tables: C is the registry, FP-RISC the policy (2026-10-04)

`runtime/mod.c` registers attached tables and reads rows: `Mod.plugs`,
`Mod.hashAt`, `Mod.rows t`, `Mod.rowHash/rowName/rowIface/rowFn/rowArity t
i` (table -1 is the image's own). `Mod.find` (newest attachment wins),
`Mod.findAt`, `Mod.resolve`, `Mod.has` and the live-reload gate
`Mod.compatAt` are a `Mod` structure in the prelude, with the same refusal
texts. `Mod.fn` stays C only because `fn` is a keyword and cannot be a field
name. Attach and detach take a writer lock, an attach publishes the slot before
the count, and readers load the count with acquire. Row counts are taken once
at attach, so a row index is bounds-checked in O(1). Review follow-up: this does
not establish a stable reader snapshot across detach/reattach slot reuse or
across the separate row accesses of a compatibility check. That concurrency
boundary remains open; the writer lock alone does not close it.

### Checked (2026-10-04)

Every fprisc suite (`check_{profiles,cases,base,builtin,arc,raw,machine,export}`)
exits 0, as on the unmodified commit, with three new Base checks. QOS on this
branch (`qos` worktree with `fprisc.path` pointing here, no QOS change
needed): smoke 16/16; `livereload`, `loaderfail`, `moduleinterfaces` and
`qpublication` meet their expect lines; `tools/plugimports-check.sh` and
`tools/qsys-check.sh` HOLD; the native kernel boots to the launcher.

## Found on the way, not yet fixed

- `g_sstrFromStr` cuts a String to 128 bytes without a sign (`SSTR_CAP` is
  by design; the silence is not).
- The log rings cut lines to 95 bytes without a sign.
- The virt TCP stack: 4 connections, a fixed 10.0.2.15.

## Phase 2 started: shared virtio and pure block deadlines (2026-10-04)

QOS's `hal/virt/virtio.fpr` now supplies shared allocation-free RV64 probe,
feature negotiation and split-queue programming for block and network devices.
`hal/virt/blockpolicy.fpr` supplies the exact full-word deadline predicate for
the three block timeout paths. The kernel, bare-metal and native process build
paths link both units; RV32 keeps the C fallback.

Independent C register/deadline differentials passed on one/two QEMU harts;
real network and disk refusal/recovery tests passed with virtio v1/v2 on
one/two harts. A loaded native process still reaches its granted namespace and
storage. QOS's `docs/2026-10-04-VIRTIO-POLICY.md` records scope and evidence.
Deadline configuration, DMA ownership, reset/offline transitions and the
TCP/ARP actor are not migrated by this first slice. No full regression sweep
or target performance claim follows from these tests.

The next recovery slice moves the waiting/reset decision tables into
`blockpolicy.fpr` and adds reset-owner cancellation cleanup. Killing the owner
before or after the reset-status write now takes the disk offline while keeping
DMA backing reserved, rather than leaving it resetting indefinitely. The eight
legacy/modern, one/two-hart cancellation boots pass; a temporary build without
the cleanup fails the same fixture. The QOS implementation record carries the
full scope. Configurable budgets and the block service protocol remain open.

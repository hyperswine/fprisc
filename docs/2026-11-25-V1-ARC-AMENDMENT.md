# FP-RISC v1.0 amendment: ARC, sharing and moves across actors (amends Q5)

Kind: **spec amendment** to the living register [2026-11-19-V1-CORE-SPEC.md](2026-11-19-V1-CORE-SPEC.md). It replaces the "remove ARC" half of decision Q5 and the ARC rows of §1.10, §2.3, §4 and §5. Everything else in the core spec stands. Applies from fprisc `main` at `06414ad2` and QOS `main` at `c88b9df`.

Status: **decided** (Jack, 25 Nov 2026). Nothing in the code changes with this page; §6 lists the work it creates.

Line references are to fprisc `06414ad2` unless they name QOS. Usage counts are word-match lines (comments included) over `.fpr` files, re-counted on 25 Nov 2026 at those two revisions.

---

## 0. The decision in one paragraph

Base has **no user-visible refcounting**. The runtime keeps the mechanism that already manages actor message lifetimes, but it is an implementation detail the spec does not expose. `sendArc`, today's only zero-copy path for heap data, is kept and renamed **`sendFrozen`**, with a typed contract: the value is deeply immutable and is not a `Vector`. `sendLinear`'s zero-copy move must work on QOS's shared memory plane before 1.0. The user-level ARC surface is removed: `Rc.retain`/`Rc.release`, the compiler's `--arc` instrumentation pass and `FPR_BUILTIN_ARC`. `arcLive` moves to a debug/test-only module. Builtin and WCET units refuse `sendFrozen`. After 1.0 the runtime may switch its internals to arenas or regions without changing the public contract (`send`, `sendLinear`, `sendFrozen`).

## 1. Why the 19 November wording had to change

Q5 said "ARC is removed from the language spec", and the carried-in decisions said "no ARC in Base". The language never needed refcounts, but the **runtime** uses one table for every heap message that crosses actors, and it is the only thing that makes zero-copy sharing possible:

- **The table.** `runtime/runtime.c:3408` `typedef struct { V ptr; uw cnt; } arcent_t;`. It starts as a static 1,024-slot array, grows under `arc_lock` (`runtime.c:3396–3405`) and allocates its next block through the counted grant path (`arc_block`, `runtime.c:3433–3439`).
- **`send` copies, then increfs the copy.** `runtime/actors.c:3728–3736`: the message is deep-copied into a slab for the receiver (`fpr_msg_copy_to` / `fpr_msg_copy_held_to`) and then `fpr_arc_incref(m)` (line 3736). The receiver's roots are released at its region or turn boundary (`fpr_rx_push`/`fpr_rx_release`, `runtime.c:3782`, `3823`).
- **`sendLinear` moves only what the table already tracks.** `actors.c:3822` requires `fpr_arc_movable_root(m)`, which probes the table (`runtime.c:3751–3761`). Anything else is copied (`actors.c:3857–3863`).
- **`sendArc` shares by promotion into the table.** `actors.c:4560–4596` calls `fpr_arc_promote_share` (`runtime.c:3725`), which adds the sender's standing share plus one per receiver and pins the slab (`escaped++`). A `Vector` is refused (`actors.c:4563–4564`), and a target in another process gets a copy (`actors.c:4570`).
- **Actor death and pool reset.** A dead actor's roots are reclaimed with `fpr_rx_reclaim` (`runtime.c:3865`). `Sys.poolReset` (`g_poolReset`, `runtime.c:3674`) runs under `arc_lock` so shared slabs survive the reset.
- **QOS uses the same verbs.** Under a loaded process image every incref, decref and share is forwarded to the shared plane (`fpr_plane_memory->arc_incref`, `runtime.c:3556`, `3726`; `fpr_plane_actors->send_arc`, `actors.c:4561`).

What crosses actors **without** the table today is limited to:
- tagged immediates, statics and actor handles (`arc_by_value`, `runtime.c:3547`);
- small flat messages: one heap cell of at most `FPR_INL_CELL` = 64 bytes (`runtime/fpr.h:1092`) whose fields are all immediates, nil, handles or statics of the receiver's image (`fpr_msg_inline_size`, `runtime.c:1994–2040`). They are still copied twice, into the ring slot and then into the receiver's memory, and only within one process.

So there is **no ARC-free zero-copy path for heap data today**. Regions, arenas and `keep` copy their results out. Removing the table along with the language surface would make every heap message a copy, which works against the QOS goal of IPC that beats kernel syscall latency for anything larger than a small message. The amendment keeps the mechanism and removes only what users see.

## 2. Decisions

- **A1. Base has no user-visible refcounting.** Decided (Jack, 25 Nov 2026). The runtime keeps its message-lifetime mechanism (the `{ptr, cnt}` table at `runtime.c:3408`, used by `send`'s copy-then-incref at `actors.c:3728–3736`, by `sendLinear`, by actor death and by pool reset) as an implementation detail. The spec does not name it, no Base program can read or change a count, and no conforming program can observe whether the runtime uses counts, arenas or regions. The carried-in line "no ARC in Base" now reads "no user-visible refcounting in Base".
- **A2. `sendArc` is kept and renamed `sendFrozen`.** Decided (Jack, 25 Nov 2026).
  - **Contract:** `sendFrozen : Actor msg -> msg -> Result Unit String`, the same shape as `send` (with the typed `Actor msg` of Q4). The pointer crosses with no copy. The value must be **deeply immutable** and **must not be or contain a `Vector`**. Both are checked at compile time, so today's runtime panic for a `Vector` (`actors.c:4563–4564`) becomes a type error rather than a new trap. Writes after sharing cannot happen because the type admits no mutable part.
  - **Across processes** it falls back to a copy, exactly as `send` does (today's rule, `actors.c:4570`). The result is the same; only the cost differs.
  - **Release:** the receiver's hold ends at its turn boundary like any received root. The sender's standing share must also end without a user `drop`: the compiler's autodrop releases it when the sender's binding dies (see §5, open point 1). `drop` stays a hint that ends a hold early. It is never needed for correctness and never names a count.
  - **Why `sendFrozen` and not `share`:** it stays in the `send` family beside `send` and `sendLinear`, so the three ways a value leaves an actor (copy, move, share frozen) sit together. It also says the contract in its name. `share` is already a user and std name: QOS `std/uart.fpr:141` defines `share : Uart -> Uart`, and QOS `tests/memoryproc.fpr:17` defines a local `share`. A builtin `share` would shadow or clash with both.
  - **Deprecation plan for `sendArc`:** D11 says renames happen in one change with no aliases, and this follows it with one bounded exception, because QOS pins fprisc and cannot move in the same commit.
    1. The change that adds `sendFrozen` keeps `sendArc` as a deprecated alias: same primitive, a compile warning naming `sendFrozen`, refused by `fpr commit` (the same treatment `intMax`/`intMin` got).
    2. The same change migrates every fprisc use (§4).
    3. QOS migrates when it bumps its fprisc pin (part of the 1.0 QOS migration milestone).
    4. The alias is deleted before the v1.0 freeze. It is not part of the 1.0 surface.
- **A3. `sendLinear` must move on QOS's shared memory plane.** Decided (Jack, 25 Nov 2026). **1.0 requirement.** Today `fpr_arc_movable_root` returns 0 whenever `fpr_plane_memory` is set (`runtime.c:3752`, "shared plane: conservative copy path"), so QOS native apps never get the zero-copy move and every `sendLinear` there is copy-and-consume. For 1.0, a received message root moved with `sendLinear` to an actor in the same address space on the shared plane must transfer the same pointer with no copy, through the plane's own lifetime table. The contract stays as it is: the sender's binding is consumed (linearity, `Infer.hs:1780`), a dead target still consumes, and a target in another process gets a copy.
- **A4. Removed for 1.0.** Decided (Jack, 25 Nov 2026):
  - the user primitives `Rc.retain` and `Rc.release` (`compiler/Infer.hs:484–485`; runtime exports `machine/builtin/unsafe.c:119`; LSP entries in `lsp/server/builtins.json`, 8 lines);
  - the compiler's `--arc` ownership instrumentation: `compiler/Arc.hs` (326 lines), `compiler/Arc/Uniform.hs` (123) and `compiler/Arc/Products.hs` (318), 767 lines in total. §3 says which parts `--raw` keeps;
  - `FPR_BUILTIN_ARC` (`Makefile:374–376`; `machine/builtin/arc.c`, `heap.c`, `virt.c`, `runtime/i32.c`) and the `ARC=1` make switch;
  - `arcLive` moves out of `builtinEnv` (`Infer.hs:779`) into a debug/test-only module that release builds and `fpr commit` refuse. It reports whatever the runtime uses internally and has no meaning in the spec.
  §4 lists every current user that must migrate.
- **A5. Builtin and WCET units refuse `sendFrozen`.** Decided (Jack, 25 Nov 2026). The lifetime table takes a lock and grows dynamically (`runtime.c:3396–3405`), which a WCET bound or a bare-metal unit cannot accept. In those units actor messages are limited to immediates and small flat messages (one cell of at most 64 bytes whose fields are immediates, handles or statics, the rule in `runtime.c:1994–2040`). Today the builtin image links no actor runtime (`actors.c` is not in `BUILTIN_RT`, `Makefile:327`, `348`), and the inline-cell path is compiled out under `FPR_BUILTIN` (`fpr.h:1088–1090`). This rule therefore binds the minimal Builtin cooperative scheduler of Q4 when it is built. `sendLinear` of a non-immediate is also refused there until a static-mailbox move exists.
- **A6. After 1.0 the internals may change.** Decided (Jack, 25 Nov 2026). The runtime may replace the table with arenas, regions or the mailbox-serialized design (`runtime.c:3722–3724` names the planned `ARC.qa` replacement) at any time after 1.0. The public contract is `send` (copy), `sendLinear` (move, consumes) and `sendFrozen` (share frozen, copy across processes). As long as those hold, the change is not a language change.
- **A7. Rationale.** Decided (Jack, 25 Nov 2026): §1. There is no ARC-free zero-copy path for heap data today, QOS IPC needs one, and the mechanism that provides it is invisible to Base programs once A1, A2 and A4 hold.

### 2.1 The cross-actor contract after this amendment

| Verb | Meaning | Same process | Across processes | Builtin / WCET |
|---|---|---|---|---|
| `send` | copy | deep copy (small flat cell: ring copy, no table entry) | copy | immediates and small flat cells only |
| `sendLinear` | move, sender's binding consumed | received root: same pointer; else copy and consume. **Shared plane: must move too (A3)** | copy and consume | immediates and small flat cells only |
| `sendFrozen` | share a deeply immutable, `Vector`-free value | same pointer, no copy | copy | **refused** (A5) |

## 3. What `--raw`, `--lib`, `--export` and `machineInterrupt` need once `--arc` goes

None of them depend on retain/release insertion. They depend on the **raw representation work** that `--arc` happens to switch on, and on CLI gates that name `--arc`:

- **`--raw`** is already "the raw ABI without the ownership instrumentation" (`compiler/Compiler/Compile/Target.hs:76–78`). Its lowering, `lowerRawWithProductEvidence` (`compiler/Arc.hs:196–207`), uses the shared representation solver (`Representation.representWithProductEvidence`), `lowerRepresented False` and `Products.lowerProducts False`, plus the allocation-free check `Interrupt.checkRawUnitWithProducts`. It never calls `Arc/Uniform` and never emits `$arc.retain`/`$arc.release`. **Keep:** the representation and lowering code with the ownership flag `False`, and the raw primitive adapters (the `#ifdef FPR_BUILTIN_RAW` blocks of `machine/builtin/arc.c`, lines 94–99 and 182–271). **Delete:** the `True` (ownership) branches, `Arc/Uniform.hs`, `lowerArcWith*`, `$arc.mainManaged`, and the retain/release adapters (`arc.c:7–8`, `virt.c:41–43`). The surviving module should be renamed for what it does, for example `Codegen/RawLower`.
- **`--lib` and `--export`** are refused unless `--arc` and builtin are both set (`Target.hs:79–81`), and `--stack-budget`/`--heap-budget` likewise (`Target.hs:85–90`). The gate is about the C ABI, which is the raw ABI. **Needs:** the gate rekeyed to builtin plus the raw ABI. `Exports.prepareExports` already serves `--raw`. `prepareUniformExportsWith` (`Emit.hs:546`) serves only the ownership path and goes with it.
- **`machineInterrupt`** is refused on builtin without `--arc` (`Emit.hs:526–528`, "raw, allocation-free handler ABI"). What the handler needs is the raw ABI plus the interrupt contract check (`Interrupt.hs:21–22`, `checkInterruptWithProducts`), which Q5 already decoupled from ARC in the spec. **Needs:** the gate rekeyed to the raw ABI, and the interrupt check run on the raw path. `checkRawUnitWithProducts` already enforces allocation freedom on every function there.
- **The FP-RISC allocator (`HEAP=fpr`).** `machine/builtin/heap.fpr` is compiled with `--arc` plus `--raw --lib --export` (`machine/builtin/compile.sol:12`, `Makefile:324–326`), and `HEAP=fpr` is tied to `ARC=1` (`Makefile:308–316`). **Needs:** `HEAP=fpr` keyed to the raw ABI (`FPR_BUILTIN_RAW`), and `compile.sol` passing the raw flag without `--arc`. Its `retain`/`release` exports (`HEAP_EXPORTS`, `Makefile:323`) are removed together with `Rc.*`.
- **RV32 / Tang Nano** never had `--arc` (`Target.hs:67–69`, `Makefile:337–338`). Its `Rc.*` uses are manual ownership on `heap.c`, and they migrate to arenas and regions (Q5).

## 4. Users that must migrate

Re-counted on 25 Nov 2026 (fprisc `06414ad2`, QOS `c88b9df`):

| Surface | fprisc | QOS |
|---|---|---|
| `Rc.retain` / `Rc.release` | 42 lines in 11 files, all builtin or Tang Nano: `tests/builtin.fpr` 7, `tests/builtin_scalar_fast.fpr` 16, `tests/builtin_tangnano20k.fpr` 2, `tests/fixtures/scalar_fast_helpers.fpr` 1, `tests/tangnano20k_stress/` 16 over 7 files. Migrate to arenas, regions and `Mem.free` | 0 |
| `sendArc` | 6 call sites in 3 files: `tests/sendarc.fpr` 2 (plus 2 comment lines), `tests/base/inboxownership.fpr` 2, `tests/base/fixedheap.fpr` 2. Rename to `sendFrozen` | 3 sites in 2 tests: `tests/inboxproc.fpr` 2, `tests/memoryproc.fpr` 1 |
| `arcLive` | 52 lines in 16 test files (`tests/autodrop.fpr` 10, `tests/frames.fpr` 7, 14 others with 1–3 each). Import the debug/test module | 19 lines in 10 files: 13 in 7 tests; `programs/mods/arcsvc.fpr` 3; `programs/mods/docsdata.fpr` 2 (in-OS documentation text); `programs/voxel-interactive.fpr:1172` 1 (an exit print) |
| `arcsvc` | – | `programs/mods/arcsvc.fpr` (60 lines) serves `arcLive` stats, baselines and deltas as `/services/arc`. Becomes a debug-only service, or is retired with `arcLive` |

The 19 November spec counted `Rc` prims at "tests 43" (at `5504e2cb`). The count is 42 now. The ARC modules were 775 lines in §5.4, and they are 767 now (`Arc.hs` 334 → 326).

## 5. Open points this amendment creates

1. **The sender's share in `sendFrozen`.** Today every holder, the sender included, releases a shared value with `drop` (comment at `actors.c:4551–4559`, `runtime.c:3714–3724`), and `tests/autodrop.fpr` shows the compiler inserting drops for **received** messages. For A1 to hold, the sender's standing share must also be released without user code: autodrop at the binding's last use, or the sender's turn boundary. This is a 1.0 requirement on the `sendFrozen` change.
2. **Deep values reclaim shallowly.** `sendArc` reclaims a deep tree's root when the count reaches zero, but its children are pool-scoped (`actors.c:4557–4559`). `sendFrozen`'s contract does not change this. Whether 1.0 needs a frozen-region handoff so a whole tree is shared and reclaimed as one is left to the QOS IPC work.
3. **Sol.** The Sol VM runs `sendArc` as `send` (`sol-vm/Sol/VM.hs:710`). That stays valid: copy versus share is not observable for a deeply immutable value. The rename applies there too.

## 6. Impact on the staged cleanup (§5.5)

- **Stage 3 (renames/removals):** `Rc.*` removal, `sendArc` → `sendFrozen` with the deprecation alias of A2, and `arcLive` moving into the debug/test module are one D11 change each. The QOS pin bump picks up the rename.
- **Stage 5 (delete the erased duplicates, then ARC):** deleting the `--arc` instrumentation pass (§3's delete list, most of the 767 lines) joins this stage. The gate is no longer "census `arc=0`" against a missing replacement. The pass is deleted once the four users in §3 run on the raw ABI and the builtin tests have migrated off `Rc.*`. The **runtime** lifetime table is not deleted at stage 5 (A1, A6).
- **Not a cleanup item:** A3, `sendLinear` on the shared plane, is runtime work on the 1.0 critical path for QOS IPC.

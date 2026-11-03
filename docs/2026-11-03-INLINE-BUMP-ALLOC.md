# Inline bump allocation (2026-11-03)

Phase 2 of the [unboxing / zero-overhead proposal](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md),
item 5 of the [zero-overhead follow-ups](2026-10-31-ZERO-OVERHEAD-FOLLOWUPS.md),
step 6 of the [performance plan](2026-10-26-PERFORMANCE-PLAN.md). Branch
`inline-bump-alloc`. Rollback: `FPR_NO_BUMP_ALLOC=1` (cache identity
`-nobump`); `codegenRev` 151, selection revisions a64 30, x64 29, rv 30.

## What changed

A constructor (`OMake`, every `Cons` included) used to be a C call to
`fpr_alloc`: `fpr_hart()`, `cur_pool`, then, in an actor pool, an atomic
exchange on the size class's bucket head even when it was empty, and the
call clobbered every caller-saved register. It is now an inline sequence that
bumps the current pool's slab directly and calls `fpr_alloc` only when it
cannot:

```
ldr  x16, [x28, #480]      ; hart cell 59: the window's slab (0 = closed)
cbz  x16, refill
ldr  d,   [x16, #32]       ; slab->hp
add  d, d, #48             ; + total (payload rounded to 16, + 16 preheader)
ldr  x17, [x16, #40]       ; slab->end
cmp  d, x17
b.hi refill
ldr  x17, [x28, #488]      ; hart cell 60: the pool's bucket array
ldr  x17, [x17, #16]       ; this size class's recycled-block head
cbnz x17, refill
str  d, [x16, #32]         ; slab->hp = end of the cell
sub  d, d, #32             ; the object
mov  x17, #48
stp  x17, x16, [d, #-16]   ; preheader: (total, slab), as alloc_in writes it
str  xzr, [d, #24]         ; the zero pad alloc_in writes (even field counts)
ldr  x16, [x16, #8]        ; slab->owner: pool->allocated += total
ldr  x17, [x16, #16] ; add ; str
ldr  x17, [x28, #472]      ; hart cell 58: region_bytes += total
add ; str
b    done
refill:
mov  x16, #24 ; bl fpr_alloc_save_local ; mov d, x17
done:
```

That is 23 instructions on the hit path for a cons on A64 (20 on Linux
x86-64 with its memory-operand adds, 26 on RV64 including the 3-instruction
TLS hart read), no call, no atomic, and no clobbered allocatable register.
The task's "about three instructions" counted only the cursor bump; the rest
is what the runtime's own bump path already does per cell and has to stay
exact (see *Kept exact* below). Folding the two gauges is the obvious next
cut (below).

### The window (runtime)

`fpr_hart_t` gains two cells right after `region_bytes` (cells 59, 60;
`runtime/fpr.h`, static assertions pin them and the slab/pool offsets the
code uses):

- `bump_slab`: the current pool's bump slab, or 0 (closed);
- `bump_bkt`: that pool's bucket array, or a static all-empty array for a
  bucketless region arena.

The cursor is the slab's own `hp`, not a copy in the hart, so every walker
and every C allocation sees an exact slab at all times; there is nothing to
flush. `fpr_alloc` opens the window at its end (`bump_open`), over whatever
pool is then current. It is closed (`fpr_bump_close`) wherever the current
pool, its bump slab or its buckets can change, or the running actor does:

| Site | Why |
| --- | --- |
| hart loop, before `h->current = n` and before `h->current = 0` | every actor switch, so also every migration |
| `alloc_in` slab refill | the pool's bump slab changes |
| `arena_open`, `arena_close`, `arena_reset` | Sys.arena/loop/loopWith pools and turn rewinds |
| `region_open`, `region_close` | compiler loop/call regions |
| `fpr_arc_teardown_pool`, `g_poolReset` | slabs go home, buckets cleared |

A zeroed hart block is a closed window, which is what a QOS app image's
`.bss` harts and a boot hart before its first allocation are.

Never opened: in a `FPR_COST_PROBE` build (so `cost_alloc_requests` and
`cost_alloc_bytes` count every allocation on the call path exactly as before;
the probe build runs the same generated code, which always refills), and in a
process routed through the shared plane (`fpr_plane_memory`), whose actors the
kernel's scheduler switches.

### Kept exact

- Layout: the cell, its 16-byte preheader `(total, slab)` and its zero pad
  are byte-for-byte what `alloc_in` produces. C1's preheader removal is a
  separate later revision.
- Buckets: a size class with a recycled block refills, so `alloc_in` takes
  the block exactly as before; freed cells are not stranded.
- Regions: `region_bytes` and `pool->allocated` grow per cell as in
  `alloc_in`, so loop regions still cycle per slab (`ORegionRoom` reads the
  same clock) and call regions still open at the refill that crosses a slab
  (`region_trip` runs in the refill). Pre-charging a whole slab to the clock
  was rejected: a 256 KiB slab would trip a 64 KiB loop region every
  iteration.
- Slow path: `fpr_alloc_save_local`, a unit-local wrapper like the fuel
  tick's, saves x0..x15 and d0..d7 (A64), rax..r10 (x64), ra, t0..t2, t6,
  a0..a7 (RV64) around `fpr_alloc`. The new protocol `BumpAllocate`
  (`Codegen.Protocol`) declares only the expansion's scratch (x16/x17;
  r10/r11; t3..t5) and a preserving runtime call (`PreservingRuntime`), so
  the allocator keeps values in caller-saved registers across a constructor.
- Bound: a cell is inline when its total fits 2032 bytes (250 fields), the
  RISC-V I-type immediate every target's add and bucket read use; a larger
  cell keeps the call, which is no less correct.

### Where it applies, and where not yet

| Target | Inline | Why |
| --- | --- | --- |
| hosted A64 (`fpr build`, hart in x28) | yes | |
| hosted x86-64 Linux (TLS) and macOS (TLV) | yes | the macOS form pays the TLV thunk per cell; still no C call |
| hosted Linux RV64 (TLS, and IE-TLS modules) | yes | |
| bare-metal RV64 (`tp`: the QOS kernel and its plane processes) | no | the kernel's and the process image's runtimes would both have to agree on the cells; not verifiable here |
| loaded QOS apps (A64 x28/global, qx64, qrv64) | no | profile `QosApp`; the app's harts are its own but the path is not qualified |
| builtin, builtin ARC, RV32 | no | no slabs (builtin heap), or the RV32 profile |

`Codegen.Policy.bumpAllocates` is the gate (`polBumpAlloc && HostedBase`),
plus the hart form per backend.

## Evidence

All on this Mac (Apple M-series, shared with two other sessions' builds;
paired and interleaved to cancel that load). Raw samples:
[`bench/2026-11-03-inline-bump-alloc.json`](../bench/2026-11-03-inline-bump-alloc.json).

### Timings (31 paired rounds, one hart, wall clock incl. start-up)

| Row | on (median) | off (median) | median on/off |
| --- | --- | --- | --- |
| list_fold | 38.5 ms | 41.8 ms | 0.922 |
| list_length_rev | 79.5 ms | 128.5 ms | 0.618 |
| tree_sum | 102.6 ms | 146.9 ms | 0.692 |
| list_map, `FPR_NO_LIST_FUSE=1` | 116.8 ms | 220.6 ms | 0.536 |
| list_filter, `FPR_NO_LIST_FUSE=1` | 103.1 ms | 178.0 ms | 0.583 |
| actors (tests/bump_alloc) | 28.7 ms | 44.6 ms | 0.645 |

list_fold allocates its list once and then only folds it, so it gains least;
the rows that allocate per element gain 1.4-1.9x, above the proposal's 1.2-1.5x
estimate (the removed atomic exchange and the registers no longer spilled
around the call are both in it).

### Fast-path share

Every allocating row takes the inline path for 99.9% of its requests
(`FPR_COST_PROBE` request count against `fpr_alloc` calls counted by the
`FPR_BUMP_CHECK` runtime, which include the C runtime's own allocations):
list_fold 598 calls / 1,000,004 requests, list_length_rev 12,459 / 21.0 M,
tree_sum 11,470 / 10.5 M, list_map 23,705 / 40.0 M, list_filter 22,785 /
30.0 M, actors 4,226 / 6.4 M.

### Text size

`__text` grows about 23 KB per hosted A64 binary (+7%: list_fold 318,136 ->
341,064 bytes; tree_sum 279,928 -> 293,752), ~90 bytes per constructor site,
most of it in the prelude unit. Folding the gauges and sharing the refill
tails would cut it (below).

### Compile budget

`python3 tests/check_compile_budget.py`: within budget. hello 1.54 GB
(+4.9%), std-live 31.94 GB (+6.7%), pos1 69.15 GB (+6.7%) against the darwin
baseline of 8cabb16. With `FPR_NO_BUMP_ALLOC=1` the same build measures
+5.2%, +6.8%, +7.1%, so the drift predates this branch (main's commits since
the baseline); the bump itself costs nothing measurable.

### Correctness

- `tests/check_bump_alloc.py` (registered in `tests/check_registry.py`):
  eleven programs (the allocating unbox rows fused and unfused, regionnest,
  pendreset, turnroots, fixedheap, autodrop3, eight migrating actors) print
  the same on and off on one and four harts; built with `FPR_BUMP_CHECK=1`
  they print the same again while the runtime verifies at every fuel tick and
  every `fpr_alloc` that an open window is the current pool's bump slab, its
  owner and buckets the pool's and its cursor inside the slab; every
  allocating program was seen with windows open (regionnest: 5.8 M checks,
  5.8 M with a window open) and with slabs refilled under load. On x64,
  a64mac and rv64 a cons builder's function has the inline path and no
  `fpr_alloc` call; off, the reverse.
- Differential over every `tests/bench/unbox` program, fused and
  `FPR_NO_LIST_FUSE=1`: identical output (22 builds each way).
- macOS x86-64 under Rosetta: actors, tree_sum, list_length_rev, regionnest,
  pendreset, turnroots identical on and off at one and four harts, except
  that turnroots on four harts panics "received roots did not settle" about
  40% of runs on and off alike, and equally (8/20) with an untouched
  `origin/main` runtime and compiler: a pre-existing x64/Rosetta issue,
  not this change (native A64: 0/30 either way).
- RV64: the emitted code assembles (`riscv64-unknown-elf-gcc`); executing it
  needs the CI cross toolchain (`check_rv64_linux.py --typed-ir`).
- `make unit-tests`: 38 suites pass.
- Base (`tests/check_base.py`, each job run alone with `--only` because the
  run stops at its first failure): 165 of the 171 jobs pass with the fast
  path on. The other six fail identically on an untouched `origin/main`
  (2d3b9d6, built with the same compiler revision), so they are not this
  change: `check_mvu_reload` (`mvuportmemory`) and `check_receive_turns`
  (`mvueventports`), both "send: target is not an actor" from an MVU event
  port; `check_reuse` and `check_consuming_reuse` (10,000 allocations where
  20,000 are expected in a reuse-disabled mode); `vecpeek` (96,048 bytes
  where 96,096 are expected); `panic_actors_std` (the panic text is on
  stderr, the check reads stdout). The full Base run was not repeated with
  `FPR_NO_BUMP_ALLOC=1`; its cases assert fixed expected outputs, and the
  on/off differential is `check_bump_alloc.py` and the unbox sweep above.
- Harnesses that link function bodies cut out of a unit
  (`tests/fuel_wrapper.py`) now append the refill wrapper as well, when the
  cut-out bodies call it.

## Follow-ups

1. Fold the gauges: `pool->allocated` could be settled lazily (charged at
   window close and read through an exact accessor), saving four
   instructions and a load-store per cell; it needs C allocations from the
   window's slab to stop double-counting.
2. Share refill tails per function to cut the text growth.
3. Qualify the bare-metal RV64 (QOS kernel) and QOS app forms.
4. The x86-64/Rosetta turnroots flake on four harts (pre-existing).
5. The six pre-existing Base failures listed above.

# Overhead and architecture audit (25 November)

Kind: findings and proposals. Nothing here is implemented yet.

Eight issues found while working across FP-RISC, Sol and QOS between 15 and 24
November: two runtime or compiler overheads, and six architectural or process
problems that cost time or hid failures. Each has the evidence it rests on and a
proposed fix. Code references are to `main` at `06414ad2` unless stated.

One earlier claim is withdrawn first, because it affected how benchmarks were
read.

## Correction: idle harts do not spin

The Benchmarks Game write-up (2026-11-15) and the vector stores note said that
instruction counts for FP-RISC binaries include idle harts spinning in `hal_wfi`.
That is wrong. With the default harts and with `FPR_HARTS=1`, CPU time equals
wall time (fannkuch-redux 11: 4.77 s wall, 4.78 s user; one hart 4.85/4.83),
`ps` shows the process at 98.9% of one core, and every idle hart thread at 0%.
macOS `sample` attributes a parked thread to `hal_wfi` (the frame that called
`pthread_cond_timedwait`), so its counts there are not CPU time. `hal_wfi`
(`machine/unix/park.c`) spins for 20 µs and then sleeps in 20 ms slices, as
designed. Use wall time and `ps`, not `sample` totals, for idle-hart questions.

## Overhead

### 1. `Vec.dup` and vector frees are runtime calls on hot paths

A profile of fannkuch-redux 11 on the current build has `h_dup`,
`alloc_in_size`, `fpr_alloc`, `fpr_free_raw` and `Vec.free` among its top
frames after the program's own loop. The program asks for a copy of the
permutation every iteration (`Vec.dup`), and `Vec.dup` has no inline lowering:
it is only the C entry `fpr_g_Vec_x2edup` (`runtime/vec.c`, `h_dup`), which
allocates a new descriptor and column and copies them.

Proposed: lower `Vec.dup` of a flat Int or float vector inline, with the same
view the inline reads and stores use (one allocation of the known size and a
word copy), falling back to `h_dup` for other reps. A copy into an existing
vector of the same length (`Vec.copyInto`) would let loops reuse one scratch
vector and allocate nothing. Measure with fannkuch-redux before and after.

### 2. The lowering state builds thunks

`Codegen/Lower.hs` keeps its per-function state in a record with lazy fields
(`data St = St {stV :: Int, stB :: Int, ...}`) and updates it with lazy
`modify` (lines 89 and 95, and the block open/suspend/resume helpers). Each
fresh VId or block id leaves an unevaluated update chain until something
forces the state. On the vector stores branch (2026-11-15), the same pattern
held about 21 MB of extra peak residency compiling pos1; making the new fields
strict and the updates `modify'` removed it.

Proposed: strict fields (`!Int` and so on) and `modify'` throughout `Lower.hs`.
A small, mechanical change; check it with the compile budget.

## Architecture and process

### 3. QOS `main` can depend on FP-RISC work that has not landed

On 24 November qos `main` (`efcf3a1`) used `Game.KeyUp` and `MV.EKeyUp`, which
existed only on the unmerged fprisc branch `ari/zero-cost-audit`, not at qos's
fprisc pin and not on fprisc `main`. No SDK could be staged from qos `main`
(fixed by merging that branch, `df405ef8`). qos CI did not notice: its smoke
job builds the host and one hello program, not the modules under
`programs/mods`.

Proposed: a qos CI step that type-checks every `programs/mods` module and every
`apps/*` entry against the pinned compiler (`fpr check`), so a module that needs
a newer FP-RISC fails the push that introduces it.

### 4. The compile budget's peak residency is noisy

`tests/sol-checks/compile-budget.sol` reads `max_bytes_used` from GHC's `-t`
statistics: the live data at whichever major collections happen to run. On the
vector stores branch, pos1's figure moved between 606 MB and 650 MB across
builds, and reordering one cheap guard moved it by 23 MB, while a heap profile
sampled every 0.5 s (`+RTS -hT -i0.5`) showed 560.0 MB with the change and
562.5 MB without it. The check failed changes that did not retain memory, and
the darwin baseline has been re-recorded several times for that reason.

Proposed: gate on allocation (deterministic) with its current margin, and
measure peak with a fixed sampling interval (`-i0.5` heap profile maximum) or
report it without gating. A wider margin alone only moves the false failures.

### 5. Compiled-unit caches are invalidated by hand

The unit and object caches are keyed with `codegenRev` (now 262), a number
bumped by hand in `compiler/Codegen.hs` when generated code changes. A compiler
change without a bump reuses stale units, and sessions have repeatedly had to
delete `*gNNN*` entries from `~/.cache/fpr` by hand while iterating.

Proposed: key the caches on a hash of the compiler executable (or of the
compiler's sources at build time) together with the runtime sources, and keep
`codegenRev` only as a human-readable label in diagnostics.

### 6. Sol duplicates the standard library and behaves differently

Sol ships its own `sol/lib` (`json`, `http`, `csv`, `digest` and more) beside
FP-RISC's `std`, and the two diverge in ways that broke real work:

- `Str.words` does not split on tabs. `ldd` indents its lines with a tab, so
  the Pi SDK packager named every bundled library `\tlibgmp.so.10` and so on:
  nothing could load, and libc escaped the system-library filter (fixed in qos
  by replacing tabs first).
- Defining a prelude name (`input`, `collect`) silently shadows it; the error,
  if any, appears far from the definition. Defining `input` made a build script
  hang reading stdin.
- `writePath` is transactional: the write lands at commit, and running a
  process after a queued write is refused. Every script that writes evidence and
  then runs another command needs a streaming write (`Stream.openWrite` plus
  `Fs.copyPublishNow`); three were written in November.

Proposed: one string library with one meaning of whitespace, shared by Sol and
`std/string`; a warning (or error) when a script defines a prelude name; and a
documented immediate write (`writeNow`) in `sol/lib` so scripts stop
reimplementing it.

### 7. Stale parallel work

The vector stores branch (`vec-inline`, 15 November) was superseded on `main`
by inline vector stores and views implemented another way (`OVectorView`,
`StoreElement`), but it stayed open, with its worktree, for nine days. Similar
overlaps appear among the unmerged `ari/*` branches on the remote.

Proposed: when work lands that supersedes an open branch, close the branch in
the same change (or say in the commit which branch it supersedes).

### 8. QOS build glue (qos side)

- `qos-app.mk` runs `"$(SOL)" tools/...`, which works only if that path is an
  executable named `sol`: `fpr` acts as Sol only under that name. `fpr sol`
  already exists (`compiler/Main.hs`), so `"$(FPRC)" sol tools/...` removes the
  naming requirement.
- The Pi SDK packager (`tools/pi4/compiler-sdk-*.sol`) still passes the retired
  Python arguments (`py`, `stdlib`, `extensions`) through every step; they are
  always empty.

## Related: removing a primitive orphans frozen module versions (Resolved)

Found while starting the QOS port to FP-RISC `main` (24 November). v1.0 removed
`intMax`/`intMin` (`34175b74`). QOS pins three frozen versions of `std/actor`
(v2.0, v3.0, v4.0) about 150 times and two of `leaseslots`, and all of them use
`intMax`, so they no longer compile. A new version cannot be minted either:
`fpr commit` checks the new version against the previous one, and the previous
one is exactly what fails to compile. Every removal from the language will meet
this in any repository with a store.

Resolved: kept `intMax`/`intMin` as deprecated values fixed at the old 64-bit
bounds so frozen pins continue to compile while `fpr commit` refuses them in
new code, and shipped QOS Portable SDK `0.5.0` against `main`.

## Order of work

Quick and independent: 7 (cleanup), 2 (strict state), 5 (cache key), 3 (qos CI
step), 8 (qos glue). Needs design or measurement first: 1 (`Vec.dup` lowering),
4 (budget metric), 6 (Sol library unification), and the frozen-version
question, which blocks the QOS move to FP-RISC `main`.

## Progress log (25 November)

- **#1 (`Vec.copyInto`)**: Added `Vec.copyInto : Vector a -> Vector a -> (Vector a, Vector a)` (`runtime/vec.c`, `compiler/Infer.hs`) to overwrite a destination vector in place without bulk allocation when layout matches and capacity suffices. Updated `tests/bench/clbg/fannkuchredux.fpr` to reuse one scratch vector: `fannkuch-redux 11` dropped from **5.24 s real / 4.91 s user** to **4.45 s real / 4.10 s user** (-15.1% wall / -16.5% user, identical `556355` / `Pfannkuchen(11) = 51`).
- **#2, #4, #5, #6 (quick wins)**: Landed in `1b1072b2` (strict `Lower.hs` `St`/`Cur` + `modify'`, report-only `max_bytes_used` in `compile-budget.sol`, executable `(size, mtime)` FNV-1a stamp in unit cache keys, `Str.words` ASCII whitespace, `writeBytesNow`/`writeTextNow` in `sol/lib/base.sol`, and Sol prelude-shadowing warning).
- **#3, #8 (qos)**: Committed locally on `qos` `main` (`61f7f24`): added CI type-checking for the 7 active QOS apps and 3 core modules (`gamerun`, `guishell`, `qsys`), switched `qos-app.mk` / `tools/ccobj.sol` to `$(FPRC) sol`, and stripped retired Python arguments from `tools/pi4/compiler-sdk*.sol`.
- **#7 (branch hygiene)**: Audited `origin` remote branches — 39 are already merged into `origin/main` (safe to prune whenever pushing) and 11 remain unmerged (`ari/chan-index`, `ari/chan-sender-line`, `ari/inline-strcompare`, `ari/overhead-audit-2026-11-16`, `ari/profile-2026-11-14`, `ari/regalloc-split`, `ari/review-2026-11-15`, `ari/unbox-f64`, `ari/unbox-notes`, `ari/unbox-range`, `ari/v1-arc-amendment`).

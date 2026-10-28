# Repeated and unnecessary work across the tree

Date: 2026-10-28. Kind: review. Applies to `main` at `7d8d283`. Follows
[the compile-speed analysis](2026-10-27-COMPILE-SPEED.md) and
[the compile-time budget](2026-10-26-COMPILE-TIME-BUDGET.md), and does not
repeat their findings (listed under "Already known" below).

**Method.** A source reading of the compiler, the C runtime and posix machine
layer, the Sol profile, the build driver and the test registry, with the call
sites of each finding read rather than inferred from names. **Nothing was built,
profiled or benchmarked for this page.** Numbers quoted come from the dated
pages and evidence files cited next to them. Each finding is marked:

- **confirmed**: the repetition is certain from the code and its callers;
- **suspected**: the code is as described, but whether it costs anything
  depends on input size, laziness or GHC floating an invariant at `-O1`.

Status: findings and suggested fixes; none implemented. Line numbers are at
`7d8d283`.

## Already known (not repeated here)

From the 10-26 and 10-27 pages: the whole module graph is parsed, inferred and
checked on every compile; the seven linked passes and region placement run on
every artifact before the unit cache lookup; each linked pass re-erases and
re-verifies every definition; constructor stubs are copied into every unit;
`hashAST` hashes `show` output character by character; `type Name = String`;
units are emitted serially on one core. The per-artifact `Cost.costProgram`
rerun was fixed in `4f56c95`.

## Summary

| Area | Highest-value findings |
|---|---|
| Build and tests | cold caches in ~80 test scripts; units cached as `.s` and re-assembled at every link; programs rebuilt per hart count; runtime object key too broad; `runghc` jobs with existing cabal suites |
| Frontend | `generalize` scans the whole environment; defaulting re-zonks every operator site per SCC; clause lookup by linear scan; call graph and measures built up to five times |
| Middle-end and backend | quadratic `freeVars` on the warm path; uncached root re-specializes against the whole program; receive-turn reachability per artifact; allocator constraint scans; repeated verification; inliners without early exit |
| Runtime | up to three graph walks per bounded send; four backlog scans per refill; `signal()` on every write |
| Sol | eager GPU init per run; `Map` register frames and name-keyed calls; cache key re-serialises the prelude and imports |

The build and test items are the cheapest to fix and probably the largest in
developer wall time. On the compiler side, the frontend items are likely the
largest; a `make fpr-prof` run on the QOS shell (`tools/compile_profile.py`)
should rank them before inference is changed.

## 1. Build driver, caches and tests

**1.1 Test scripts start from cold caches (confirmed).** 85 Python scripts
under `tests/`, `examples/` and `tools/` set `XDG_CACHE_HOME`; about 80 of them
point it at a fresh temporary directory rather than honouring an existing value
(only a handful use `os.environ.get('XDG_CACHE_HOME', ...)`). `Build.hs` keeps
both the runtime-object cache and the unit cache under that directory, so each
such script compiles the 22 runtime and machine C files at `-O2` and re-emits
the prelude and std units from scratch. `check_base.py` warms `~/.cache/fpr`
with `hello.fpr`; these scripts never see it. Several go further and use one
cache per mode, width or flag (`check_typed_ir_coverage.py`,
`check_typed_ir_rv_frames.py`, `check_typed_vector_reads.py`,
`check_typed_inline.py`), although the `FPR_NO_*` modes are already part of the
unit key and do not change runtime cflags. `check_compile_budget.py` is cold on
purpose and should stay so.

*Fix:* one suite-level cache set by `check_base` and `check_ci`, and the
`environ.get` fallback pattern in every script.

**1.2 `fpr compile` keeps its unit cache beside the output (confirmed).**
`Compile.hs:827`: `unitDir = takeDirectory out </> "units"`. A test that writes
its `.s` into a temporary directory gets an empty unit cache whatever
`XDG_CACHE_HOME` says (`check_base.py`'s per-target veccaps cases,
`check_rv64_linux.py`, `check_typed_inline.py`). `fpr build` is unaffected.

**1.3 The unit cache stores assembly, not objects (confirmed).** Cached units
are `…-<tag>.s` files, and `Build.hs` passes the root assembly, every cached
unit and the runtime objects to one `cc` call, which assembles every unit again
at each link. [2026-10-18-COMPILER-BUILD-OPT](2026-10-18-COMPILER-BUILD-OPT.md)
measured `cc` at 12.4 s of a 25.0 s warm logbook build and 20.4 s of a 45.6 s
warm pos1 build.

*Fix:* assemble each unit once into a `.o` beside its `.s`, keyed by target,
`cc` and flags, written with the same `writeWhole` discipline.

**1.4 Programs are rebuilt per hart count (confirmed).** `Build.hs` does not
pass `--harts` to `fpr compile`, so the assembly does not depend on it; only
the link does. `fpr build` has no executable cache (only `fpr run`'s `runKey`
path does). Scripts that loop over hart counts therefore compile the same
program twice: `check_pos_reload.py` (two full POS builds; its own comment puts
each at about 40 s on eight cores), `check_typed_core.py` (8 cases × 1 and 4
harts), the a64 and x64 frame checks, `check_typed_ir_native.py`,
`check_typed_callbacks.py`, `check_typed_vector_reads.py`,
`check_typed_inline.py`. `check_base.py` already does the right thing: one
build with a larger cap, run under `FPR_HARTS`.

*Fix:* reuse the `runKey` executable for `fpr build -o`, and build once per
program in these scripts.

**1.5 The runtime-object key is too broad, and objects build serially
(confirmed; race suspected).** `Build.hs:199` adds
`-DFPR_POSIX_CODEGEN_REV=<codegenRev>` and `-DFPR_NHARTS=<n>` to the cflags of
all 22 objects, and the cache directory name hashes those cflags. Only
`machine/posix/os_module.c` reads the codegen revision, and only `runtime.c`,
`actors.c`, `machine/unix/main.c` and `park.c` read `FPR_NHARTS`. So every
codegen revision bump (135 now) rebuilds every object for every hart count,
and each new `--harts` value rebuilds 22 files instead of 4. The default hart
count is the host's core count, and tests use 1, 4, 8 and 10. Objects compile
one after another (`mapM objectFor`) and `cc -c` writes straight to the final
path. Six shared-cache jobs use `--harts 4` and can start together, so they may
compile the same set concurrently, and one could link a half-written `.o`
whose modification time already passes the freshness test (not observed).

*Fix:* pass these two defines only to the files that read them (or move them
into a generated header per configuration); compile objects in parallel and
write each to a temporary name and rename.

**1.6 Six Base jobs interpret the compiler with `runghc` (confirmed).**
`check_typed_ir_kernels.py`, `check_workers.py`, `check_reuse.py`,
`check_self_loops.py`, `check_specialization.py` and `check_case_growth.py`
run `cabal exec -- runghc -icompiler tests/<X>.hs`, loading the whole compiler
as bytecode per job, although `fp-risc.cabal` declares test suites for the same
drivers (`KernelIR`, `WorkersCheck`, `ReuseCheck`, `NullaryConstants`,
`Specialization`, `CaseGrowth`) and `tests/haskell_units.py` exists to run
them. [2026-10-26-HASKELL-TEST-SUITE](2026-10-26-HASKELL-TEST-SUITE.md) puts all
26 compiled suites at about 20 s on six cores. `check_typed_ir_kernels` is the
second-longest Base job (190 s in
`docs/evidence/2026-10-25-test-suite-speed/base-times.json`). Four of the six
also hold `lock='cabal'`, so they queue behind each other.

**1.7 The longest jobs build serially (confirmed).** `examples/ideal/check.py`
builds eight `--cost` programs in a loop and about twelve more one at a time
(149 s in the evidence file); `check_mvu_reload.py` builds ten variants in
sequence (136 s). The builds are independent; a small pool inside each job
shortens the suite's critical path.

**1.8 CI repeats configurations and caches nothing (confirmed; one item
suspected).**
- `check_ci.py` runs its groups one after another.
- `check_registers.py` runs in CI's `host-extra` group and again as the inline
  Base case `registers` (`check_base.py:728`), which `--completed` cannot skip.
- `rv64-typed` (`FPR_TYPED_IR_BACKEND=mixed`, `--typed-ir`) and `host-extra`'s
  `runtime` variant cross-build the same programs into separate cold caches.
  `Compiler/Options.hs` maps unset and `mixed` to the same granularity, so the
  compiler output appears identical and only the log assertions differ
  (suspected duplicate; worth confirming before merging them).
- `.github/workflows/ci.yml` caches neither `dist-newstyle` nor `~/.cache/fpr`.

**1.9 `make` re-stamps an unchanged compiler (confirmed).** The `fpr` recipe
always copies `$(cabal list-bin fpr)` over `./fpr`, and `fpr-dev` is phony, so
`./fpr` gets a new modification time even when nothing was rebuilt. `runKey`
stamps the compiler binary, so every `fpr run` cache entry is invalidated by a
no-op `make`. Copying only when the bytes differ (or hashing the binary in
`runKey`) avoids it. Separately, `bare-metal`, `posix` and
`bare-metal-builtin` recompile their runtime C on every invocation, and
`check_typed_ir_arc.py` drives about seventeen `make bare-metal-builtin` calls.

**1.10 Dependency units are keyed on whole-program hashes (suspected,
bounded).** Dependency unit names include `shapesHash` (every record shape in
the program) and every unit tag includes `contractHash`, so a program that adds
one record field re-emits every std unit. The comment at `Compile.hs:993-998`
explains why projections need it for correctness. Emission is about 12% of a
compile, so the win is bounded.

## 2. Frontend: inference and source checking

**2.1 `generalize` snapshots the whole environment (confirmed).**
`Infer.hs:329`: `envFtv <- mconcat <$> mapM schemeFtv (M.elems env)`, where
each `schemeFtv` freshens, zonks and deep-forces a scheme. It is called once
per unsigned top-level bind in an SCC (`:1985`) and once per local function or
lambda `let` (`:1166`), each time against an environment holding every builtin,
every signature and every bind inferred so far. Top-level schemes are almost
all closed, so the environment's free variables can be tracked incrementally
(or OCaml-style levels can replace the scan, as discussed for Algorithm J).

**2.2 Numeric defaulting re-zonks every operator site for each SCC
(confirmed).** `Infer.hs:1968-1976` iterates `IM.elems sites`, and `iSites`
only grows, so each SCC re-zonks every earlier site; `carrierReps` re-zonks
every carrier. `constrainCarrierSites` (`:963`) filters the whole map by
`k >= first` instead of splitting at `first`, and its `stabilize` restarts
from scratch on each choice. `firstSite` is already captured at `:1903`.

**2.3 Clause lookup is a linear scan of the program (confirmed).**
`clausesOf n = [... | TBind n' ... <- tops, n' == n]` (`Infer.hs:1717`, again
at `:1989`) is evaluated three or four times per bind, after a `nub` over all
bind names. `Safety.hs:294-304` repeats the pattern, and `callsOf` is an
unmemoized function recomputed by the SCC builder, `recursive0` and the taint
passes. `Frontend/Traverse.hs:136` (`sourceGroups`) is the same again. One
`M.fromListWith` grouping fixes all of them.

**2.4 The call graph and measures are built up to five times (confirmed).**
Infer builds its SCC graph; `checkSafety` builds `callGraphOf tops` and runs
`measureCheckCG`, then discards the measure table (`SafetyResult` keeps errors
and suggestions only); `measureCheck tops` rebuilds the graph for the region
context (`Compile.hs:521`), `--cost` and placement.

**2.5 Smaller items (confirmed).**
- `unify` deep-zonks both sides at every recursion level (`Infer.hs:141-151`),
  and `zonk` does no path compression.
- `checkDeclared` runs once per clause of a signed function, and every recorded
  check is re-run against the final solution (`:1798-1807`).
- Appends at the end of accumulators in the inference driver (`:1788`, `:1844`,
  `:1738`) are quadratic in the number of binds.
- The constructor sibling table is rebuilt at each `case` with constructor
  patterns (`Infer.hs:1205`; `icCons` never changes in a run).
- Fixpoints rewrite the whole program each round: struct specialization
  (`Struct.hs:173`, `go (depth + 1) (tops' ++ new)`), linearity
  (`Frontend/Linearity.hs:182`), vector evidence (`Infer.hs:1603-1637`).
- Typed specialization compares a group with itself by `encode`-ing both sides
  (`Frontend/Desugar/Typed.hs:442`), and `compatibilityFor` regroups the whole
  program per fallback function (`:364`).
- `Compile.hs:474` forces every unit's anchors (a name × line scan) only to
  recover unit hashes the `ModUnit`s already hold, and `:476` re-expands
  structs already expanded at `:389`.
- `fpr commit` rechecks the previous, immutable version's interface on every
  commit and parses the new version twice (`Commit.hs:104`, `:132`, `:147`).

## 3. Middle-end and backend

**3.1 `freeVars` is quadratic and on the warm path (confirmed).**
`Core/Syntax.hs:45-55`: `CLet x a b -> freeVars a ++ filter (/= x) (freeVars b)`
filters the whole tail at every `let`, so a let chain of depth d costs O(d²).
The unit cache key (`Core/CacheIdentity.hs:27-31`) recomputes `references`
over the accumulated program on every round of `needed`, then once more for
`external`: about three full passes per unit, on cached units too. The same
idiom is in `Mono.hs` (`n `elem` freeVars b'` at each let), `Core/Opt/Vector.hs`
and the fusion helpers. `Core/Opt/Normalize.hs` already uses an accumulator
form that these can share.

**3.2 The root re-specializes against the whole program on every compile
(confirmed; part suspected).** The root unit is never cached.
`Compile.hs:929-931` qualifies every imported artifact's region program, and
`symbolize importedCore` walks it all before the root's `mono`. Inside
`Mono.specializeCompatibility` the universe is root plus every import, and the
callback and callable fixpoints recompute `calls` and `safe` for every function
each round. How much of that is forced depends on whether a compatibility
callee receives a known function argument.

**3.3 Receive-turn reachability runs per artifact over the whole program
(confirmed).** `Regions.placePrograms` calls `placeWith` per artifact with the
merged program as context, and `ReceiveTurns.hs:122-134` builds the whole
program's edge map with `freeVars` and computes reachability by repeated
`M.filter` over it, per artifact, for both `receivers` and `managed`. The
world-level part is the same for every artifact and can be computed once,
exactly as the cost snapshot now is.

**3.4 Allocator constraint scans start from the front (confirmed).**
`Codegen/Allocate.hs:186`: `within iv = takeWhile ... . dropWhile ((< ivStart iv) . fst)`
walks each reservation group from position 0 for every value; the comment
above it says the cost is "the number of reserving instructions a range
spans", which is not what this computes. `crossesCallV` and `crossesClobberV`
do the same over call and clobber positions, and run again on the spill path
and for `stCrossing`. An `IntMap` keyed by position, or one sweep in start
order, makes these proportional to the range.

**3.5 Verification is repeated per function (confirmed).** The lowered
program is verified before and after simplification, and `Simplify` runs
`verifyFn` after each of its passes: about seven verifications per function,
each recomputing the CFG and an iterative dominator fixpoint that compares
whole maps per round (`ControlFlow.hs:26-30`). Kernels re-verify the kernel
and its callbacks before and after simplification, and the targets then run
their form, function and allocation checks (the last recomputing physical
liveness). None of it can be switched off for development builds. Verifying at
pass boundaries in a checked build and once at the end otherwise would keep the
guarantee where it is consumed.

**3.6 Simplify passes contain quadratic scans (confirmed).** `usedOutside`
(`Simplify.hs:142`) rebuilds every other block's uses for each block;
`threadJoin` rebuilds `defsOf` per join; `dropDeadPure` recomputes uses and
compares whole functions per iteration and runs after every pass;
`fuseFloatTrees` evaluates `fuse ds o a b` twice.

**3.7 The inliners always run all their rounds (confirmed).** The typed
linked inliner (`Core/Typed/Pipeline.hs:137-157`) runs all three rounds,
rebuilding the catalogue, planning, walking every owned definition and
verifying, even after a round that inlined nothing. The compatibility inliner
(`Inline.hs:53`) also always runs three rounds and re-measures the whole callee
with `size` at every call site, with no early stop. The typed inliner already
weighs each template once per snapshot with a budget cutoff; the compatibility
one can do the same.

**3.8 Fusion re-derives safety per node (confirmed).**
`fuseVecFixWithImports` re-walks every definition each round, evaluates
`fusedAt` at least three times per node, and each `fusedAt` calls
`fusionSafe`, which re-walks the callback's transitive callees with no memo.
`nestPipelinesWithImports` runs twice on unchecked definitions. One safety map
per round removes most of it.

**3.9 Notes are always built and printed (confirmed).** `mapM_ putStrLn vnotes`
forces `emNotes`, which forces `declines` (re-running `vecSpec` at every full
`Vec` spine that `kernelSites` already planned), a `nativeNote` per function
(which recovers `frame=` by splitting the rendered header line) and fusion's
"NOT fused" notes. Under `fpr build` stdout goes to a log read only on failure.
The [optimization remarks](2026-10-27-OPTIMIZATION-REMARKS.md) work is the
natural place to make these lazy.

**3.10 Metrics re-parse the rendered assembly (confirmed).** The
`native-insns-v1` instruction costs re-scan rendered text per line
(`RV.hs:647-655`, `A64.hs:873-889`, `X64.hs:709-715`), and `Bounds.analyse`
checks branch targets against a label list (O(branches × labels)). Counting from
the selected instructions before rendering would avoid both.

**3.11 Smaller items (confirmed).** `Workers` computes `vectorCallbacks`
twice and builds each candidate body once to measure it and again to emit it;
`Reuse` repeats `aliases` and `consume` between `candidate` and `additions`;
kernel emission rebuilds its available program and re-lowers shared callbacks
per kernel, then discards duplicate kernel functions (`Codegen.hs:538-555`);
`linkArtifacts` checks each imported contract by a linear symbol scan on each
relink; `Erase.project` sorts a record's fields per projection.

## 4. Runtime

**4.1 A bounded send walks the message graph up to three times (confirmed).**
`dc_budget` (admission), then `dc_size` in `msg_copy_held_in`
(`runtime.c:1221`), then `dc_dup`. Unbounded inboxes skip the first. The
per-turn state copy pairs `dc_size_in` with `dc_dup` the same way, and repeats
the size walk without the retain slab if retaining fails. The admission walk is
explained at `runtime.c:942-944`; the size and copy walks could be one pass
that falls back when the slab overflows.

**4.2 `refill` scans the backlog up to four times (confirmed).**
`actors.c:1191`: `while (h->rq_len < RQ_CAP) { acb_t *a = select_backlog(h); ...`,
and each `select_backlog` is a full locked walk with an LCG step per entry.
One pass can choose all `RQ_CAP` (4) admissions.

**4.3 `arc_lock` is taken several times per message (suspected
contention).** A bounded send takes it to hold the slab, for
`fpr_arc_incref`, and for `fpr_slab_unhold`; each received root dropped at turn
end takes it again. Nothing batches these; `runtime.c:2502` assumes contention
is negligible, which has not been measured at ten harts.

**4.4 `Os.write` installs a signal handler on every call (confirmed).**
`machine/posix/os_io.c:104`: `signal(SIGPIPE, SIG_IGN)` per write. Once at
startup is enough. `Os.read` and `Os.readFile` also copy their buffer again
into the result string.

**4.5 Smaller items.** The generic `Vec` tier grows by doubling where the final
length is known (`h_range`, `h_iota`, `h_slice`, `fpr_vec_map`); `Sys.arena`
copies its result twice; `Mod.fn` does a locked linear string scan per call
(`mod.c:203-213`); the render buffer macros read `fpr_hart()` per character,
which is an asm read on ESP-IDF.

## 5. Sol

**5.1 GPU initialisation runs on every script run (confirmed; cost
suspected).** `Sol/Main.hs:292`: `gpu <- Gpu.initGPU` inside the transaction
loop, so once per attempt, whether or not the script uses `Vec.map`. Unless
`SOL_GPU=0`, non-Apple builds set up an EGL display and GL context
(`vecgpu.c`). A failed probe is repeated each attempt. The startup measurements
in [2026-09-29-Sol-Improvements-Needed](2026-09-29-Sol-Improvements-Needed.md)
disable the GPU, so this cost is outside them and may be part of the 50-70 ms
gap on Linux. Initialising on first GPU-eligible call removes it.

**5.2 Register frames are maps and calls are by name (confirmed; known).**
`Sol/VM.hs:249`: `frame <- newIORef (M.fromList (zip [0 ..] args) :: M.Map Reg Value)`,
with an `M.lookup` per register read and an `M.insert` per write, although
`fnSlots` is computed at compile time and bound as `slots` (unused).
`Call`/`TailCall` carry a `Name`, looked up in the tabling map and then the
program map per call; HAL and builtin dispatch chain further map lookups and
string comparisons. The Sol improvements page already lists the map frames.

**5.3 A cache hit re-serialises the prelude and every import (confirmed;
known in part).** The cache key (`Sol/Cache.hs:92`) encodes the prelude text
and the full AST of every import, then hashes the bytes with FNV; `readEntry`
hashes the payload again, decodes a second copy of the key and deep-forces the
result. A key from the source hash, each module's pin hash and a constant
prelude hash avoids re-encoding.

**5.4 Smaller items (confirmed).** Actor mailboxes append with `q ++ [x]`
(`VM.hs:533`); the prelude's `Str.mapGo` and `Str.repeat` rebuild the whole
accumulator per character (`Preamble.hs:259`, `:262`), and `Str.indexFrom`
allocates a `substr` per position although a native `strIndexFrom` exists;
tabling, on by default, rebuilds its map to refresh an LRU tick on each hit and
evicts by a linear scan of 4,096 entries; the JIT caches successes only, so a
function it cannot compile is re-analysed on every call; `BStr.at` decodes from
the start of the buffer, although `Val.hs:151-153` describes an ASCII fast path.

## Suggested order

1. **Cheap and local:** shared test cache and the `environ.get` pattern (1.1),
   `--harts`-free builds in the looping scripts (1.4), per-file runtime defines
   and atomic object writes (1.5), compiled suites instead of `runghc` (1.6),
   `signal()` once (4.4), lazy GPU initialisation (5.1), early exit in both
   inliners (3.7), `make` copying only on change (1.9).
2. **Build structure:** `.o` per cached unit (1.3), an executable cache for
   `fpr build` (1.4), parallel builds inside the longest jobs (1.7).
3. **Compiler, after a profile:** `generalize` (2.1), defaulting (2.2), clause
   grouping (2.3), one call graph and measure table (2.4), linear `freeVars`
   (3.1), one receive-turn reachability (3.3), the allocator scans (3.4).
4. **Runtime and Sol:** single-pass size-and-copy (4.1), one backlog scan per
   refill (4.2), array frames and resolved call targets in the Sol VM (5.2).

Each compiler change should land with byte-identical emission and its
`tests/check_compile_budget.py` delta, as the 10-26 budget work did.

## Checked and fine

Assembly for a unit is generated once and written atomically; the run cache
writes by rename; `runKey` hashes the transitive `use` closure. Allocation
zeroes only the rounding pad. Strings carry their length and `strJoin` makes one
allocation. Receive scans a bounded set of channels. ARC table growth is
amortised. Unchanged loop state is nearly free to re-copy (`dc_retained`). The
typed inliner weighs templates once per snapshot. `Core/Opt/Normalize` and
`Compiler/Native/Imports` reference collection are linear. Each source file is
parsed once per compile. The Sol prelude is parsed and compiled only on a cache
miss.

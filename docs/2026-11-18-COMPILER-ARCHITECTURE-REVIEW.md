# Compiler source architecture review

> **Status, 2026-11-21.** Commit `d2a07465` resolved findings 2 (the
> transaction attempt loops unified onto `runTxAttempts` + `TxAttemptConfig`),
> 4 (`checkedInterface` takes `CompileArguments` directly), 5 (unified cache
> identity in `Sol/Cache.hs`), 6 (`FPR_TIMINGS` instrumentation in
> `Compile.hs`), 7 (`Sol.KIR` renamed `Sol.JitIR`), 8 (`deploy/README.md`)
> and 9 (root relics removed). Finding 10 is partially addressed
> (`Compile.hs` restructured internally, still 1748 lines); findings 1 (the
> dual-assembler/JIT decision) and 3 (`Txn.hs` split, 2106 lines) remain
> open. Verified post-unification on both paths: the script path retries a
> forced conflict and lands deferred effects exactly once
> (`tests/procdefer.sol` under `SOL_FORCE_RETRY=1`); the REPL ignores
> `SOL_FORCE_RETRY` by config gate and commits on attempt 1; the check
> suite runs 87 PASS with 4 pre-existing representation/ordering failures
> (`result-sizes`, `layout-raw`, `layout-raw-i64`, `reactor`) unrelated to
> the transaction machinery.

Date: 2026-11-18. Kind: review. Applies to `main` at `69da12ca` plus the
uncommitted P2 typed-lowering working tree (that in-flight work is noted,
not judged). **Method:** a source reading of the module tree, both compile
drivers, the cache family, the Sol runtime modules and the repo layout,
with call sites read rather than inferred from names. Nothing was built,
profiled or benchmarked. This page deliberately does NOT repeat the
[repeated-work findings](2026-10-28-REDUNDANT-WORK-REVIEW.md) (performance
redundancy, findings there stand) or the performance records; this page is
about *structure*: redundancy, layering, and features that feel bolted on.

Scale reference: `compiler/` is ~64.5k lines of Haskell across ~90 modules.
The tree was substantially reorganized since late October (Frontend/, Core/,
Codegen/Target/, Compiler/, Arc/, Resource/, Ownership/, Source/ now exist
as owners; `FPRISC.hs` remains as a marked compatibility facade).

## What is in good shape (so the findings are read in proportion)

- **One binary, profiles as subcommands.** `app/Main.hs` dispatches; the
  profile table (`Target.hs`) separates ISA from operational profile;
  HostedBytecode is literally a backend of the one compiler
  (`--target=bytecode` routes into the Sol pipeline). This is the cleanest
  architectural decision in the tree and it is holding.
- **Migrations are explicit.** `FPRISC.hs` says "Compatibility facade. New
  compiler code imports the owning modules directly." The erased-vs-typed
  lowering duality (`Codegen/Lower.hs` vs `LowerTyped.hs`) is migration
  scaffolding with a stated end state ("LowerTyped agrees with the erased
  lowering" is its acceptance test). Facades and scaffolds are marked as
  such — the tree does not hide its transition states.
- **Caching shares a core.** All five cache families in `Sol/Cache.hs`
  (unit, module, prelude, parse, library verdicts) share `readEntry`/
  `writeEntry`/schema/magic; the per-family keys are the only divergence.
- **The editor integration is small.** `Compiler/Editor.hs` enters compiles
  as an explicit `Editor.Report` parameter, `Editor.disabled` by default,
  at 11 sites across two drivers. The seam is honest.

## Findings

| # | Finding | Severity | Type |
|---|---|---|---|
| 1 | Two A64 and two X64 instruction emitters in one binary | structural | redundancy (decision needed) |
| 2 | Three transaction attempt loops in the Sol driver | structural | redundancy |
| 3 | `Sol/Txn.hs` is an everything-module (2112 lines, ~143 functions) | structural | cohesion — **resolved 2026-11-22**: the state/filesystem layer split into `Sol.TxnState` (1020 lines); the protocol remains `Sol.Txn` (1146), one-way import, re-export keeps importers unchanged ([record](2026-11-22-TXN-SPLIT.md)) |
| 4 | `checkedInterface` re-enters the compiler by mutating argv | mechanism | inelegance |
| 5 | Five cache key derivations re-derive identity independently | mechanical | drift risk |
| 6 | Only one of the two compile drivers is instrumented | mechanical | asymmetry |
| 7 | Three unrelated meanings of "kernel" | naming | confusion |
| 8 | Non-compiler projects in this repo (`deploy/`, printer tools) | repo | placement |
| 9 | Repo-root relics and build artifacts | repo | hygiene |
| 10 | `Compile.hs` is the last un-split giant driver | structural | cohesion |

### 1. Two A64 + two X64 emitters (confirmed)

`Codegen/Target/A64.hs` (1718 lines) and `X64.hs` (1820) emit the AOT
tier's register-allocated typed IR. `Sol/AsmA64.hs` and `Sol/AsmX64.hs`
encode the same two ISAs for the JIT tier's KIR stack machine. That is
~3.5k lines of duplicated ISA knowledge — immediate encodings, branch
ranges, shift/extend forms — that must be kept correct twice (the board
and QEMU gates exercise the AOT emitters; the JIT emitters are exercised
by the Sol suites; nothing cross-checks an encoding fact between them).

They are NOT trivially mergeable: different IRs, different register
models, different relocation strategies (in-place bytes vs `.s` text).
The realistic factoring is a shared *encoder* layer (instruction encodings
and range checks only, no instruction selection) — worthwhile only if the
JIT tier is a permanent resident. The strategic question this finding
should force: **is the KIR/JIT tier expected to shrink as the typed AOT
tier matures?** If yes, declare the Sol asm pair migration-bound (like the
erased lowering) and do not invest in the merge; if no, build the encoder
layer. Either answer is fine; drift is what is not.

### 2. Three transaction attempt loops (confirmed)

`Sol/Main.hs` carries `runTxLoop` (scripts), `replExecCommit` (REPL — a
descendant of the REPL prototype's copy of `runTxLoop`), and the
journal-recovery path. The two live loops duplicate: fresh transaction +
actor join, commit, the `Committed`/`Conflict` reporting prose (including
the guarded-retry refusal wording, currently verbatim in two places), and
the retry arithmetic. They differ only in what they execute and how
conflicts resolve (silent retry vs bounded command retry). Drift has
already happened once (only `runTxLoop` gained the session checked-
definitions and import re-splice machinery). Direction: one
`withAttempt :: AttemptSpec -> IO AttemptResult` where the REPL's
differences are parameters (its own max attempts, its own conflict
handler), so the commit/reporting prose exists once.

### 3. `Sol/Txn.hs` cohesion (confirmed)

2112 lines, ~143 top-level functions spanning: transaction state and
views, fs operations, the fs error model, lock protocol, redo journal and
recovery, saga/Git undo, path logs, realtime escapes, process spawn/PTY
plumbing, temp-dir ownership, retry policy. Each piece is individually
well-commented; the module is the accretion. The seams already exist as
section comments. Direction: split into `Txn.State`, `Txn.Locks` (lock
protocol + reclaim), `Txn.Journal` (journal/recovery/saga), `Txn.Fs`
(operations + the `FsErr` model, which belongs beside `ScriptIO`), and
`Txn.Escapes` — no behavior change, and each split module becomes small
enough to hold in one's head. Do it after the in-flight P2 work lands to
avoid merge tangles.

### 4. `checkedInterface` re-enters via argv (confirmed)

`Compile.hs:204` runs `withArgs ["--check-only", "--lib", file,
"/dev/null"] (compileWithInterface ...)` — the module-interface extraction
re-enters the compiler's own main with mutated global argv, and uses exit
codes as the protocol. It works, but it is the one place where "library
call" is spelled as "call myself through the CLI layer": fragile under
concurrency, invisible to types. Direction: lift the interface extraction
into a direct function of the checked unit (the data is already in scope
inside the same compile — the report ref pattern it uses proves it); keep
the argv path for the CLI only.

### 5. Cache key derivations (confirmed)

`libraryKey`, the unit-cache `cacheContext`, `cachedModule`/`cachedPrelude`
/`cachedParse` each re-derive "executable identity + options + payload
digest" with slightly different spellings (unit key serializes absolute
path + source; library key serializes the spliced module digest + trusted
set; the parse caches key on text). The core is shared; the identity
derivation is copy-paste with drift already visible (options tuples differ
in arity between families). Direction: one `CacheIdentity` record (the
name `Core/CacheIdentity.hs` suggests something like this may already be
planned on the Core side — extend the idea to the Sol caches) with
per-family payload digests.

### 6. Instrumentation asymmetry (confirmed)

The Sol driver instruments its phases (`phase`/`phaseIO`, `SOL_TIMINGS`);
`Compile.hs` contains zero `phase` calls — the native pipeline's stage
timings can only be obtained by external profiling. Given the compile-time
budget culture of this repo, wiring the same two wrappers through the
native driver is a small change that removes a standing blind spot.

### 7. "Kernel" means three things (confirmed)

`KernelKinds.hs` — kinds of the raw-word callback ABI (KI/KD/KS/KB).
`Sol/KIR.hs` — "the kernel IR of the hand-rolled JIT tier" (its own
JI/JD/JW/JB kind system). `Core/Opt/Vector*` — the column kernels. Three
vocabularies, two parallel kind lattices, one adjective. A reader cannot
guess which "kernel" a sentence means. Direction: rename the JIT tier
(the odd one out) — e.g. `Sol/JitIR.hs` — and let KernelKinds/Vector keep
their meanings; or fold the JIT kinds' names into the KIR module. Pure
naming, zero behavior.

### 8. Non-compiler projects under this repo (confirmed)

`deploy/aws-pos1`, `deploy/printer-dashboard`, `deploy/macmini-inventory`,
plus the printer/session tooling in `tools/` (printer_*.py,
printer-dashboard-requirements.txt) are ops tooling for other projects
living in the language repo. They ride along on every clone and every
bundle conversation. Direction: a separate ops repository (or at minimum a
`deploy/README` declaring these are not part of the compiler and excluded
from release bundling — check that `sol-install.py`'s Git-listed snapshot
excludes them).

### 9. Repo-root relics (confirmed)

Tracked: `dispatch.sol` (an example misplaced at the root; its content —
the Vec dispatch lattice — belongs in `sol/examples/` or the docs),
`SPLIT-SOURCE.json` (a relic of a past tree split). Untracked but
resident: `image.elf` (regenerated build artifact, 343 KB), `pos1.log`,
`POS1.txt` (debug leftovers from September). Direction: relocate/relocate
+ delete the untracked artifacts; `.gitignore` the class.

### 10. `Compile.hs` is the last giant driver (confirmed)

1727 lines with a 27-helper `compileMain`/`compileWithInterface` spine and
deeply nested profile branches (builtin/bare-metal/qos/base × hosts ×
lib/export modes). The rest of the tree learned the lesson — `Codegen/`,
`Compiler/Native/`, `Core/Opt/` all exist as splits; the native *driver*
is the remaining monolith, and it is where the profile matrix makes
reading hardest. Direction: split orchestration from per-profile unit
selection (the `prepareChecked`/`selectCheckedUnit` helpers show the
seam), the same discipline `Sol/Main.hs` underwent. Not urgent — nothing
is wrong — but it is the file a newcomer dreads and the file every profile
change touches.

## Suggested order

1. Finding 2 (unify the attempt loops) — small, removes real drift risk,
   no external behavior.
2. Finding 6 (instrument the native driver) — small, removes a blind spot
   the perf records keep hitting.
3. Finding 9 (root hygiene) — trivial.
4. Finding 4 (de-argv `checkedInterface`) — contained, kills a fragility.
5. Findings 3+10 (module splits) — mechanical but best done when the P2
   typed-lowering work lands, to avoid merge tangles.
6. Finding 1 — **decide the JIT tier's fate first**; the answer chooses
   between "build the encoder layer" and "declare migration-bound".
7. Findings 5, 7, 8 — opportunistic.

## Not findings (checked and left alone)

- The five-layer runtime stack (runtime/ C, machine/ C, cbits/, std/
  .fpr, sol/lib .sol) — each layer has a distinct owner and profile; not
  bloat.
- The Core→typed-IR→selector pipeline shape and the erased/typed lowering
  duality — migration scaffolding, tracked by the P2 work.
- `Frontend/` module granularity (Lexer/Normalize/MemoryLayout/
  OwnedMapFold as separate modules) — matches the ownership story.
- One-binary-for-everything (Web/Gpu/JIT linked into `fpr`) — deliberate
  trade documented at the dispatch site; runtime opt-in per feature.

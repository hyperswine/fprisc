# Compile-speed bottleneck analysis: pre-cache work in multi-unit builds

Date: 2026-10-27. Kind: review and bottleneck analysis (`a6043da` in `fprisc`,
`986b025` in `qos`). Follows [2026-10-26-COMPILE-TIME-BUDGET.md](2026-10-26-COMPILE-TIME-BUDGET.md),
which removed register-name `read` parsing, memoized `Region.copyable`/`bounded`
type walks, and added `Core.Typed.Pipeline.ownedOnly` to skip transforming
elided constructor stubs inside the five linked passes. This report measures
what remains on a 38-unit QOS shell compile (`qos/programs/main.fpr`) when the
unit cache is cold versus 100% warm, and traces why a warm-cache rebuild still
spends 87.7% of the cold-compile CPU time and 77.8% of its heap allocation.

## 1. Empirical measurement (`qos/programs/main.fpr`, `--target=qa64`)

Command run against `/Users/jasonqin/Documents/GitHub/qos/programs/main.fpr`
(38 imported module units + `core/prelude.fpr` + root `programs/main.fpr`,
2,323 remote-callable exports):

```sh
FPR_HOME=/Users/jasonqin/Documents/GitHub/qos \
FPR_PATH=/Users/jasonqin/Documents/GitHub/fprisc \
FPR_FOREIGN=/Users/jasonqin/Documents/GitHub/qos/core/foreign.fpr \
/Users/jasonqin/Documents/GitHub/fprisc/fpr --target=qa64 \
  --prelude=/Users/jasonqin/Documents/GitHub/fprisc/core/prelude.fpr \
  programs/main.fpr build/profiles/Main/shell-build/qosapp-a64.s +RTS -s
```

| Metric (`+RTS -s`) | Cold unit cache (38 units emitted) | 100% warm unit cache (all 38 units `(cached)`) | Warm share of cold |
|---|---:|---:|---:|
| Total CPU time | **67.690 s** | **59.351 s** | **87.7%** |
| Mutator (`MUT`) time | 59.587 s | 52.161 s | 87.5% |
| GC time | 8.011 s | 6.939 s | 86.6% |
| Total heap allocated | **69,417,366,704 B** (~69.4 GB) | **54,040,668,928 B** (~54.0 GB) | **77.8%** |
| Bytes copied during GC | 7,139,877,544 B (~7.1 GB) | 5,293,437,864 B (~5.3 GB) | 74.1% |
| Collections (Gen 0 / Gen 1) | 1,045 / 14 | 815 / 13 | — |
| Maximum residency | 1,125,882,656 B (~1,126 MiB) | 1,125,754,176 B (~1,126 MiB) | 100.0% |
| Total memory in use | 2,681 MiB | 2,309 MiB | 86.1% |

Emitting target assembly across all 38 dependency units plus prelude accounts
for only **8.34 s** of CPU time (67.69 s − 59.35 s) and **15.4 GB** of heap
allocation (69.4 GB − 54.0 GB). The remaining **59.35 s** and **54.0 GB**
happen **before** `emitUnit` checks `cached <- doesFileExist path` at
`compiler/Compile.hs:936`.

## 2. Root causes in the compiler pipeline

### 2.1 Quadratic whole-program `Cost.costProgram` inside `Regions.place` ($39\times$ whole-program fixpoint)

In `compiler/Compile.hs:515`, `regionContext` builds its baseline `world`
program from the **pre-linked** `compileRaw finalTops`:

```haskell
regionContext = Regions.context (fst (measureCheck tops)) (compileRaw finalTops)
```

Later, at `compiler/Compile.hs:904`, `regionArtifacts` runs `Regions.place` on
every artifact in `Linked.linkedArtifacts linked` (39 artifacts:
`RootArtifact`, `PreludeArtifact`, and 37 `DependencyArtifact`s):

```haskell
regionArtifacts = M.map (runTurns . artifactRaw) (Linked.linkedArtifacts linked)
```

Each artifact's `artifactRaw` has already been transformed by the `Linked`
pipeline (two rounds of callback specialization, cross-unit inlining,
pair-free vector reads, normalization, and fusion). Inside
`compiler/Compiler/Native/Regions.hs:89-96`, `Regions.place` checks whether the
artifact's lowered definitions match `world`:

```haskell
let world = analysisProgram base
    local = analysis "$region.local." (programNames world) input
    ...
    allCode = local `M.union` world
    same = M.isSubmapOfBy (==) local world
    view = if same then base else derive measures allCode
```

Because `local` is post-inlining/post-normalization and `world` is
pre-inlining/pre-normalization, `same` (`M.isSubmapOfBy (==) local world`)
evaluates to `False` for nearly every artifact. Whenever `same` is `False`,
`derive measures allCode` runs a fresh whole-program fixed-point cost analysis
(`Cost.costProgram measures M.empty allCode`) over all ~2,500 functions in
`allCode`. For a 39-artifact program, `Cost.costProgram` runs **39 times** over
the whole merged program instead of once.

### 2.2 All 39 artifacts run the full `Linked` + `Regions` pipeline before checking the unit cache

In `compiler/Compile.hs:883-967`, unit-cache lookup (`doesFileExist path` at
line 936) sits at the very end of the per-unit pipeline:

1. `linkedResult` (`Compile.hs:883-894`) forces all 39 `NativeCore` artifacts
   through seven `Linked` stages (`linkArtifacts`, `specializeLinked` $\times 2$,
   `inlineLinked`, `planVectorReadsLinked`, `normalizeLinked`, `fuseLinked`).
2. `regionArtifacts` (`Compile.hs:904`) and `declarationsResult`
   (`Compile.hs:905-911`) force `Regions.place` across all 39 artifacts so that
   `tgtPoolResetters` (`Compile.hs:914`) is known for the whole program.
3. In `emitUnit` (`Compile.hs:919-936`), computing the cache filename `path`
   hashes `placed = artifactRegions (Linked.artifactId artifact)` and
   `tgtPoolResetters linkedTgt` before checking `cached <- doesFileExist path`.

As a result, even when every `.s` unit file in `build/units/` is warm, the
compiler still runs all seven `Linked` passes and `Regions.place` on all 39
artifacts. Moreover, while [2026-10-26-COMPILE-TIME-BUDGET.md](2026-10-26-COMPILE-TIME-BUDGET.md)
made the five optimization passes skip transforming elided constructor stubs
via `ownedOnly`, every `Linked` pass still calls `replaceClosed` $\to$
`eraseClosed` (`compiler/Compiler/Native/Core.hs:106-120`) and
`linkArtifacts` (`compiler/Compiler/Native/Linked.hs:67-132`), which re-erases
and re-verifies every definition (including elided constructor stubs and
unchanged imported units) 7 times per compile.

### 2.3 All ~320 program constructor stubs are duplicated into every unit's `NativeCore`

In `compiler/Compile.hs:514`:

```haskell
nativeUnit unit = compileSelected PreserveCallbacks (selectUnit (M.keysSet consAll) unit)
```

`selectUnit (M.keysSet consAll) unit` copies all ~320 constructors declared
anywhere in the 38-module program into **every** unit's `NativeCore`. Even a
5-function dependency module carries ~325 definitions in its `NativeCore`
($39 \times 320 \approx 12,480$ constructor definitions across the artifact
map). Although `ownedOnly` skips rewriting non-owned stubs during optimization,
those 12,480 definitions are still:

- constructed and closed in `nativeUnit` (`closeProgram`),
- erased in `replaceClosed` (`eraseClosed`) on every `Linked` step,
- checked by `verifyClosedArtifacts` / `linkArtifacts` on every `Linked` step,
- converted by `analysis "$region.local."` in `Regions.place`, and
- only removed at `emitted = M.withoutKeys prog elide` inside `emitProgram`
  (`compiler/Codegen.hs:334`).

### 2.4 Whole-program surface passes, type inference, and `show`-based AST hashing run on all 38 spliced modules every invocation

Before reaching `NativeCore`, `compiler/Modules.hs` and `compiler/Compile.hs`
process the entire transitive module graph from source on every compile:

- `loadProgram` (`compiler/Modules.hs`) parses all 38 imported `.fpr` files and
  splices their top-level declarations into `tops0RL`.
- `hashAST` (`compiler/Modules.hs:98-111`) serializes entire AST structures via
  `show` into a lazy `String` (`[Char]`) and folds FNV-1a one character at a
  time; it is also called for `preludeTops`, `contractHash`, and `shapesHash`
  in `compiler/Compile.hs:457-498`.
- `expandPathLits`, `aritySpill`, `expandStructs`, and `applyPreconds` each run
  twice: once over the full spliced program (`tops0RL`) and a second time per
  unit in `units0L` (`compiler/Compile.hs:347-421`).
- `inferTopsChecked`, `checkSafety`, `specializeCheckedSource`,
  `checkLinearity`, and `measureCheck` run over the entire 38-module spliced
  program even when only the 4-line root `programs/main.fpr` changed.

## 3. Prioritized remediation plan

1. **Build `regionContext` from the post-linked program once (fixes §2.1):**
   Construct `regionContext` from the union of the post-linked `artifactRaw`
   programs in `Linked.linkedArtifacts linked` (or compute a single post-linked
   `Regions.Context` after `fuseLinked`) rather than from pre-linked
   `compileRaw finalTops`. Then `M.isSubmapOfBy (==) local world` in
   `Regions.place` is `True` for every artifact, running `Cost.costProgram`
   **once** instead of 39 times.
2. **Lookup constructor stubs from a shared table instead of duplicating
   `consAll` into every unit (fixes §2.3):**
   Keep each constructor definition only in its defining unit's `NativeCore`
   (or in the shared `Linked` lookup table) so `closeProgram`, `eraseClosed`,
   `linkArtifacts`, and `Regions.place` do not carry ~12,480 redundant
   constructor definitions across 39 artifacts.
3. **Avoid re-erasing and re-verifying unchanged definitions on every `Linked`
   step (fixes §2.2):**
   Erase to untyped `Core.Program` once at the end of the `Linked` pipeline (or
   lazily when needed by `Regions` / `Codegen`) rather than inside every
   `replaceClosed` call, and restrict intermediate `Linked` re-verification to
   definitions whose bodies or imports changed in that pass.
4. **Persist checked module interfaces / lowered unit summaries across runs
   (fixes §2.2 & §2.4):**
   Cache per-unit checked interfaces (exported schemes, contracts, inlinable
   templates, `poolResetters`, and unit input hash) keyed by the unit's
   transitive source hash so warm builds can check `doesFileExist path` and
   skip re-inferring and re-optimizing unchanged dependency units.

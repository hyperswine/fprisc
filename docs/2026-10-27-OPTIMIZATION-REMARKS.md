# Optimization remarks: the compiler explains its performance decisions

Date: 2026-10-27. Kind: goal / plan. Status: proposed, nothing implemented.
Applies to `main` at `4f56c95` (codegen revision 135). Builds on
[structured diagnostics](2026-10-25-STRUCTURED-DIAGNOSTICS.md),
[the cost pass](2026-10-02-COST-PASS.md),
[bounds in signatures](2026-10-02-BOUNDS-IN-SIGNATURES.md) and
[the performance plan](2026-10-26-PERFORMANCE-PLAN.md).

## Goal

When a function is slower than it looks, the compiler already knows why: it
declined to inline a call, kept a callback generic, left a value tagged, kept
an overflow or bounds check in a loop, spilled the accumulator, or could not
reuse a cell across an opaque call. Today almost all of that is decided by a
`Maybe` or a `Bool` and thrown away. This plan turns those decisions into
**remarks**: structured, located records of an optimization that was applied
or declined, with the reason and, where one exists, a mechanical fix. The
same records feed four consumers:

1. `fpr compile`/`fpr build` (`--remarks`), as located text;
2. a machine-readable stream (`--remarks=json`) for tools;
3. the fpr-lang editor extension, as diagnostics, inlay hints and code lenses;
4. **expectations** in signatures (`| expect tail`), which turn a remark the
   author cares about into a compile error, the way `| work f <= e` already
   turns a cost bound into one.

The rule that keeps this useful: **remarks describe performance, never
correctness, and they are quiet by default.** Unannotated code gets remarks
only where they are likely to matter (loops, recursive groups, receive
loops). Code that states an expectation gets a hard guarantee. A remark the
user learns to ignore is worse than none.

## Where things stand

### What already reports

| Mechanism | Where | What it says | Limits |
|---|---|---|---|
| `vec note` declines | `Codegen.declines` | a `Vec.map/filter/fold` site runs in the GENERIC apply tier, and why (capture count, record dual, closed arithmetic) | reasons are hard-coded strings; stdout; owner name only; lost on a unit cache hit |
| Typed fusion refusals | `Core.Typed.Fusion.Decline`/`FusionNote`, `Core.Typed.FusionSafety.Reason` | two element passes not fused, with a structured reason | the model to copy; printed to stdout on every build; owner names, no position; unresolvable callbacks and op mismatches still decline silently |
| Per-function backend line | `Codegen.Allocate.Stats` → `nativeNote` | `typed-ir-backend: f native (frame ..., spills=..., reloads=..., loops=...)` | per-function spill counts already exist, but as text in an assembly header comment and a stdout line, per function rather than per loop |
| Pass reports | `Core.Opt.Pipeline.PassReport` | `# private workers: fields=N scalar=M`, `# private consuming workers: N` | counts only |
| Receive turns | `ReceiveTurns.hs`, `FPR_RECEIVE_NOTES` | per self-tail group, a region or a `(declined)` note with a `Left` reason string | the best decline reporting outside fusion; stderr; declined groups are only counted without the knob |
| Preconditions | `Precond.PreNote`, `FPR_PRECOND_NOTES` | discharged / runtime check / builtin trap per obligation | structured, rendered as text |
| Cost equations | `Cost.hs`, `fpr build --cost` | `work`/`alloc` per root function, ω terms for opaque callees | root unit only; semantic Core allocation, before reuse and regions |
| Declared bounds | `| work f <= e`, `| alloc f <= e` | `Cost.Verdict`: PROVEN / OVER / UNPROVED, errors under `=== COST: ERRORS ===` | the model for expectations below |
| Apply counts | `FPRC_APPLY`, `Compile.applyReport` | per unit: `fpr_apply` dispatches, PAP creations, static descriptors, counted from assembly comments | per unit, not per site |
| Dumps | `FPR_DUMP_CORE`, `FPR_TYPED_IR=dump\|dumplowered` | the program after passes | the expert's tool; nobody reads it in an editor |

There is no machine-readable diagnostic output anywhere in the compiler.

### What is missing

1. **Reasons are discarded at the decision.** Most passes decide with a
   `Maybe` or `Bool` and keep nothing:
   - the checked inliner (`Core.Typed.Inline`) refuses recursive callees, a
     weight over the limit (24, or 64 when the caller is recursive), callees
     that use a forbidden global, arity mismatches and failed contract
     instantiation, all silently;
   - callback specialization (`Core.Typed.Callback`) refuses past its budgets
     (arity 64, depth 12, 256 clones, 60,000 nodes) or on a unification
     failure, and falls back to a direct indirect or PAP call;
   - `Workers` admits a scalar worker only for functions reachable from a
     loop, with at most 8 parameters, a body of at most 1,024 nodes, an
     Int/Bool signature and room in a 20,000-node budget, and field workers
     under their own limits; `Reuse.reuseProgram` refuses bodies over 256
     nodes, more than 64 parameters and every failed uniqueness proof;
   - the guarded vector fast path (`Codegen.VectorRead.canRead`) and loop
     motion (`Codegen.LoopOptimize`) return `Bool`.

   Two passes compute reasons and drop them: `Core.Typed.Specialize.declines`
   is exported and never called, and the typed lowering's `planDeclines`
   reach `NativeCore`'s compatibility map, which is only ever read with
   `keysSet`. Those are the cheapest remarks to surface.
2. **Notes are strings on stdout**, interleaved with build output, and only
   for units emitted in this run: `Compile.emitUnit` returns `"cached"` before
   `mapM_ putStrLn vnotes`, so a warm build prints none of them, while typed
   fusion notes print on every build. Running the same build twice gives
   different output.
3. **Locations stop at erasure.** Typed Core carries `exprOffset :: Maybe
   SourceOffset` and an `Origin`; untyped `Core.Syntax` and `Codegen.IR`
   carry neither. Passes before erasure (inlining, callback specialization,
   vector reads, normalization, fusion, region analysis) can point at a source
   site. Passes after it (workers, reuse, `Codegen.Simplify`, loop motion,
   the allocator) know only the owning function.
4. **`--check-only` stops before optimization** (`Compile.hs`, `when checkOnly
   exitSuccess`, before per-unit codegen), so the editor's cheap path cannot
   see any of this. That is right for keystroke latency; remarks need a
   second, slower path.
5. **The editor server is line-shaped.** The fpr-lang extension's server is a
   zero-dependency Node analyzer that never runs the compiler; its own notes
   name `fprc`-as-diagnostics as the next step. Nothing in this repository
   defines an output it could consume.

## Design

### 1. One record: `Diagnostic.Remark`

```haskell
data Remark = Remark
  { remarkKind     :: RemarkKind      -- what decision (see the catalogue)
  , remarkOutcome  :: Outcome         -- Applied | Declined Reason
  , remarkPass     :: String          -- the pass that decided, for --remarks=all
  , remarkOwner    :: String          -- source definition, as Diagnostic's owner
  , remarkSite     :: Site            -- where, as precisely as the pass knows
  , remarkHeat     :: Heat            -- Cold | InRecursiveGroup | InLoop Int | InReceiveLoop
  , remarkFix      :: Maybe Fix       -- a mechanical suggestion, if one exists
  }
data Site = AtSpan SourceSpan | AtOffset SourceOffset | AtCall String Int | AtDefinition
data Outcome = Applied | Declined Reason
```

`Reason` is a closed sum per kind, never prose: the renderer owns
the words, as `Core.Typed.Fusion.renderNote` already does for fusion. `AtCall
g k` means "the k-th call to `g` in the owner", the stable handle a post-erasure
pass can name without a source position (resolution below).

A remark projects to a `Diagnostic` with `Severity = Note` and a new
`DiagnosticCode` constructor `OptimizationRemark RemarkKind`, so it shares
`Diagnostic.Render`'s location resolution and the CLI's `file:line:col:`
rendering. `DiagnosticCode` has only error codes today; this is its first
non-error family. A remark does not live in `iErrs` or any error list: no
remark can fail a build except through an expectation (section 7).

### 2. Producers: `Maybe` becomes `Either Reason`

Each decision point already computes its reason to make the choice; the change
is to return it. In order of value:

The reason constructors below name the conditions each pass tests today.

| Pass | Decision | Reasons to record |
|---|---|---|
| Checked inliner (`Core.Typed.Inline`, run as `Linked.inlineLinked 3 24 64`) | inline a call or not | `RecursiveCallee`, `OverWeight weight limit`, `UsesForbiddenGlobal g`, `ArityMismatch`, `ContractInstantiation`, at refused sites in a loop or recursive group. The result already keeps the call site's `exprOffset` |
| Callback specialization (`Core.Typed.Callback`) | clone a higher-order callee per callback, or call through `fpr_apply` | `OverArity`, `TooDeep`, `TooManyClones`, `OverNodeBudget`, `Unification`, `NoKnownArgument`, `Unstable` |
| Structure specialization (`Core.Typed.Specialize`) | specialize a call over a known structure, or keep the generic call | surface the existing `declines`; add `StructureNotKnown position` at the site gate |
| Struct/sig monomorphization (`Struct.hs`) | inline a sig record, or pass it at runtime | `SigArgumentNotLiteral`: the first-class fallback, where an ops record is passed like a dictionary |
| Typed lowering (`planDeclines`) | typed path or compatibility path for a function | surface `compatibilityReason`, which already exists |
| `Codegen.declines` (vec sites) | column kernel or generic tier | already has reasons: make `why` a constructor |
| `Workers` | scalar or field worker with raw parameters | `NotLoopReachable`, `TooManyParams n`, `BodyTooLarge n`, `SignatureNotScalar`, `VectorCallback`, `OverBudget` |
| `Reuse.reuseProgram` | consuming worker / in-place constructor | `ResetBarrier callee`, `NotReadOnly param`, `BodyTooLarge n`, `TooManyParams n`, `Excluded` |
| Typed fusion | fuse adjacent element passes | already structured; add the two silent cases and the site |
| Compatibility fusion, `Core.Opt.Vector` pipeline plans | fuse or plan a pipeline | `fusionUnsafeReason` already returns a string; pipeline plans refuse stage counts outside 2-16, more than 7 args, no filter, a closure over 64 |
| Guarded vector reads (`Codegen.VectorRead.canRead`) | inline read or C entry | `FastPathOff`, `NotWord64`, `ProfileHasNoFastPath`; the bounds check itself is always kept |
| Receive turns, regions | loop/call region or trampoline | the existing `Left` strings become constructors; absorbs `FPR_RECEIVE_NOTES` |
| `Codegen.LoopOptimize` | hoist an invariant | `NoUniquePreheader`, `NotSpeculatable op`, `MoveLimit`, `RematerializableStillRead`, `OverPressure class n budget` |
| `Codegen.Simplify`, then the planned interval analysis | keep an overflow check | `CheckKept op` now; `Unproved` vs `Removed` once step 4.4 of the performance plan lands |
| `Codegen.Allocate` | spill | per natural loop rather than per function: values spilled, loop depth, class |
| Tail calls (`Codegen.Lower.lowerTail`, kernel lowering) | jump or call | see below |

**Tail calls.** `lowerTail` turns a saturated call to a known global into a
jump (`TBr entry` for self calls, `TTailCall` otherwise). ARC lowering releases
owners *before* the tail call, so drops do not break tail position. The cases
that do, all silent today:

- `LocalHead`: the callee is a local or a parameter, so the call goes through
  generic apply and returns (`TRet`). In a loop this is a frame per iteration;
- `KernelCallback`: inside a kernel callback, `TTailCall` is rewritten to a
  call plus a join;
- `SelfLoopsOff`: `FPR_TYPED_IR_SELF_LOOPS=0`, where self calls re-enter
  through the symbol.

Two tail-call conditions refuse the whole function from native emission
rather than the call: a result-type mismatch in `lowerTail`, and more
arguments than the arity ceiling in the x64 and A64 targets. Those are
stronger facts than a remark; they belong in the function's `path` remark
(native or refused, with the reason), next to `planDeclines`.

Every pass keeps its current output exactly; remarks are a by-product. The
acceptance test for each producer is that emitted assembly is byte-identical
with remarks on and off, the same check the compile-time budget stage used.

### 3. Heat: report only where it matters

A declined optimization in straight-line startup code is noise. A remark is
**shown by default** only when its site is

- inside a natural loop of the native IR (`Codegen.ControlFlow`'s loop nest,
  depth recorded),
- in a recursive group (the same groups `Safety` and `Cost` already compute),
- in a receive loop body, or a `Vec` kernel's element function,
- or in a function that declares an expectation.

Everything else is counted per function and visible only with
`--remarks=all` or as the editor's code lens. Later, a profile
can supply heat directly; nothing here depends on one.

### 4. Locations across erasure

- **Stage A, owner.** Every remark has `remarkOwner`, which resolves through
  the existing definition anchors (`Frontend.Diagnostics.bindAnchors`,
  per-unit anchors for imported modules). Never wrong, sometimes coarse.
- **Stage B, typed sites.** Passes before erasure use `exprOffset` and set
  `AtOffset`. This covers inlining, specialization, fusion, vector reads and
  regions, which are most of the high-value kinds.
- **Stage C, after erasure.** A post-erasure pass names `AtCall g k`. Native
  artifacts keep the typed product beside the erased projection
  ([structural checkpoint](2026-10-26-COMPILER-STRUCTURAL-CHECKPOINT.md)), so
  the driver resolves "the k-th call to `g` in `f`" against the typed
  occurrences of `g` in `f`'s typed body. Where inlining has duplicated or
  removed occurrences and the count no longer matches, the remark falls back
  to the owner. Like step 2 of [the spans plan](2026-08-30-SPANS.md), the
  fallback is coarse, never wrong.

Not proposed: a source position on every untyped Core or IR node. As the
spans plan found for the AST, it touches every pattern match in every pass for
precision that the resolution above mostly recovers.

### 5. Caching: remarks survive a warm build

A unit's remarks are written beside its assembly, `<unit>.remarks`, with the
same cache identity and the same write-then-rename (`writeWhole`), and read
back on a cache hit. Linked-program remarks (inlining, specialization) are
computed every build already, since those passes run on every compile. Remark
options stay out of every cache identity: turning remarks on must not
recompile anything, and must not change a single emitted byte.

### 6. Output

CLI:

```
fpr build prog.fpr --remarks            # hot remarks, located text
fpr build prog.fpr --remarks=all        # every decision, applied and declined
fpr build prog.fpr --remarks=json       # one JSON object per line on stderr
```

Text follows the diagnostic renderer:

```
prog.fpr:41:9: remark[inline]: `step` not inlined into the loop in `run`: weight 71, limit 64 at a recursive caller
prog.fpr:47:15: remark[generic-call]: `List.fold` over `addRow` stays a generic call per element: the callback captures a function value
prog.fpr:52:3: remark[spill]: loop in `scan` (depth 1) spills 2 values live across a call: acc (F64), i (Int)
```

JSON is the editor contract and is versioned (`"remarkVersion": 1`):

```json
{"remarkVersion":1,"kind":"inline","outcome":"declined",
 "reason":{"tag":"OverWeight","weight":71,"limit":64},
 "owner":"run","file":"prog.fpr","start":{"line":41,"character":9},
 "end":{"line":41,"character":13},"heat":{"loop":1},"pass":"typed-inline",
 "fix":null}
```

Positions are in decoded characters, as `Source.Span` counts them. LSP's
default is UTF-16 code units; the extension negotiates `positionEncoding:
utf-32` (LSP 3.17) or converts per line. Getting this wrong only shows on
lines with non-BMP characters, which is exactly when it is hard to notice.

The existing `vec note`, fusion and worker strings become renderings of
remarks, printed only under `--remarks` (and the env knobs they replace
become aliases for one release, then retire).

### 7. Expectations: remarks the author wants enforced

The bounds grammar already has the shape: reserved entries after the result
type, kept by the parser as `$work`/`$alloc` and ignored by Sol. Add one more:

```
sumTo : (i : Int | measure lim - i) -> (lim : Int) -> Int -> Int
  | work sumTo <= 6 * (lim - i) + 6
  | expect loop, noalloc, unboxed .
```

| Expectation | Holds when |
|---|---|
| `loop` | every call within the recursive group is compiled as a jump (self loop or sibling tail call) |
| `noalloc` | no allocation call or inline bump remains in the function's loop blocks after reuse and regions. Distinct from `alloc f <= 0`, which bounds semantic Core allocation before those passes |
| `unboxed` | the function received a scalar worker (raw Int/Bool parameters) |
| `specialized` | no `fpr_apply` dispatch remains in the function's loop blocks |
| `inlined` | (on a callee) every call site in the linked program inlined it |
| `fused` | (on a pipeline) every adjacent `Vec` element pass in the body was fused |

Verdicts follow the bounds pass: `HOLDS`, or `BROKEN` with the remark that
broke it, as a compile error under `=== EXPECT: ERRORS ===`. An expectation
that cannot apply in the current configuration (`specialized` under `--arc`,
where callback specialization is off; `noalloc` on a target without the
pass it depends on) is `NOT APPLICABLE`, a note,
not an error, so one source builds on every target.

Expectations are not interface. `fpr commit` should not classify a changed
expectation as a major change: it constrains this module's compilation, not
its callers. (Open question 2.)

### 8. Source-level hazards: cheap checks on the keystroke path

A few hazards need no optimizer, only the checked program and `Cost`'s
equations, and can run under `--check-only`. They are the asymptotic traps,
the ones a faster backend cannot fix:

- **Growing accumulator with linear-cost operations.** In a measured recursive
  group, an argument that grows each step (`acc + s` on String or List, a
  `cons` onto a list that is then traversed) feeding a callee whose cost
  mentions `len acc`. `Cost` can report this precisely: the group's derived
  work has degree 2 or more in the measure. Suggest collecting pieces in a
  list and one `String.concat`/`String.join` (one allocation, the `strJoin`
  primitive), or a reversed accumulator.
- **Deep equality in a loop condition.** `==` is deep; comparing a growing
  structure in a guard is linear per iteration.
- **Length in a loop condition** where the length is loop-invariant.
- **Copies the source asks for without looking like it.** Vectors have one
  owner and real copies (`runtime/vec.c`, no copy-on-write since MEMORY v2
  phase 3): `Vec.dup` copies, `send` deep-copies its message, `keep` deep-copies
  into the caller's pool. Any of these inside a loop or receive turn on a
  value that grows with the input is a per-iteration copy.

These are `Note` severity, shown only in hot positions, with the same
`OptimizationRemark` code family so the editor treats them alike.

## Editor integration (fpr-lang extension)

The extension lives outside this repository; this is the contract it needs.

- **On keystroke:** unchanged. The line-shaped server keeps outline, symbols
  and hovers. Add `fpr compile --check-only` for type, safety and linearity
  diagnostics plus section 8's hazards, debounced.
- **On save:** run the compiler through unit emission with `--remarks=json`,
  stopping before the C link (a new `--emit-only` mode; `fpr compile` to a
  scratch `.s` works meanwhile), cancel any run in flight, and replace the
  file's remarks wholesale. Warm caches make most units free; the root unit
  and the linked passes are the cost.
- **Presentation:**
  - diagnostics at `Information` (shown remarks) or `Hint` (the rest), never
    `Warning`; `code` is the kind, `codeDescription` links to the catalogue;
  - inlay hints at the site: `generic call`, `alloc`, `not tail`, `spill`;
  - one code lens per function: `loop · 0 allocs in loop · unboxed · 1 spill`;
  - hover on a call: the inlining and specialization decision and its reason;
  - code actions where the fix is mechanical: add the `| expect` line that
    pins the current good state, add the `unsafe` signature (the existing
    `FPR_UNSAFE_SUGGEST` output), package several captures into one capture
    record (the `vec note` advice).
- **Stale results.** Remarks describe the saved file. The server drops them on
  the first edit to their range rather than displaying stale locations.

## Catalogue

| Kind | Trigger (shown by default when hot) | Produced by | Fix |
|---|---|---|---|
| `inline` | a call in a loop or recursive group not inlined | linked inliner | split the callee, or `inlined` expectation to pin it |
| `generic-call` | `fpr_apply` dispatch per iteration; a `Vec`/List site in the generic tier; a sig record passed at runtime | callback and structure specialization, `Struct.hs`, `Codegen.declines` | one capture record; avoid function-valued captures; pass the sig as a literal |
| `tagged` | a loop-reachable function's Int/Bool parameters stay tagged (no scalar worker) | `Workers` | the reason names the limit: at most 8 parameters, a body of at most 1,024 nodes, an Int/Bool signature |
| `not-tail` | a call in tail position compiled as call-and-return | `lowerTail`, kernel lowering | call a known function rather than a parameter; accumulator form |
| `path` | a function on the compatibility path, or refused native emission | typed lowering (`planDeclines`), targets | the recorded reason |
| `alloc` | allocation in a loop block after reuse and regions | IR after regions | reuse the input cell; arena; see `noalloc` |
| `no-reuse` | constructor reuse refused | `Reuse` | remove the opaque call between last use and rebuild, or give it a verified effect contract |
| `copy` | `Vec.dup`, `send` or `keep` of a growing value in a loop; full state copy where generations were refused | section 8, region/state copy | thread the vector linearly; send a smaller message; keep vectors out of retained state |
| `not-fused` | adjacent element passes not fused | fusion | the callback reason names the blocker |
| `check-kept` | overflow check, or a guarded vector read's bounds check, in a loop | `Simplify`, `VectorRead`, then interval analysis | a guard the analysis can use (`i < len v`) |
| `not-hoisted` | invariant work left in a loop | `LoopOptimize` | none; informational until motion is default |
| `spill` | spill inside a loop | allocator, `Pressure` | fewer live values across the tick or a call |
| `opaque-cost` | ω term in a hot function's cost | `Cost` | declare a bound on the callee |
| `quadratic` | degree ≥ 2 work in the measure | `Cost`, section 8 | `String.concat` of collected pieces, reversed accumulator |

## Staged plan

Each stage lands alone with byte-identical emission (remarks on vs off, every
target the emission oracles cover), the compile-time budget
(`tests/check_compile_budget.py`, remarks off and on reported separately) and
the full Base suite.

**Stage 0: the record and the renderer.** `Diagnostic.Remark`, its
`Diagnostic` projection, text and JSON renderers, `--remarks` flags. Convert
the existing producers (`vec note`, typed fusion, pass reports, receive turns,
`Allocate.Stats`) with no new information, and surface the two reason lists
that are computed and dropped today (`Core.Typed.Specialize.declines`,
`planDeclines`). Sidecar `.remarks` per unit so warm builds print the same as
cold. *Acceptance:* `tests/check_remarks.py` builds a fixture twice and gets
identical remark output; existing notes reappear only under `--remarks`.

**Stage 1: the reasons that matter most.** Inliner, callback specialization,
workers, reuse, self tail calls. Owner and typed-site locations. Heat from
recursive groups and receive loops. *Acceptance:* a fixture per kind with the
expected kind, reason and line; `helpers`, `sha` and `byteloop` (the
benchmarks the plan names) produce a remark list that is reviewed and checked
in as `bench/remarks-*.txt`, so a later optimization shows up as a diff.

**Stage 2: the native IR.** Loop nest heat, `check-kept`, `not-hoisted`,
`spill`, `alloc` in loop blocks, `AtCall` resolution. *Acceptance:* the loop
motion benchmark kernel reports the spill counts in
[register pressure](2026-10-27-REGISTER-PRESSURE.md) (5 before that change, 0
with motion on) from remarks alone.

**Stage 3: expectations.** `| expect ...` in the signature grammar, verdicts,
`NOT APPLICABLE` per target, Sol parses and ignores. *Acceptance:* a fixture
per expectation that holds, one that breaks with the expected remark named,
and one not applicable on RV32.

**Stage 4: source hazards on the check-only path.** Section 8, using `Cost`.
*Acceptance:* the old byte-loop `strcat` shape from
[the regressions page](2026-10-26-PERFORMANCE-REGRESSIONS.md) is reported as
`quadratic`; std produces no hazard remarks it does not deserve (reviewed
list, checked in).

**Stage 5: the editor.** In the fpr-lang repository: the on-save runner,
presentation and code actions above, against stage 0's JSON contract.

Stages 0 and 1 are the bulk of the value; stage 3 is what makes it stick,
since a benchmark's hot loop can then state `expect loop, noalloc` and CI
fails the day a compiler change quietly breaks it.

## Risks and what this does not do

- **Noise.** The heat filter is the main control. If a kind fires on most of
  std, it is either a real finding or the kind is wrong; both are decided by
  reviewing std's list in stage 1, not by raising thresholds.
- **Compile time.** Producers allocate reasons only for declined decisions,
  and only build the rendered text when asked. The budget gate records the
  difference.
- **Message stability.** Kinds and reason tags are stable; wording is not.
  Tools and expectations key on tags.
- **Remarks are not a profiler.** Heat is structural. A hot remark in a loop
  that runs twice is still a remark; a profile can refine heat later.
- **Sol.** The bytecode profile is out of scope except one kind: `not-tail`
  for an `Apply` in tail position, which still keeps its frame
  ([tail calls](2026-10-02-SIGNATURES-AND-TAIL-CALLS.md)).

## Open questions

1. **Default visibility in the CLI.** Off unless `--remarks` (proposed), or
   hot remarks on by default for `fpr build` of the root unit?
2. **Expectations and commit.** Treated as implementation (proposed), or as
   interface, so a dependency relaxing `expect noalloc` is visible to callers?
3. **Expectation vocabulary.** The six above, or start with `loop` and
   `noalloc` only, the two the performance plan's benchmarks need?
4. **Editor cost.** Is an on-save emission run acceptable for files that
   import `std/live` (19 s cold, warm cost unmeasured), or should the editor
   request remarks only for the function under the cursor once the driver can
   stop after one unit?

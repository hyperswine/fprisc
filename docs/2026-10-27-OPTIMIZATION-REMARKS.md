# Optimization remarks: the compiler explains its performance decisions

Date: 2026-10-27. Kind: goal / plan. Status: stage 0a, high-value stage 1 decisions and the explicit editor command implemented locally.
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

Before stage 0a there was no shared machine-readable optimization remark output.

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
5. **The editor already runs compiler checks.** `fpr-vscode-2` checks saved
   files on open/save through `server/compiler-check.js`, parses compiler
   diagnostics and cancels superseded checks. Its lexical scanner supplies
   interactive symbols and hovers. Extend that runner with an explicit remark
   command; do not add an emission run on every keystroke or save by default.

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
data Site = AtSpan SourceSpan | AtDefinition -- exact spans require retained file provenance
data Outcome = Applied | Declined Reason
```

`Reason` is a closed sum per kind, never prose: the renderer owns
the words, as `Core.Typed.Fusion.renderNote` already does for fusion. Call ordinals such as "the k-th call to g" are not stable source identities.
The first slice uses definition locations. Precise sites require retained,
file-owned origin identities, including through inlining and cloning.

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
- `SelfLoopsOff` is a separate optimization-policy fact: re-entering through
  a symbol can still be a tail jump with constant stack usage. It must not
  itself produce `not-tail` or break an `expect loop` guarantee.

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
  per-unit anchors for imported modules). Unknown owners remain unlocated;
  the first slice explicitly labels resolved locations as definition-level.
- **Stage B, typed sites.** Retain `exprOffset` together with its source-file
  origin. An offset alone is insufficient when inlining a body from another
  module into a caller. Publish an exact span only when that ownership is
  proved; otherwise keep the definition location.
- **Stage C, after erasure.** Start with the owning source definition.
  A later precise mapping must retain an explicit origin identity across the
  transformation, with its source file. Matching call counts/ordinals is not
  proof: deleting, duplicating or reordering calls can preserve the count and
  still identify the wrong occurrence. Unknown provenance stays at the owner.

A position on every untyped node is not required for this first slice. The
interface must distinguish definition locations from proven expression spans;
it must never present a guessed token as an exact optimization site.

### 5. Caching: remarks survive a warm build

Emission-stage remarks may eventually be written beside assembly as
`<unit>.remarks`. Their envelope needs a schema/producer version and the
source provenance used by its coordinates, in addition to the codegen key.
The semantic assembly cache does not validate source paths or positions.
Publish complete records atomically; define recovery for absent/corrupt
sidecars and caches populated with remarks disabled. A sidecar miss must
not silently hide a decision or invalidate reusable assembly. Linked-program remarks (inlining, specialization) are
computed every build already, since those passes run on every compile. Remark
options stay out of codegen cache identities and must not change emitted
bytes. A missing emission-side record may require a documented analysis-only
regeneration; it must not pretend emission diagnostics can be recovered for
free. The first slice reports only facts already recomputed before cache
lookup (fusion, compatibility lowering and selected regions), with locations
resolved from this invocation's sources. It needs no sidecar.

### 6. Output

CLI (the first slice implements these native compile/build flags):

```
fpr build prog.fpr --remarks            # hot remarks, located text
fpr build prog.fpr --remarks=all        # every decision, applied and declined
fpr build prog.fpr --remarks=json       # one JSON object per line on stderr
```

Later site-aware producers can render text such as the following; stage 0a
uses the source definition line instead of these expression coordinates:

```
prog.fpr:41:9: remark[inline]: `step` not inlined into the loop in `run`: weight 71, limit 64 at a recursive caller
prog.fpr:47:15: remark[generic-call]: `List.fold` over `addRow` stays a generic call per element: the callback captures a function value
prog.fpr:52:3: remark[spill]: loop in `scan` (depth 1) spills 2 values live across a call: acc (F64), i (Int)
```

JSON is the editor contract and is versioned (`"remarkVersion": 1`):

```json
{"remarkVersion":1,"positionEncoding":"utf-32","kind":"not-fused",
 "outcome":"declined","reason":{"tag":"CallbackEffect","callback":"first",
 "cause":{"tag":"Primitive","detail":"the primitive `print`"}},
 "owner":"run","file":"prog.fpr","start":{"line":40,"character":0},
 "end":null,"precision":"definition","heat":"Cold","pass":"typed-fusion",
 "message":"callback `first` prevents fusion: the primitive `print`","fix":null}
```

The example is the stage 0a contract: one summary per owner/reason, not per
call site. `end` is null for definition-level locations; unresolved owners
also have null `file`/`start`. No range is fabricated. More precise sites and
fixes are deferred. JSON positions are zero-based, unlike the CLI's one-based coordinates.
Positions are in decoded characters, as `Source.Span` counts them. LSP's
default is UTF-16 code units; the extension negotiates `positionEncoding:
utf-32` (LSP 3.17) or converts per line. Getting this wrong only shows on
lines with non-BMP characters, which is exactly when it is hard to notice.

Convert existing reports producer by producer. The first slice makes typed
fusion refusals opt-in; other vec/worker/receive debug strings keep their
existing controls until migrated. JSON consumers recognize `remarkVersion`
records; unrelated diagnostic/debug text and compiler failures retain their
existing channels and must not be interpreted as JSON records.

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
| `noalloc` | the chosen scope has no allocation, including transitive callees, runtime helpers and region copy-out. Unknown indirect/foreign effects are `UNPROVEN`. A weaker direct-instruction property must have a different name |
| `unboxed` | the relevant calls actually use the raw worker; merely generating an unused worker is insufficient |
| `specialized` | define the relevant scope and all indirect-call forms first; absence of the literal `fpr_apply` symbol is insufficient |
| `inlined` | (on a callee) every call site in the linked program inlined it |
| `fused` | (on a pipeline) every adjacent `Vec` element pass in the body was fused |

Verdicts follow the bounds pass: `HOLDS`, or `BROKEN` with the remark that
broke it, as a compile error under `=== EXPECT: ERRORS ===`. An expectation
must distinguish `BROKEN`, `UNPROVEN` and unsupported configurations. An
unsupported expectation cannot silently count as a satisfied hard guarantee.
Target applicability needs an explicit source/configuration policy before
this syntax lands. A function without loop blocks also needs a defined scope;
vacuous success must not imply that its entry or callees allocate nothing.

Expectations are not interface. `fpr commit` should not classify a changed
expectation as a major change: it constrains this module's compilation, not
its callers. (Open question 2.)

### 8. Source-level hazards: cheap checks on the keystroke path

Some hazards can eventually run without native emission, but they need
specific checked data-flow/shape evidence and a latency budget. Re-running
whole-program `Cost` on editor changes is not automatically cheap. They are the asymptotic traps,
the ones a faster backend cannot fix:

- **Growing accumulator with linear-cost operations.** In a measured recursive
  group, an argument that grows each step (`acc + s` on String or List, a
  `cons` onto a list that is then traversed) feeding a callee whose cost
  mentions `len acc`. The current `Cost` pass does not track this growth recurrence.
  A measured `grow n acc = ... grow (n - 1) (strcat acc "x")` currently
  reports `(n + 1) * (len acc + 7)` work, not a quadratic in `n`.
  Detecting this needs growth analysis or a narrowly justified pattern check;
  polynomial degree alone cannot establish the hazard. Suggest collecting pieces in a
  list and one `String.concat`/`String.join` (one allocation, the `strJoin`
  primitive), or a reversed accumulator.
- **Deep equality in a loop condition.** Inspect the checked operand types
  and implementation; scalar equality is constant-time and structural equality
  may short-circuit. Report a possible traversal, not an unconditional bound.
- **Length in a loop condition** only for a traversing implementation and a
  proved invariant operand. String/vector length is already constant-time.
- **Copies the source asks for without looking like it.** Vectors have one
  owner and real copies (`runtime/vec.c`, no copy-on-write since MEMORY v2
  phase 3): `Vec.dup` copies, `send` deep-copies its message, `keep` deep-copies
  into the caller's pool. Any of these inside a loop or receive turn on a
  value that grows with the input is a per-iteration copy.

These are `Note` severity, shown only in hot positions, with the same
`OptimizationRemark` code family so the editor treats them alike.

## Editor integration (fpr-lang extension)

The extension lives outside this repository; this is the contract it needs.

- **On keystroke:** keep existing lexical features. Compiler diagnostics
  currently describe saved files checked on open/save; keystroke checking
  would require a separately designed overlay and debounce protocol.
- **Explicit command first:** run native compilation to a scratch `.s` with
  `--remarks=json`, without linking C. Extend the existing cancellable runner.
  Record the saved source/version snapshot and discard results after edits.
- **Automatic refresh:** optional and off by default until measured. The QOS
  shell still used 29 seconds of compiler CPU with all 49 unit-cache hits
  after shared cost analysis; warm hits do not make linked passes free.
- **Presentation:**
  - diagnostics at `Information` (shown remarks) or `Hint` (the rest), never
    `Warning`; `code` is the kind, `codeDescription` links to the catalogue;
  - inlay hints at the site: `generic call`, `alloc`, `not tail`, `spill`;
  - one code lens per function: `loop · 0 allocs in loop · unboxed · 1 spill`;
  - hover on a call: the inlining and specialization decision and its reason;
  - code actions where the fix is mechanical: add the `| expect` line that
    pins the current good state, package several captures into one capture
    record (the `vec note` advice).
- **Stale results.** Remarks describe the saved file. The server drops/invalidate results on any source or dependency change
  relevant to the analysis, including an edit during the compilation. Checking
  only edits within a displayed range is insufficient.

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
| `quadratic` | proved growth recurrence or a justified checked pattern; degree alone is insufficient | new growth analysis, section 8 | `String.concat` of collected pieces, reversed accumulator |

## Staged plan

Each stage must preserve emitted bytes with remarks on/off across the
covered targets. The foundational stage 0a uses the focused checks below and
an off/on allocation probe. Wider producer migrations additionally gate on
the compile-time budget (`tests/check_compile_budget.py`, off/on reported
separately) and full Base. Hosted CI and physical execution are separate
validation claims.

**Stage 0a: record and pre-cache reports (first implementation slice).**
`Diagnostic.Remark`, diagnostic projection, text/JSON and `--remarks` flags.
The implementation lives in `Diagnostic.Remark` and `Compiler.Remarks`;
compiler drivers only pass retained products to those modules.
Start with typed fusion refusals, compatibility-lowering reasons and selected
region boundaries. Definition locations, no guessed expression spans. All
three facts are retained/recomputed before cache lookup, so no sidecar is
needed. Compatibility lowering has a stable `CompatibilityLowering` tag but
retains its existing reason text as an opaque detail; finer typed reason
categories are deferred. Region reports describe selected boundaries, not
all region refusals or call-region sites. JSON emits all collected records for tool-side filtering; bare
`--remarks` shows declined decisions in recursive/receive groups, while
`--remarks=all` includes applied and cold decisions. Check-only rejects these
native reporting flags explicitly rather than silently returning no remarks.
*Acceptance:* cold/warm and remarks-disabled-to-enabled consistency, imported
owners, JSON escaping/coordinates, unchanged root/unit assembly and cache
reuse. Focused producer/native regressions gate this slice; broad Base and
budget checks gate wider producer migrations.

**Stage 0b: emission reports and persistence (later).** Port vec/worker and
allocator reports with the versioned, source-validated sidecar recovery
contract above. Cover missing/corrupt sidecars and concurrent publication.
Do not infer structured reasons by parsing human note strings.

**Stage 1a: high-value decisions (implemented).** Inliner and callback
specialization preserve pass-owned typed reasons in the closed program.
Definition-level summaries are emitted through the stage 0a contract. They
report attempts across the linked passes, not final-code guarantees; repeated
identical owner/target/reason facts are deduplicated. Early size limits remain
early exits: oversized weights are lower bounds, not expensive full counts.

**Stage 1b: remaining decision producers (later).** Workers, reuse and tail
calls; precise sites require file-owned origins. Add reviewed fixture/report
lists for relevant benchmark loops as each producer is migrated. This stage
must distinguish intrinsic recursion and expected generic code from actionable
missed optimizations before making additional hot remarks visible.

**Stage 2: the native IR.** Loop nest heat, `check-kept`, `not-hoisted`,
`spill`, `alloc` in loop blocks, explicit origin mapping. *Acceptance:* the loop
motion benchmark kernel reports the spill counts in
[register pressure](2026-10-27-REGISTER-PRESSURE.md) (5 before that change, 0
with motion on) from remarks alone.

**Stage 3: expectations (contract design required first).** Settle scopes,
transitive effects, `UNPROVEN` and explicit target applicability before
adding `| expect ...` syntax. *Acceptance:* holding, broken, unknown-callee
and unsupported-target cases; the latter two cannot silently satisfy a hard
guarantee. Define Sol's behavior explicitly rather than assuming that parsing
and ignoring a guarantee is acceptable.

**Stage 4: source hazards on the check-only path.** Section 8, using `Cost`.
*Acceptance:* the old byte-loop `strcat` shape from
[the regressions page](2026-10-26-PERFORMANCE-REGRESSIONS.md) is reported as
`quadratic`; std produces no hazard remarks it does not deserve (reviewed
list, checked in).

**Stage 5a: the explicit editor command (implemented).** The extension
contributes `FP-RISC: Show Optimization Remarks`, using existing compiler
path/environment/project-root helpers. It emits native code to scratch without
a C link; `--plugin` supports mainless modules. Results are shown as Information
diagnostics for open files and an output panel for the requested file. Ordinary
compiler checking remains independent. No remark compilation is triggered by
open/save/edit events.

**Stage 5b (later).** Lenses, inlays, code actions and optional automatic
refresh. Expectations must settle their proof/applicability contract before
an action can offer to add them.

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

1. **Default visibility in the CLI (decided for stage 0a).** Off unless
   `--remarks`; no hot remarks are added to ordinary builds.
2. **Expectations and commit.** Treated as implementation (proposed), or as
   interface, so a dependency relaxing `expect noalloc` is visible to callers?
3. **Expectation vocabulary.** The six above, or start with `loop` and
   `noalloc` only, the two the performance plan's benchmarks need?
4. **Editor cost.** Explicit command initially; automatic emission is off.
   Consider narrower analysis only after the driver can stop safely at a
   defined stage/scope and measurements demonstrate acceptable latency.

## Stage 0a implementation and local evidence

Implemented `--remarks` (hot declined summaries), `--remarks=all` (all
summaries) and `--remarks=json` (all version-1 records) in native compile/build.
Text and JSON go to stderr. Existing debug/error output retains its own
format; a tool selects JSON objects with `remarkVersion` and handles a failed
compiler separately. Remarks are advisory `Note` diagnostics and never enter
inference's error list. Their flags do not change codegen revision 135 or
unit-cache identities. Disabled reporting does not force collection/rendering.

Typed fusion now retains its source owner and only reports refusals when
requested. The old `renderNote` remains for compatibility/unit tests. The
adapter consumes the typed refusal, not that rendered text. Private checked
region helpers resolve through their retained source owners. Facts are sorted
and deduplicated by owner/reason; this is deliberately a summary interface,
not a claim to identify every call site or all optimization decisions.

Validation completed locally:

- `Diagnostics`, `CompilerOptions` and `TypedProgram` Cabal suites, including
  typed fusion and new advisory/JSON-escaping/visibility checks.
- `tests/check_remarks.py`: disabled-to-enabled and repeated warm output,
  imported definition locations, non-BMP/quoted paths, moved source lines,
  invalid modes, explicit check-only refusal, native execution and build flag
  forwarding. All seven managed/QOS emission targets pass. The check is in
  Base's registry.
- Root and dependency assembly are byte-identical against the saved
  pre-change compiler for `vecfuse_effects` and `autodrop3` on A64, x64, RV64,
  RV32, QA64, QX64 and QRV64. On/off/all/JSON also preserve root bytes,
  dependency paths and cached-file modification times.
- Focused Base checks pass for fusion effect/failure order, exact-zero parked
  receive retention and the check registry.
- A cold hello allocation probe reports 1,679,559,080 bytes before,
  1,679,536,512 with reporting off, and 1,694,122,928 with JSON on: effectively
  unchanged off, +0.87% on for this small fixture. The
  [raw probe](../bench/2026-10-27-remarks.json) records compiler hashes and
  methodology. This does not establish large-project editor latency.

At the end of stage 0a, inliner/callback producers and editor UI remained;
the additional implementation below now supplies them. Emission sidecars,
expectations, source-growth hazards and exact expression spans remain deferred.
Full Base, hosted CI and physical target execution were not part of that
initial reporting slice.

## High-value decisions and explicit editor command

`Core.Typed.Decision` owns closed inliner/callback reason sums. Collection is
opt-in; the compiler carries those advisory records beside `ClosedProgram`
through linking, vector planning, normalization and fusion. The records are
not typing evidence and do not select optimizations or allocate fresh code
identities. Existing no-report APIs retain their behavior. `Compiler.Remarks`
adapts these products rather than parsing debug strings or assembly.

The inliner reports applied calls, recursive/nullary exclusions, early
weight-limit refusals with the actual caller budget, linker-private globals,
arity mismatches and contract-instantiation failures. Callback specialization
reports applied attempts, unknown targets/arguments, unstable or unsafe
substitution, arity/depth/clone/node limits, unification/private-type refusals,
and post-liveness arity rollback. A planned clone can later be restored to the
original call; `RetainedArityOverflow` records that fact. The summaries are
not chronological traces and do not prove that a dispatch remains in final
machine code. Locations remain at the original source definition.

JSON output also carries a separate provenance record:

```json
{"remarkInputsVersion":1,"kind":"inputs","algorithm":"fnv1a-64-utf8",
 "files":[{"file":"prog.fpr","digest":"0123456789abcdef"}]}
```

The manifest fingerprints the decoded source snapshots actually consumed,
including root, imported/pinned modules, prelude and foreign declarations.
FNV is an equality check, not a security hash or assembly cache identity.
The editor requires this manifest, checks current disk/open-buffer contents,
installs input watchers and checks again before publication. Unproven file
locations are rejected. JSON positions are converted to UTF-16 for LSP.
Unsupported manifest/schema versions fail explicitly instead of displaying
unvalidated coordinates.

The explicit command rejects dirty root buffers and stale/dirty dependencies,
cancels superseded work, and clears results on editor/configuration/workspace
changes or watched input changes. It preserves unit emission caches in a
session scratch directory while giving each request a separate root output.
Normal shutdown cancels children, closes watchers and removes scratch data.
It uses no C link and does not execute the source program. It supports native
Base files/modules; bytecode, ARC/raw and cost-manifest checking stay outside
this first editor command. An older compiler without provenance metadata is
reported as unsupported.

Additional validation:

- Typed-program/callback unit checks compare exact lowered graphs with
  reporting off/on, verify applied and recursive decisions, test ordinary
  versus loop budgets, and retain the existing 64-field callback rollback.
- The focused typed-Core suite passes native one/four-hart answers, effects,
  stored partials, closure identity, imported-unit/cache transitions and
  existing cross-target emission checks.
- The remark CLI regression passes cold/warm consistency, emission/cache
  identity and native execution, now including inliner/callback records and
  source manifests.
- Two fixtures (`typed_core/callbacks.fpr`, `base/vecfuse_effects.fpr`) have
  identical root/dependency assembly against the saved stage-0a compiler,
  reporting off and JSON on, on all seven targets.
- The complete extension `npm test` passes. New tests exercise real LSP
  requests, absence of automatic emission, Information severity, cancellation,
  supersession, disk/buffer dependency changes, foreign-source invalidation,
  Unicode conversion, scratch cleanup and actual no-main module compilation.
  The suite also exposed three stale generated prelude entries (refreshed)
  and located safety messages that needed their named declaration token
  rather than the whole line (fixed).
- A cold `std/live` probe allocates 38.398 GB before, 38.414 GB reporting off
  (+0.04%) and 40.741 GB with JSON (+6.1% versus off). JSON produces 2.75 MB
  of records. Single wall-time samples under host load are descriptive, not
  a latency guarantee. See [raw allocation/parity evidence](../bench/2026-10-27-remarks-stage1.json).

Codegen revision 135 and native ABIs remain unchanged. No VSIX publication,
installation into a running VS Code instance, hosted CI or physical target
execution is claimed. Highest-value follow-ups are worker/reuse refusals,
careful tail-call classification, and filtering/profile feedback from actual
projects; broader expectation/growth-analysis work remains separate.

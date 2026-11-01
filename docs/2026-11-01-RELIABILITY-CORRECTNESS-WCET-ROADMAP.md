# Reliability, correctness and WCET: a roadmap

Date: 1 November 2026. Kind: assessment and prioritized roadmap, with quick
measurements; it changes no code. Base: main `7060b1b`. Builds on
[the unboxing proposal](2026-11-01-UNBOXING-ZERO-OVERHEAD-PROPOSAL.md),
[the near-term plan](2026-10-31-PERFORMANCE-AND-PREDICTABILITY-NEXT.md) (whose
"WCET and enforceable resource contracts" section states the five admission
properties; not repeated here), [the zero-overhead follow-ups](2026-10-31-ZERO-OVERHEAD-FOLLOWUPS.md),
[resource bounds](2026-10-02-RESOURCE-BOUNDS.md) and
[target manifests](2026-10-02-TARGET-MANIFESTS.md). "Measured" means run on
the x86-64 box this session; everything else is labelled.

## Summary

The tree already has more safety machinery than most young compilers: a
structural typed-IR verifier after every simplify pass, an enforced
safe/unsafe line with an allow-list review, symbolic work/alloc equations,
native instruction bounds between safepoints, manifests that refuse
over-budget functions, and clean traps for overflow, division, stack and heap
exhaustion. What it lacks is **independent evidence that the compiler is
right**: nothing generates programs, nothing compares configurations as a
routine, the proof pass is not in CI and is broken, the runtime has never been
run under sanitizers in CI, and the WCET numbers rest on abstract operations
and supplied ns/op, not on a timing model of any target.

Top findings this session (all measured, repros below):

1. **`fpr stdcheck` fails on `std/list.fpr`** with 21 arity errors, and on a
   4-line program. It is not run in CI, so it rotted silently.
2. **`tests/std/apps.fpr` does not build on main**: `std/log.fpr:22-23,29-30`
   declare `work <= 6`, the cost pass derives 8. A contract and its checker
   drifted apart with no gate between them.
3. **The compiler crashes** (`Prelude.head: empty list`) on a 6-line
   ill-formed program found by 2000-mutant fuzzing in a few minutes.
4. **Optimization flags agree**: 37 std programs x 11 configurations (each
   `FPR_NO_*` pass off, 4 harts, UBSan runtime) produced identical results.
   Good news, and cheap to keep as a CI gate.
5. **Sanitizers**: UBSan finds one benign UB (`qsort(NULL, 0)` in
   `machine/posix/os_fs.c:54` on an empty directory); ASan runs but reports
   false positives on actor stacks until the context switch carries fiber
   annotations.
6. Panics print to **stdout** (`runtime/runtime.c:3031-3034` via `hal_putc`),
   mixed into program output; an `unsafe` infinite loop runs forever with no
   watchdog in hosted builds.

**Recommendation.** Spend the next week on gates, not new analyses: put
`stdcheck`, the configuration-differential matrix, a UBSan runtime build and a
parser/typechecker fuzz smoke into CI, and fix the three bugs. Then build the
one missing oracle, an executable reference interpreter over checked Core,
and use it for generated-program differential testing and translation
validation of the risky passes. WCET proper starts with a cycle model for
simple-risc and an IPET pass over the selected low IR, validated against
`mcycle`. WCET is not a profile: per Jack's decision (section 6) it is part
of the type system, always on, using the `| work f <= ...` signature syntax
already proposed in `2026-10-02-RESOURCE-BOUNDS.md`; the reference target is
the cached SDRAM simple-risc configuration.

## 1. Reliability: what exists

| Mechanism | Where | Notes |
| --- | --- | --- |
| Safe/unsafe line, explicit `unsafe` on recursive SCCs, taint stops at the allow-listed library | `compiler/Safety.hs:1-31`, allow-list `:50-75` | Allow-list entries are "not proof certificates" (`:52`); `tests/check_trust.py` refuses unlisted std modules |
| Typed-IR structural verifier (types, SSA, dominance, edges) after lowering and after **each** simplify pass, failure = compiler error with before/after dump | `compiler/Codegen/Verify.hs:1-8`; `compiler/Codegen/Simplify.hs:66-79`; `compiler/Codegen.hs:223` | Structural only: it cannot catch a semantically wrong but well-formed rewrite (the class of the Interval bug) |
| Typed Core verifier at stage boundaries | `compiler/Core/Typed/Verify.hs`, used by `Stage.hs:33,137`, `Erase.hs`, `Layout.hs`, `Program.hs` | Type-level, not semantic |
| Native bound: `native-insns-v1` segmax between safepoints; an unbounded cycle declines native code | `compiler/Codegen/Bounds.hs:1-8`; `compiler/Codegen.hs:236-247` | Instructions, not cycles |
| Fuel and stack checks on hosted entries; "Base without fuel is not a supported policy" | `compiler/Codegen/Policy.hs:81` | Cooperative yield, not a watchdog |
| Traps (measured): overflow, `/0`, stack ceiling (1 GiB), heap exhaustion all panic cleanly with exit 1 | `runtime/runtime.c:3031-3051` | Message goes to stdout |
| Cost equations (work, alloc) per function; contracts `\| work f <= k` checked at build | `compiler/Cost.hs:1-20` | Alloc excludes preheader/rounding (`:10-13`) |
| Manifests: ns/op, budgets, refusal of over/unproved budgets | `compiler/Manifest.hs`; target manifests doc | ns/op is supplied, not measured |
| Sol transactions mark `sh` external (no rollback); no sandbox | `compiler/Sol/VM.hs:1405,1548` | No seccomp/landlock anywhere (grep) |
| CI: one workflow, Linux x86-64 + QEMU RISC-V/RV32/RV64 groups + Sol suites (Linux, macOS non-blocking) | `.github/workflows/ci.yml:20-23,39-130,143-170` | No A64 hardware job, no sanitizer job, no fuzz job |
| Tests: 173 Python checks, 46 Haskell, ~126 top-level `.fpr/.sol`, 40 std expected-output programs | `tests/` | No property-based or generated tests (`fp-risc.cabal` has no QuickCheck/hedgehog) |

**CI health (measured, last 40 runs via `gh run list`)**: 18 success, 12
cancelled (superseded pushes), 8 failures. The main-branch failures were
deterministic, not flaky: `sol-library-check.py` failed three consecutive
main pushes on 31 Oct, and `check_compile_budget.py` failed once. Main HEAD's
own run was cancelled, so the `apps` breakage above had no gate result.

## 2. Hands-on checks (measured, reproducible)

Scripts are outside the tree (`/workspace/out/difftest.py`, `fuzz.py`,
sanitizer `FPR_CC` wrappers); they need no code changes because `FPR_CC`
already selects the C compiler (`compiler/Build.hs:180`) and enters cache
identity (`:412`).

| Check | Result |
| --- | --- |
| Config differential: 37 `tests/std` programs x {default, `NO_INTERVAL`, `NO_INLINE`, `NO_SPEC`, `NO_REUSE`, `NO_SCALAR/FIELD_WORKERS`, `NO_VEC_*`, `NO_STR_FAST`, `NO_LOOP/CALL_REGIONS`, 4 harts, UBSan} = 407 builds | **0 cross-config differences.** 34 match `.expected` everywhere; `apps` fails to build everywhere (bug 2); `durable`, `posix` need `check_std.py`'s arguments (harness, not a bug) |
| UBSan runtime (`-fsanitize=undefined`) | 1 finding: `os_fs.c:54` `qsort` with NULL base when a directory is empty |
| ASan runtime | Works, but `stack-buffer-overflow` in `__asan_handle_no_return` from `fpr_prim_fn_error` on actor stacks: a known false positive without `__sanitizer_start_switch_fiber` annotations |
| Parser/typechecker fuzz: 2000 byte/token mutants of the corpus through `fpr check`, 20 s timeout | 2 crashes (one signature: `Prelude.head: empty list`), 1 timeout that is really slowness: unmodified `tests/base/vecwide.fpr` takes 18.7 s to check |
| `fpr stdcheck std/list.fpr` | FAILED, 21 errors `call ... expected 1 args, got N` |
| Infinite `unsafe` loop | Runs until killed (hosted, single actor) |

### Bug repros (not fixed here)

1. `stdcheck` arity: an out-of-fragment multi-argument function called from
   another function.
   ```
   go : (xs : List a | measure xs) -> Int -> Int .
   go xs n = case xs of Nil -> n | _ :: r -> go r (n + 1).
   len : List a -> Int .
   len xs = go xs 0.
   ```
   `fpr stdcheck sc2.fpr` -> `error: call at site 1000 to go: expected 1 args, got 2`, `stdcheck: FAILED`.
   It also shows the fragment excludes constructor patterns, so all list code
   is "opaque cost" to the proof pass.
2. Cost contract drift: `fpr run tests/std/apps.fpr` -> `COST: ERRORS`
   `name`/`rank` in `std/log.fpr` declared `work <= 6`, derived 8.
3. Compiler crash (minimized from a fuzz mutant of `tests/base/mvudeadlines.fpr`):
   ```
   MV = use "std/mvu".
   backend mode me =
     case q of
         MV.Dims u -> if mode == 1 then _ = Sys.sleepUs 2000000; Unit else _ = AC.sendSure me from (80, 24); backend mode me
       | MV.Render  sc fr -> if mode == 2 then _ = Sys.sleepUs 2000000; Unit else _ = AC.sendSure me from (0, 0); backend mode me
       | MV.Poll u -> if mode == 3 then _ = Sys.sleepUs 2000000; Unit else _ = AC.sendSure me from (0, 0, 0); backend mode me.
   runCase me render input port mode =
     MV.runResultWithin (if mode == 7 then 500 else 30) me cfg app.
   ```
   `fpr check` -> `fpr: Prelude.head: empty list` (expected: unbound-name errors).
4. Benign UB: `machine/posix/os_fs.c:54` `qsort(names, 0, ...)` with
   `names == NULL` (listing an empty directory).

## 3. Correctness: gaps and options

- **No oracle.** Every check compares the compiler against itself or against
  hand-blessed `.expected` files. An executable reference interpreter over
  checked Core (strict, small-step, trap-exact, following `docs/SEMANTICS.md`
  and `2026-10-25-TYPED-TRAPS.md`) is the single highest-leverage artefact:
  it gives an oracle for differential testing, a target for a later
  mechanized spec, and a check for Sol VM agreement.
- **No generated programs.** A well-typed program generator (Hedgehog/QuickCheck
  in the existing cabal test suites) over Int/Bool/ADT/List/closures with
  overflow- and trap-prone arithmetic, run reference vs native x configs x
  backends (x86-64 native, RV64/RV32 under QEMU as CI already does, Sol VM).
  Metamorphic variants (inline/outline a binding, reorder independent lets,
  add dead code) catch optimizer instability without an oracle.
- **Structural, not semantic, pass checks.** The verifier proves IR is
  well-formed; the Interval discharge bug was well-formed and wrong. For the
  risky passes, cheap translation validation is feasible because they are
  local: `Interval.discharge` can emit the facts it used and a separate
  checker re-derives each discharged check from dominating guards; `Reuse`
  can emit its uniqueness witnesses for a checker; `Allocate` can be checked
  by a register-assignment validator (every use reads the value its SSA
  definition wrote); `LoopForm`/`StringScan` by equivalence of the original
  CFG on the fallback path plus the guard facts. Each validator runs under a
  flag in CI and always in debug builds.
- **Mutation testing** of the test suite (flip a comparison in `Interval`,
  drop a fuel tick, swap a field offset) measures whether the suites would
  notice; cheap with a script that patches and runs `check_base.py` groups.
- **Formalization** (research-grade): a Lean 4 or K spec of the Core subset
  plus the typed-IR, proving the discharge rule and the trap-order
  preservation of fusion. Only worth it after the reference interpreter
  exists, since the interpreter is the executable form of the same spec.
- **Trust boundary**: the allow-listed std modules are trusted to have
  correct `measure`/`size`/`work` declarations, and bug 2 shows they drift;
  every declared contract should be re-derived in CI (already done at build,
  so the gap is only that no CI job builds every std test).

## 4. WCET: what exists and what sound bounds need

Today the chain is: `Safety` guarantees termination structure, `measure`s
and `size`s bound iteration counts, `Cost.hs` produces symbolic work/alloc,
`Codegen.Bounds` bounds native instructions between safepoints, manifests
multiply by a supplied ns/op. This is a **resource-accounting** system, not a
WCET analysis: no per-ISA timing model, no pipeline/cache/memory model,
runtime C code (allocator refill, ARC, message copy) is costed by declared
primitive numbers, and stack depth is not bounded statically.

What sound per-target bounds need, in dependency order:

1. **A target timing model.** simple-risc on Tang Nano 20K is the right first
   target because the hardware is ours, but it is **not cache-less**: the
   documented SDRAM configuration runs with a 64 KiB cache
   (`simple-risc/README.md:62`). Options: a scratchpad/uncached WCET
   configuration (fixed latencies, simplest and sound), or a cache model
   (must/may analysis, as aiT does). **Decided (2026-11-01): the cached SDRAM
   configuration is the reference target**, so a cache model (must/may
   abstract interpretation over the 64 KiB cache, plus SDRAM refresh/row
   latencies) is on the critical path, not optional. The uncached/BRAM
   configuration remains useful as a stepping stone: same IPET pass, fixed
   latencies, so the pipeline model can be validated against `mcycle` before
   the cache model lands.
2. **Analysis on the selected low IR, then on the binary.** IPET over the
   typed-IR CFG with loop bounds from `measure`s, using the selected
   instruction stream `Codegen.Bounds` already walks; a binary-level
   cross-check later. Low-IR analysis is simpler and keeps loop facts; the
   binary check covers the assembler/linker.
3. **Runtime with bounded costs.** Static arenas sized from `alloc` bounds
   (the unboxing proposal's header-free cells make them exact), no `fpr_alloc`
   refill path, bounded ARC drop (or region-only in WCET mode), no
   stack growth (`fpr_stack_grow`) with a static stack bound computed from the
   call graph (non-recursive except measured tail calls).
4. **Validation**: every bound must be >= observed. `mcycle` is already read
   (`machine/tangnano20k/base.c:49-52`); a CI-style board job runs each
   admitted callback on worst-case-ish inputs and fails if observed > bound,
   and tracks bound/observed tightness.
5. **Optimizations**: fusion, inlining and monomorphization (unboxing
   proposal phases 1-5) change code and therefore bounds; analysis must run
   after them on the final stream (as `Bounds` already does), and a
   regression gate tracks bound changes per admitted function.
6. **Bounds in the type system, not a profile** (decided 2026-11-01; section
   4a). Every function has a cost, always: safe code a derived closed form,
   `unsafe` code ω. A declared bound is a checked part of the signature, and
   a target manifest turns it into cycles. The refusals that the earlier
   draft gave a `wcet` profile become ordinary type errors at a declared
   bound: a reachable unbounded loop, a callback without a cost contract, an
   opaque primitive without a timing entry, or an allocation without an
   arena bound under a declared `alloc`/`live` bound. The report (per
   function: bound in cycles, loop bounds used, assumptions,
   manifest/compiler/runtime versions; JSON plus text, like
   `--remarks=json`) is what `fpr build --cost --target=<manifest>` prints.

### 4a. WCET in the type system: alignment with the existing proposal

The syntax already exists in the tree and is the one to use; no new keyword
or profile is introduced:

```
f : (a : Int) -> (b : Int) -> Int
  | work  f <= 12 * a + 40     -- abstract ops (Cost.hs units)
  | alloc f <= 16 * a          -- bytes requested over the call
  | live  f <= 64 .            -- peak resident bytes (Stage 4)
```

Sources: `2026-10-02-RESOURCE-BOUNDS.md` (grammar, Stages 1-4: derived
equations, bounds in signatures and interfaces, target manifests, live
memory), `2026-08-25-SAFETY.md` (the `unsafe` marker is exactly the set of
WCET-opaque functions, always on), and the `measure`/`size` annotations that
bound iteration counts. What exists now: `work`/`alloc` contracts on std
functions checked by `fpr build --cost` (PR #41 adds the drift gate).

How the roadmap maps onto it:

| Roadmap piece | Lands as |
| --- | --- |
| cycle bound per function | `work f <= e` judged against a manifest for cached-SDRAM simple-risc (Stage 3) |
| loop bounds | `measure`s and `size`s, already in the checker |
| callback contracts | `work g` of a function-typed parameter on the right-hand side (Stage 2) |
| opaque primitives | foreign declarations carry bounds or are ω (Stage 2) |
| static arenas / stack bound | `alloc`/`live` plus a `stack f <= n` quantity (the fourth quantity named in RESOURCE-BOUNDS) |
| "refuse anything unbounded" | a declared bound that cannot be proven is a compile error naming the ω |
| preemption latency | `segmax` from `Codegen.Bounds`, reported beside `work` |

One extension is needed beyond RESOURCE-BOUNDS: Stage 3's manifest is
ns-per-abstract-op times a safety factor, which is unsound on a cached
target. For the reference target the manifest's per-op cost must come from
the IPET + cache analysis over the selected low IR (section 4, items 1-2),
so a manifest entry becomes "cycles for this function's CFG under this
cache model", with the abstract-op form kept as the portable fallback.

### 4b. Proposal: the Sol bytecode VM as the reference interpreter

Status: proposal only; nothing implemented.

**Idea.** Section 3 asks for an executable reference over checked Core. The
Sol VM (`compiler/Sol/VM.hs`, `Bytecode.hs`, about 11k lines across
`compiler/Sol/`) already runs the shared FPRISC.hs surface -> Core pipeline
(`Sol/Lang.hs` imports `FPRISC`) on a bytecode interpreter written in
Haskell, independent of the native back end (`Codegen`, the C runtime). It
is the cheapest independent second implementation available.

**Semantics that differ from native today (from the source; each must be
closed or declared for a trap-exact reference):**

| Area | Native | Sol VM |
| --- | --- | --- |
| `Int` | 64-bit, overflow traps (`2026-10-12-INT-OVERFLOW.md`) | `VInt !Integer`, unbounded (`Sol/Val.hs:52`); no overflow trap |
| Int/Numeric mixing | separate types | `VInt` promotes into `VNum` on contact (`Val.hs:53`, `veq` 1 == 1.0) |
| division by zero | trap | `vmPanic "division by zero"` (`VM.hs:370`): same outcome, different text path |
| trap text | `*** FPRISC PANIC [actor N]: msg ***` | `*** SOL PANIC: msg ***` |
| evaluation order / trap order | native after fusion, inlining, discharge | bytecode order; JIT tiers (`HandJIT`, `JitCore`) are separate code |
| actors | real harts, C scheduler | VM scheduler; a spawned actor's panic printed, not propagated the same way (`VM.hs:507,638`) |
| host services | QOS / HAL | ScriptIO, Txn, Process; size caps (`16777216`) in host budgets |
| profile | `base`, `builtin` | `sol` prelude and `>` statements |

**What "reference mode" would be.** A `fpr sol --reference` (or
`FPR_SOL_REFERENCE=1`) switch that: uses checked i64 arithmetic with the
native trap points and texts; disables Int->Numeric promotion; disables
every JIT tier; uses a deterministic single-hart schedule (and a seeded
interleaving mode for actor tests); and accepts the `base` prelude so ordinary
`tests/std` and generated programs run unchanged. Output contract: stdout
equal to native, exit code equal, and the trap reason equal byte for byte.

**Pros.** Already exists and is exercised by the sol CI job; independent of
`Codegen`, the C runtime, region inference, reuse and the vector paths that
the differential most needs to check; Haskell `Integer` makes an
overflow-checking mode easy to write correctly; shares no low-level code
with native, so agreement is meaningful.

**Cons.** It shares the front end (parser, typechecker, Core), so front-end
bugs are invisible to it (the fuzz smoke and the exhaustiveness repros cover
some of that); it is a product interpreter with performance work in it
(JITs, caches), which is the opposite of a minimal reference, and each
reference-mode switch is a fork inside product code; it is slow for large
inputs; actor semantics differ enough that actor-heavy programs need their
own spec first. A minimal Core interpreter (a few hundred lines) would be
simpler to trust but is another implementation to maintain.

**Cost (estimate).** Reference-mode switches and trap texts: 1 week.
Running `tests/std` and benches through it with a diff gate: 3-4 days.
Generated-program differential (reference vs native x configs): reuses
`tests/reliability/config_differential.py`, 1 week for the generator.
Actor determinism spec: 1-2 weeks, can follow. CI: about 3-5 minutes on
the PR subset, the full set nightly.

**Recommendation.** Do it, scoped: reference mode on the Sol VM for
single-actor programs first, with the differences above as an explicit
checklist and a test per row; revisit a minimal Core interpreter only if the
shared front end turns out to hide real bugs.

### 4c. Design: sandboxing Sol `sh` by default (design only)

Status: design; not scheduled this week.

- **Default:** `sh`/`Process` children run with: read access to the
  script's directory, the working directory and system paths; write access
  only to the working directory and `$TMPDIR`; no network unless the script
  declares it; no new privileges.
- **Linux:** landlock (filesystem) + seccomp (no `ptrace`, no namespace
  escapes) + `PR_SET_NO_NEW_PRIVS`; degrade to an explicit warning on kernels
  without landlock rather than silently running unsandboxed.
- **macOS:** `sandbox-exec` with a generated profile (deprecated but
  shipped); otherwise a warning.
- **Opt-out:** `--unsandboxed` / `SOL_SANDBOX=0` per run, and a script-level
  declaration (e.g. `needs net, write "~/out".`) that widens the policy and is
  printed by `--explain`.
- **Compatibility:** a one-release warn-only phase logging what would be
  denied; existing tests run with the sandbox on to find scripts that need a
  declaration.
- **Tests:** escape attempts (write outside allowed roots, open a socket,
  `ptrace`) must fail with a named error; allowed operations must not.

Comparison (checked on the web this session: OTAWA is an open-source
IPET-based binary-level framework, documented ISAs ARM/PowerPC/SPARC/TriCore,
RISC-V via a separate loader; Patmos/T-CREST is a time-predictable processor
co-designed with aiT and platin. From recollection, not checked: aiT is
AbsInt's commercial abstract-interpretation WCET analyzer with cache/pipeline
models; SPARK/Ada Ravenscar restricts tasking for schedulability analysis and
proves absence of runtime errors; Lustre/SCADE and Copilot generate bounded,
allocation-free code from synchronous/stream programs, which is the model a
`wcet` profile's callbacks most resemble; I know of no mature Rust WCET tool
and would not cite one.)

## 5. Plan

Each step is small, mergeable, and either a new gate or behind a flag
(`FPR_NO_*` / `FPR_*_VALIDATE`). Efforts are estimates.

### Quick wins (this week)

| Step | Effort | Gate / metric |
| --- | --- | --- |
| Fix bugs 1-4; add each repro as a regression test | 1-2 d | repros pass |
| CI job: `fpr stdcheck` over `std/*.fpr` | 0.5 d | stdcheck OK on every std module |
| CI job: config-differential matrix over `tests/std` (the 11 configs above) | 1 d | 0 differences; ~10 min |
| CI job: UBSan runtime build of `tests/std` (`FPR_CC` wrapper) | 0.5 d | 0 `runtime error` lines |
| CI job: 2000-mutant fuzz smoke of `fpr check` with a fixed seed | 0.5 d | 0 crashes; new crashes become tests |
| Panics to stderr (keep stdout clean), documented exit codes | 0.5 d | output tests |
| Compile-time budget for `vecwide.fpr`-class inputs (18.7 s) tracked with the quadratic families | 0.5 d | recorded, not yet gated |

### Medium (weeks)

| Step | Effort | Gate / metric |
| --- | --- | --- |
| ASan fiber annotations in the context switch; ASan CI job | 2-3 d | 0 reports |
| Reference interpreter over checked Core, trap-exact | 2-3 wk | agrees on all `tests/std` and benches |
| Well-typed program generator + differential (reference vs native x configs x x86-64/QEMU RV/Sol VM) | 2 wk | N programs/night, 0 mismatches; failures auto-minimized |
| Translation validators: `Interval.discharge` first, then `Allocate`, `Reuse`, `LoopForm`/`StringScan` (`FPR_VALIDATE_<PASS>`) | 1 wk each | on in CI; 0 rejections |
| Mutation-testing script for `Interval`, `Bounds`, `Reuse` | 3 d | mutation score recorded per pass |
| Extend stdcheck's fragment to constructor/list patterns so std list code has costs | 1-2 wk | list.fpr functions not opaque |
| Hosted watchdog option (wall-clock or fuel budget per actor turn) | 3 d | infinite loop terminates with a named trap |
| Sol `sh` sandbox (landlock/seccomp on Linux, sandbox-exec on macOS), opt-out flag | 1 wk | escape tests |

### Research-grade (months)

| Step | Effort | Gate / metric |
| --- | --- | --- |
| simple-risc timing model (BRAM config to validate the pipeline model, then the cached SDRAM reference target), cycle-level IPET on selected IR | 1-2 mo | bound >= observed `mcycle` on every admitted function; tightness reported |
| Bounds in the type system (RESOURCE-BOUNDS Stages 2-4): manifests from IPET, `stack` quantity, static arenas, no refill/growth under a declared bound, JSON report | 1-2 mo | rejection tests for each missing property |
| Binary-level cross-check (own or OTAWA-style) | 1 mo | agrees with IR-level bound |
| Mechanized semantics (Lean 4) of Core subset; proofs for discharge and fusion trap-order | 3+ mo | proofs checked in CI |
| Cache-aware analysis (must/may) for the cached SDRAM reference target: required | 2+ mo | as above |

## 6. Decisions (Jack, 2026-11-01)

1. **Reference WCET target: the cached SDRAM simple-risc configuration.**
   A cache model is required (section 4, item 1); uncached BRAM is a
   validation stepping stone only.
2. **WCET is not a profile.** It always exists and lives in the type system
   with the existing `| work f <= ...` syntax (section 4a).
3. **CI budget: under 30 minutes total, ideally 15-20.** New checks run in
   one `reliability` job in parallel with the x86-64 job (no added wall
   time), with fixed seeds, a PR subset and a nightly full run (PR #44).
   Heavy work (full configuration differential, 2000-mutant fuzz) is nightly.
4. **Yes to machine-maintained contracts:** `tests/reliability/std_contracts.py`
   fails on drift and `--fix` rewrites (PR #41).
5. **Reference interpreter:** write a proposal for the Sol VM (section 4b).
6. **Sol `sh` sandbox by default: yes, design only for now** (section 4c).

### This week's items: status

| Item | PR |
| --- | --- |
| A. bugs 1-4 with regression tests | #43 (stdcheck arity), #41 (log contracts), #42 (Exhaust crash), #40 (qsort NULL) |
| B. reliability CI job | #44 |
| C. panics and diagnostics to stderr | see the PR linked from #39 |
| D. vecwide compile-time tracking | see the PR linked from #39 |
| E. contract-sync check | #41 |
| F. this update | #39 |

## Verified vs unverified

Measured this session: everything in sections 2 and the CI counts. Cited from
the tree: section 1 rows and file:line references. Estimates: all efforts and
any expected effect of the plan. Web-checked: OTAWA, Patmos/T-CREST.
Recollection: aiT, SPARK/Ravenscar, Lustre/SCADE, Copilot, Rust tooling.

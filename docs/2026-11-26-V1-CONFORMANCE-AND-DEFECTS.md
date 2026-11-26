# v1.0: the conformance suite starts, and the first defects are fixed (26 November)

Kind: delivery record. Branch `v1-defects`, from `main` at `f607eb59`.
Checked on macOS arm64 (posix, Base); other targets were not run.

This works through the first items of "What to do with this page" in the
[v1.0 semantics draft](2026-11-26-V1-SEMANTICS.md) (§12): fix the defects that
need no decision, start implementing the decisions of 26 November, and turn
clauses into conformance cases.

## 1. Stage 0 of the core spec: `tests/conformance/`

The [core spec](2026-11-19-V1-CORE-SPEC.md) §5.5 puts a conformance suite first,
"one `.fpr` case per spec clause". It had not been started. It exists now:

- **Cases:** `tests/conformance/NAME.fpr`, whose first line names the clause it
  tests.
- **Expected outcome:** one of these files beside the case:
  - `NAME.expected`: the exact standard output.
  - `NAME.exit`: the expected exit code (default 0).
  - `NAME.refused`: the program must not compile, and the compiler's output must
    contain the file's text.
- **Runner:** `tests/sol-checks/conformance.sol`, registered in
  `tests/sol-checks.tsv` as a push-tier check. It builds every case in parallel
  and runs them one at a time.
- **Known failures:** a clause the compiler does not meet yet is a row
  `conformance:NAME` in `tests/sol-checks-known-failures.tsv`. The check fails
  when such a case starts passing, so fixing a defect means deleting its row.

It runs native posix only. Running the same cases under Sol and on the other
targets (Q6, and "native (x64/A64/RV) and Sol" in §5.5) is the next step.

| Case | Clause | Today |
|---|---|---|
| `lex-keyword-prefix` | §1: a name may begin with `case`, `of` or `Type` | passes (fixed, §2.1) |
| `safety-local-recursion` | §6: a recursive local function needs a marker | passes (fixed, §2.2) |
| `precond-literal-zero-divisor` | §7 rule 2: a decidably false precondition is refused | passes (implemented, §3) |
| `precond-opaque-divisor` | §7 rule 4: an unproved divisor is a run-time check that traps | passes (already true) |
| `eq-float-structure` | §5: `==` is structural and IEEE inside structures | **known failure** (§4) |

## 2. Defects fixed

### 2.1 Names beginning with `case`, `of` or `Type`

**The bug:** `casesArg`, `ofTen` and `Typed` did not parse. The parser matched
those three keywords with `symbol`, which checks for no word boundary.

**The fix:** they now use `keyword` (`Frontend/Parser.hs`), as `fn`, `if` and the
others already did.

**Sol:** Sol shares the frontend, so `casesArg` now works there too. The
[Sol review](2026-11-26-SOL-SCRIPTING-REVIEW.md) listed it as a porting cost.

### 2.2 Local recursion escaped the safety rule

**The bug:** a recursive function defined inside a block compiled with no marker.
The call graph walked a local function's body with the function's own name
already in scope, so the self-call was never seen.

**The fix:** the call graph now records, for each top-level function, the local
functions in it that call themselves (`cgLocalRec`, `Safety.hs`). A top-level
function containing one counts as recursive, and the diagnostic names the local
function:

```text
main is unsafe (its local function `go` is recursive) but has no explicit
`main : unsafe ...` signature
```

A local function can carry neither a signature nor a measure, so a measure on the
outer function does not excuse it.

**Sol:** Sol runs the same check (`checkSafety`), so the rule applies to Sol
scripts too.

**Impact on existing code:** none. `fpr stdcheck` passed, and so did every Sol
check apart from the two in §5.

## 3. Decision implemented: preconditions rule 2

Decided 26 November (semantics §7): a precondition the compiler proves false is
refused in every layer.

**How:** `Precond.hs` gains a `Refuted` status. A site is refuted when the local
facts entail the predicate's negation. The facts are the same ones that already
discharge obligations: the function's own preconditions, clause guards, `case`
discrimination and literal binds. The driver (`Compile.hs`) prints refuted sites
under `=== PRECONDITION: ERRORS ===` and stops.

| Program | Before | Now |
|---|---|---|
| `1 / 0` | trapped at run time | refused: `main: (/) requires (divisor != 0), which is false here` |
| `7 % 0` | trapped at run time (`%` was not analysed at all) | refused the same way |
| `case n of 0 -> 10 / n` | trapped when reached | refused: that arm can never divide |
| `pos (-3)` with `pos : (n : Int \| n > 0) -> Int` | inserted check, trapped | refused: `pos requires (n > 0, given -3)` |
| `f n \| n != 0 = 10 / n` | discharged | unchanged |
| an opaque divisor | run-time trap | unchanged (rule 4) |

`%` is now analysed like `/` (discharged, refuted, or left to the trap).

**Not done under §7:**
- **Rule 3** waits on a definition of "bounded unit".
- **Rule 4's report:** an ordinary compile still prints only the one-line count.
- **Sol** does not run the precondition pass, so `1 / 0` still compiles in a Sol
  script.

## 4. Not fixed: `==` on structures holding a float

**The defect** is wider than the semantics page says. All of these exit with
signal 11 (exit 139):
- `(1, 1.5) == (1, 1.5)`;
- the same for a list or a record;
- a polymorphic `eq : a -> a -> Bool` used at `F64`;
- a polymorphic `show x = "{x}"` applied to `(1, 1.5)`.

So "printing a structure that holds a float is refused at compile time" is true
only where the type is known at the call. A nominal type's own `F64` field works,
because the layout table marks it raw.

**The cause:** the runtime's structural equality (`veq`) and its printer find a
value's shape from its header. A float stored in a tuple, list or record field,
or passed at a type variable, is raw IEEE bits, and they get followed as a
pointer.

**Three ways out**, an owner decision:
1. **Refuse at a known type, like print.** `==` at a concrete type that holds a
   float outside a raw field becomes a compile error. Small. The polymorphic case
   still crashes, for both `==` and printing.
2. **Constrain the type variables.** A type variable that reaches `==`, `!=` or
   rendering may not be instantiated at a float-holding type, which makes both
   cases safe. Medium. It is close to an implicit `Eq`/`Show` constraint, and Q2
   excludes implicit typeclasses from v1.0.
3. **Typed equality and printing.** The compiler generates a comparison and a
   renderer per concrete type, which gives the IEEE rule the semantics page
   states. Largest, and it still needs 2 or a dictionary for polymorphic code.

## 5. Suite results and issues found

- **How the suite was run.** `tests/run.sol` interprets each check with `sol`
  from `PATH`, or `FPR_CHECK_SOL`. CI links that name to the freshly built `fpr`.
  On this Mac, `sol` on `PATH` is the `fprmeta` launcher's Sol 0.13.0, so a plain
  local run mixes an old Sol with the branch's compiler. Run it the CI way:
  a symlink named `sol` pointing at the built `fpr` (it acts as Sol only under that name), passed as `FPR_CHECK_SOL`.
- **What Sol 0.13 misreported.** Run with 0.13, `publish-release-index` fails with
  type errors in `std/map` spliced through `sol/lib/cli` (`unbound name:
  O.None`), because 0.13 predates the 22 November `None` fix. The new
  `conformance` runner also could not use a name beginning with `case` there. Its
  helper is named `conformanceCases`, so it parses under both.
- **Updated for rule 2.** `ideal` and `pagination` asserted that calls with
  literal arguments that violate a precondition panic at run time. Those calls
  are now refused at compile time.
  - Their run-time cases now pass an opaque zero (`z = List.len []`), so they
    still test rule 4.
  - `ideal` gains two cases asserting the literal form is refused.
- **Result, run the CI way:** 32 checks, 0 unexpected outcomes; the only
  failure is the recorded `conformance:eq-float-structure`. `result-sizes`
  passes. Its failure seen earlier came from Sol 0.13.
- **Haskell unit suites:** all 46 pass (`make unit-tests`).
- **Examples:** eight `examples/*.fpr` programs fail to build, the same eight
  with `main`'s compiler: `checkdemo`, `pos1_core`, `pos1_pricing`,
  `printer-host`, `stax` and the three `tangnano20k_*`. Not caused by this
  branch, and not investigated.
- **Still to decide** (semantics §10): the four linear leaks. `print`/`str`,
  `drop` and `send` each count as a linear value's one use and free nothing, and
  a path that ends in `error` owes nothing. Each fix changes what programs may
  write:
  - refuse rendering a linear value, or provide a hand-back form;
  - make `drop` free;
  - refuse `send` of a linear value in favour of `sendLinear`.

# Callable ownership: closures and partial applications are single-use

Implemented locally, 9 November 2026, on `fix/ownership-closure-pap-holes`
(from `0e14b0e`). This is priority 3 of the
[performance priorities](2026-11-09-PERFORMANCE-PRIORITIES.md): close the four
ownership probes that `tools/audit_linear_ownership.py` still accepted at
`bc11824`, and gate CI on the audit. It is item 3 of the
[ownership corrections' next work](2026-10-17-OWNERSHIP-CORRECTIONS.md#next-compiler-work).

## The rule

A closure that captured a linear value, and a partial application that holds
one, owns that value. It is single-use: it must be called, or passed on,
exactly once. Nothing in its type says so, so the checker tracks it through the
ownership shape (`LCon "fn" False [owners]`, `Ownership.Shape.closureShape`).
That shape already existed for a lambda bound to a local; the gaps were the
places where it was lost.

| Audit probe | Was accepted because | Now |
| --- | --- | --- |
| `higher_order_twice` | a function-typed parameter was unrestricted, so a body calling it twice constrained nothing | function-typed parameters are symbolic (`->i/k`, like a type variable); a body that calls or copies one more than once, or never, records "must be unrestricted"; a call passing a single-use closure there is refused |
| `closure_return` | a function-typed result was unrestricted | the result records its arity; a call that supplies the declared parameters but not the returned function's own holds the owned arguments |
| `aliased_pap` | partial application was detected only on a named head with a signature | a global referenced as a value carries its arity, so `alias = at; alias t` is a partial application |
| `dynamic_pap` | a non-variable head (`(case .. of .. -> at) t`) returned unrestricted | an expression head of unknown arity is assumed partial: owned arguments make the result single-use |

Diagnostics:

```
'twice' may call its function argument #1 more than once (or never), so it cannot take a single-use closure there (a lambda or partial application that captured a linear value)
linear variable 'f' used 2 time(s), expected exactly 1; it is a closure or partial application holding a linear value, so it is single-use
```

## Neighbouring holes closed with them

Probing around the four cases found more ways to lose a single-use closure.
Each is a refusal case in `tests/check_callable_ownership.py`, with a legal
twin that must build and run identically in native and HostedBytecode.

- **Primitives with callbacks.** A primitive has no body to read. The ones that
  call their callback per element or per iteration are listed in
  `Ownership.Shape.repeatedCallbackPrims`: `Vec.map`, `Vec.mapSame`,
  `Vec.filter`, `Vec.fold`, `Sys.loop`, `Sys.loopWith`, and HostedBytecode's
  list schemes `map`, `filter` and `foldl`. Sol had accepted
  `List.map f xs` with a single-use `f` (its prelude reaches the `map`
  scheme), which native already refused through `std/list`'s body. `Sys.arena`
  and `spawn*` call their callback once and are not listed. A source
  definition with the same name (a module's own `map`) is read from its body.
- **Function types nested in a parameter** (`((Int -> Int), Int)`, a record
  field, `List (Int -> Int)`): symbolic too, named by their path (`->0.1/1`).
  The diagnostic says "a function inside its argument #1".
- **Function types nested in a result** (`Token -> ((Int -> Int), Int)`):
  they are `heldVar`. What a call's result holds there comes from the body,
  through the same fixpoint as the other obligations, so wrappers inherit it
  and inferred signatures get it too:
  - If the body returns a surely-owned closure there, the function records
    `heldVar`, and every result is single-use. This covers `pair t = (fn n ->
    consume t + n, 0)` and also a closure over an owner the callee made
    itself (`mk k = t = Token k; fn n -> consume t + n` behind
    `Int -> (Int -> Int)`).
  - If the body returns a closure over a symbolic owner (a callable
    parameter passed through, a `t : a`), the function records `heldOf v`.
    The call's result then holds what the call passed for `v`. An owned
    argument beside a passed-through callback therefore does not make the
    callback single-use (`std/mvu.fpr`'s `renderStep`).
- **Joins of two callables** (a case returning one of two callback
  parameters) stay symbolic and hold what either holds. Before, they
  collapsed to a sure owner. That made `examples/pos1.fpr`'s pricing record
  of functions owned once callables were symbolic.
- **Function-typed constructor fields.** `Holder (fn n -> consume t + n)` for
  `Holder = Type (Holder (Int -> Int))` lost the owner: the constructed value's
  type cannot say its field is single-use. Constructing one is refused ("pass
  the owner as its own field instead"). Over a callable parameter, the
  enclosing function's parameter is constrained instead. For example, a
  decoder combinator that wraps its callback in a constructor then refuses
  single-use callbacks. A generic field (`Some f` with field type `a`) is
  unaffected, because it already carries the payload's ownership.
- **Lambda-bodied definitions.** `twice = fn f -> (f 0, f 1)` is read as
  `twice f = (f 0, f 1)`, both by the checker and by inferred signatures.

## Not covered

- **A linear value in a top-level constant.** `c = mk 7` (or `g = Token 7`)
  can be referenced from any number of places. Global references are not
  counted, so `c 1 + c 2` is accepted. This predates callables (`g = Token 7`
  is accepted the same way). It needs a rule for linear globals: refuse them,
  or count them per program.
- **An unknown-arity local applied to an owner** (`(fn h -> h t) at`, where
  `h` is a lambda parameter with no signature). A local callable with a known
  arity (a callable parameter, a function name, a constructor field) is
  checked. One without a known arity is treated as fully applied, as before.
  Treating it as partial would be sound. Whether it refuses current code has
  not been measured; see open questions.
- **Named record types with function fields used as parameters**
  (`Handlers = { on : Int -> Int }` spelled by name in a signature). A
  record written out in the signature is covered; a named one reads through
  `shapeTyTable` without the callable walk.
- **Linear-type constructors with function fields** are refused like any
  other constructor (conservative), rather than letting the linear value own
  the closure.

`keep` remains the explicit escape: `Sys.loop 0 (step (keep v))` still compiles
and is stopped by the runtime's "the callback may not capture a Vector" check.
`tests/check_loop_state.py` now asserts both the static refusal of the plain
form and the runtime backstop under `keep`.

## Validation

All runs were local, on the shared Linux x86-64 box (8 vCPU).

- `tools/audit_linear_ownership.py`: 0 invalid probes accepted by either
  frontend; only `keep_escape`, the explicit escape, is accepted (it was 4 at
  `0e14b0e`). It takes about 5.5 s wall (CI-style); about 10 s with `--native-run`.
  [Recorded output](evidence/2026-11-09-linear-ownership-after-callables.json)
  comes from `--native-run --json`.
- `tests/check_callable_ownership.py` (new, in `check_base`): 34 cases. That
  is 19 refusals checked in both frontends, 3 Sol-only scheme refusals, and 12
  legal programs built natively and run in both with identical output. It took 14.6 s in the full `check_base` run at `b05d682` (one of four workers).
- Every tracked `.fpr` was run through `fprc --check-only` (632 files), and every
  `.fpr`/`.sol` through `fpr sol --asm` (750 files). Both ran against `0e14b0e`
  and the branch. No file changes verdict in either frontend: 0 of 632 and 0
  of 750 differ in exit status or linearity refusal. The three files Sol
  refuses for linearity are refused identically at `0e14b0e`. Earlier
  revisions of this change failed this sweep: 70 files over four std sites,
  each traced to a join bug and fixed above, not by weakening the rule.
- Full `check_base` job list on the branch, compared job-by-job against
  `0e14b0e` on the same box: 226 jobs / 191 ok / 35 failed at `b05d682`
  (the new `tests/check_callable_ownership.py` job, 14.6 s, ok) versus
  225 / 190 / 35 at `0e14b0e`. Zero status flips among the shared 225 jobs.
  The 35 failures match base and are the ones this box already hits without
  clang/riscv toolchains (and a few pre-existing segfault/oracle failures
  that also fail at `0e14b0e`). Recorded as
  `/workspace/out/fpr-own/final.json` vs `base.json`.
- `tests/check_compile_budget.py` passes. This platform (ghc-9.8.2
  x86_64-linux) has no recorded baseline, so the same script also ran at
  `0e14b0e`. Allocation: hello 1,347,055,472 vs 1,345,816,296 bytes (+0.09%),
  std-live 29,113,088,016 vs 29,089,165,672 (+0.08%), pos1 60,547,393,912 vs
  60,462,587,776 (+0.14%). Peak live is within 0.6%.


## Open questions

For Jack, before treating this as done beyond the four audit probes:

1. **Linear top-level constants.** `c = mk 7` (or `g = Token 7`) can be
   referenced from any number of places because global references are not
   counted. Refuse linear globals, or count them per program?
2. **Unknown-arity locals applied to an owner.** `(fn h -> h t) at` still
   treats `h` as fully applied. Treat unknown-arity application as partial
   (sound, may refuse more code)? A sweep of how often that fires has not
   been run.
3. **Named record types with function fields** used as parameters
   (`Handlers = { on : Int -> Int }` by name). Cover them the same way as
   inline record types in signatures?
4. **Linear-type constructors with function fields** are refused
   conservatively today. Prefer letting the linear value own the closure
   instead?
5. **`keep` escape.** Still accepted by the audit (explicit). Leave the
   runtime Vector-capture backstop as the only stop, or tighten further?

## CI

`.github/workflows/ci.yml` runs the audit as a step of the reliability job,
after `make fpr`. Exit 1 (an invalid probe accepted) fails the job. It adds
about 5.5 s (measured locally at `b05d682`, CI-style, no `--native-run`). `tests/check_callable_ownership.py` runs in `check_base` (x86-64
job), where it adds about 30 s of one worker's time.

# 2026-09-02-DESIGN_PATTERNS.md — FP-RISC and Sol

Conventions that are fixed. The goal is that once these are learned, most
"should it be this way or that way" questions stop being questions. Anything
not listed here is situational and can be decided case by case.

## 0. Meta-rules

- **Decide a model, then be consistent.** The primary design question is
  always "what is the actual model M?" How it is spelled is secondary, as long
  as it is consistent with everything else and has no obvious defects
  (redundant or overlapping names, argument orders that don't follow the same
  scheme).
- **Pareto set → pick one → stick with it.** When several candidate models are
  non-dominated, enumerate them, choose one (randomly is fine), and commit. Do
  not reopen the decision without a new dominating argument.
- **Recognition over recall.** Docs, examples, and content-addressed search are
  the memory. Naming and features must be strict enough that a half-remembered
  name resolves by pattern.

## 1. Naming and call form

- **`Module.func` is the only call form** for builtins and APIs. No
  `object.method`, and never a mix of both (Elm, not Python).
- Modules are nouns (`List`, `Vec`, `Memory`, `MVU`, `FPRLive`); functions are
  verbs or verb-phrases.
- No two functions in scope should overlap in meaning. If two names could
  plausibly describe the same operation, one of them is wrong.

## 1a. Operators are the default

Every value kind spells its natural operation with the arithmetic
operators, resolved by the operand types at each site (Elm-style
`Module.func` stays for everything that is not one of these):

| operator | Int / Numeric | String | List | Vector | Matrix | your type |
| --- | --- | --- | --- | --- | --- | --- |
| `+` `-` | arithmetic | concat / drop a matching suffix | append / drop a matching suffix | elementwise (both consumed) | elementwise (both consumed) | a struct field `(+)` / `(-)` |
| `*` | arithmetic | | | dot product; `k * v` scales | matmul; `m * v` is matrix times vector | `(*)` |
| `/` | quot on ints, real on inexact | | | | | `(/)` |
| `%` | truncated remainder (C, RISC-V `rem`), inexact too | | | | | `(%)` |
| `^` | exact exponentiation by squaring; a fractional or negative exponent is refused by name (`Num.div 1 (a ^ n)` is the inexact reciprocal) | | | | | `(^)` |

- A helper named for one of these operations (`dotProd`, `strConcat`,
  `listAppend`, `mod2`) is wrong: write the operator.  `List.append`,
  `Numeric.mod`, `strcat` remain as the operators' definitions, not as
  the spelling to use.
- `^` binds tighter than `* / %`, which bind tighter than `+ -`; `^` is
  right-associative (`2 ^ 3 ^ 2 = 2 ^ 9`).
- Operators on linear values (Vector, Matrix) CONSUME both operands and
  return one fresh value; use the `M.mul` / `Vec.mmul` threading forms
  when an operand is needed again.
- Mixed operand types (`Matrix * Vector`, `Int * Vector`) resolve to a
  struct operator whose two parameter types match; same-type sites
  resolve on the first parameter alone.  Nothing is registered: the
  operator's own signature is the instance.
- Inside a native kernel (Vec.map / Vec.fold / list schemes) `%` and `^`
  compile like any other arithmetic, and an `error "..."` guard compiles
  to a trap, so operator-heavy element functions stay on the JIT.

## 2. Argument order

One scheme for everything:

```
Module.func  <function>  <secondary data> <initializer> <main data>
```

- **Higher-order functions:** function first, then the collection, then any
  initializer last. `List.foldl f z xs` — the main data sits just before the
  end so it pipes: `xs |> List.map f z`
- **Two-collection functions** (`zip`, `merge`, `diff`): the "main" data is
  last, the other operand before it.
- **Configs** are the first argument after the function argument (if any) and
  before data; see §3.

## 3. Configs and secondary parameters

- **Definition.** A parameter is *secondary* if it does not change the core
  command or state machine of inputs → outputs, but shifts or adds to it:
  verbosity, caching, logging, retries, limits, formatting. A parameter that
  changes the *type* of the output is primary and gets its own positional slot.
- **All secondary parameters go in one record**, and the record contains the
  *entire* set of configs for that function. No optional trailing args, no
  keyword args, no half-in-record/half-positional splits.
- Every configurable function has a `Module.defaults` record; callers write
  `{ Module.defaults | verbose = True }`.

## 4. Application structure

- **MVU is the only application framework.** Do not reinvent MVU or introduce
  another architecture. Every app is `MVU.serve { init, update, view }`.
- **`view` returns a scene, not a widget tree:** `Scene2D`, `Scene3D`, or
  `None`. This is what lets one model cover web apps, desktop apps, games, and
  headless/remote services (which return `None`).
- **Remote:** `FPRLive` + MVU is the default and recommended way to develop
  and run anything remote — client/server apps, live sessions, telemetry.
- **Local:** local MVU is the recommended way for local apps.
- Effects and subscriptions are expressed as data returned from `update`, not
  performed inside it. If you find yourself needing a second lifecycle, the
  scene type or the command type is what should grow, not the framework.

## 5. Writing code

- **Prefer builtin composition to helpers.** Before writing a helper function, use the
  content-addressed search over docs, examples, and modules; copy or follow an
  existing pattern directly in place - dont spam helpers everywherem but still keep everything concise. A missing example for a feature is a bug in the corpus.
- **Recursion schemes and `|>` wherever possible.** Explicit recursion is the
  exception and should be justifiable on the spot.
- Examples are executable and part of the test sweep; they are the spec.

## 6. Open / to be pinned (proposed, not yet decided)

Each item names the decision, what the corpus does today (counts in
docs/2026-09-02-API-REVIEW.md), and a proposed answer.  Pinning one means moving it
up into §1–§5 and migrating the corpus in the same change.

- **D1 Bare HAL names vs `Module.func`.** Sol has `strlen charAt substr chr
  strcat` AND `Str.len at sub fromCode cat`; FP-RISC tests use the bare
  forms 50:2, Sol examples the module forms 8:0.  Proposed: `Str.*` is the
  API in both profiles; the bare names are the codegen contract
  (`fpr_g_*`) and never appear in examples.
- **D2 One spelling per operation.** `Str.parse` = `parseInt` =
  `unwrap (Try.parseInt s)`; `List.fold` = `foldl`; `List.map` = `map`.
  Proposed: keep the `Try.x` / `x` (unwrapping) pair as the ONLY sanctioned
  double, retire the third spellings.  (Pinned for the operator cases in
  §1a: `+ - * / % ^` are THE spelling; the corpus was migrated.)
- **D15 Lists under `*` -- DECIDED: none.** Vectors give `*` to the dot
  product; lists keep only the structural `+ -`.  `Vec.fromList a *
  Vec.fromList b` is the spelling for a list dot product.
- **D3 Filesystem verbs.** `readPath writePath mkdirp rm rmdir mv ls stat
  exists isDir` + the `Now` escapes are Unix names, not a module.
  Proposed: `File.read write mkdir rm rmdir mv ls stat exists isDir`,
  `File.readNow` etc.; `@path` literals unchanged.
- **D4 Two process vocabularies.** `sh` / `shq` (strings, immediate /
  queued) next to `Proc.query / afterCommit / runNow` (structured).
  Proposed: `Proc.sh` and `Proc.shq`, documented as the string doors of
  the same three-way (immediate / queued / realtime) model.
- **D5 Actor spellings across profiles.** Sol `myself spawn send receive
  receiveFrom kill yield`; FP-RISC `Actor.self spawn spawnOn send recv
  recvRes yield`.  Proposed: `Actor.*` in both, `self` and `recv` win
  (shorter, already the FP-RISC struct).
- **D6 Index-before-data.** `Vec.get i v` is data-last but `Str.at s i`,
  `Str.sub s i n`, `Str.findFrom c s i` are data-first, and FP-RISC
  `List.take l n` is the mirror of Sol `List.take n xs`.  Proposed: indices
  and counts are secondary data and come BEFORE the main data everywhere;
  infix `xs ! i` is exempt as an operator.
- **D7 Failure channels.** In use at once: `Result`, panic, a list as an
  option (`List.find`), three local `Opt`/`Some|None` unions, and 0 as a
  sentinel (`Str.find`).  Proposed: ONE prelude `Option (Some x | None)`;
  `Result` when the failure has something to say, `Option` when absence is
  ordinary, panic only behind an unwrapping name (`parseInt`, `unwrap`,
  `!`).
- **D8 Verb vocabulary.** `get` = by key/index (total or Option); `find` =
  by predicate (Option); no `lookup`.  `new` = empty container; `fromX` /
  `toX` = conversions; `parse` = text -> value (Result); `render` = wire
  text; `pretty` = human text; `show` = debug text.  `len` stays the one
  size word.
- **D9 `Module.defaults`.** Zero APIs follow §3 today (`MV.run`'s cfg is
  half positional, `ProcessSpec` is positional with `with*` builders).
  Proposed: convert `ProcessSpec` to `{ Proc.defaults | cwd = "/tmp" }` as
  the reference, then require it for every new configurable function.
- **D10 One MVU entry shape.** The doc's `MVU.serve {init, update, view}`
  exists in neither profile: FP-RISC has `MV.run me cfg (MApp init update
  skey view vals done subs)`, Sol has `View.serve port init update view
  subs`.  Proposed: the record form, one name in both profiles, `skey /
  vals / done` as config or scene content.
- **D11 The one object-method.** Typed path literals are called
  `p.get m` / `p.set v m` (10 uses) while everything else is
  `Module.func`.  Proposed: sanction it as the single exception (the
  literal IS a record of closures) and say so in §1, or add `Path.get`.
- **D12 Two preludes.** Sol's `Str`/`List` surface is 4x FP-RISC's, so
  FP-RISC tests re-declare `revL joinBar escLf splitNl lenL catL` per file.
  Proposed: grow the FP-RISC structs to the Sol names (same grammar, same
  spellings), accepting that `std` proof obligations gate which ones the
  AOT tier admits.
- **D13 Two-way conditions.** Guard clauses versus
  `case c of True -> a | False -> b` for the same job: Sol 137 / 90,
  FP-RISC 76 / 65.  Proposed: guards
  for clause selection on parameters, `case` for a computed condition in
  a body; never `case` on a literal `True/False` when a guard fits.
- **D14 `unsafe` in examples.** `unsafe` versus `measure`: FP-RISC tests
  262 / 43, Sol 176 / 37.  Proposed: an example may carry `unsafe` only with a
  one-line reason; a plain countdown or list walk uses `measure`.
- Whether config records are open or closed to extension (unchanged).

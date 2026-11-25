# FP-RISC v1.0 semantics: first draft from the implementation (26 November)

Kind: **draft register**, to be kept current like the
[v1.0 core spec](2026-11-19-V1-CORE-SPEC.md), which it sits beside. The core
spec decides types, layers and the cleanup; it says nothing about the surface
language, evaluation, failure, modules or actors. This page starts those.

How to read it. Every clause carries one of three marks:

- **[is]** what the implementation does today, read from the code or shown by
  a small program. Proposed as the 1.0-rel rule unless someone objects.
- **[decide]** the implementation does something, but pages disagree with it
  or with each other, or the behaviour looks accidental. The owner decides.
- **[defect]** the implementation is wrong by its own rules. Fix, do not
  specify.

Nothing here is decided by this page. A clause becomes a rule when the owner
accepts it and it has a test (the conformance suite of core spec §5.5 stage 0
does not exist yet; each **[is]** clause below is a candidate case for it).

Evidence. Checked on 26 Nov 2026 against `main` at `f607eb59` plus the branch
`zero-cost-named-keys`, with `fpr 0.16.0-dev` on macOS arm64, posix, Base
profile. Other targets and Sol were not run. Sources are named by file and
function; line numbers rot. The alpha 2 contract, [SEMANTICS.md](SEMANTICS.md),
was the starting point: where it is still right it is restated here, and §11
lists where it is wrong ([Version names](2026-11-26-VERSION-NAMES.md) rule 3).

---

## 1. Lexical structure

- **[is] Comments** run from `#` to the end of the line. There is no block
  comment. `#:` lines are comments to the compiler; build tools read them.
- **[is] Layout** is free: newlines and indentation mean nothing.
- **[is] A definition ends with `.`** that is not followed by a letter.
- **[is] Names.** A name starts with a letter; the rest are letters, digits,
  `_` or `'`. Lowercase first letter: values, functions, parameters, type
  variables, record fields. Uppercase first letter: constructors, types,
  module aliases. `A.b` with an uppercase head is a qualified name; `a.b` with
  a lowercase head is a record field access. `_` alone is the wildcard.
- **[is] Reserved words:** `fn case of if then else Type Sig Struct use`.
  `and`, `or`, `unsafe`, `measure`, `profile`, `deprecated`, `Layout`,
  `program`, `module` are words with a meaning in one position only and may be
  used as names elsewhere.
- **[defect] A name beginning with `case`, `of` or `Type` does not parse** in
  an expression (`cases`, `casesArg`): those three keywords are matched
  without a word boundary (`Frontend/Parser.hs`).
- **[is] Integer literals** are decimal. A `-` directly before a digit makes a
  negative literal; there is no unary minus, so `3 -1` applies `3` to `-1`.
- **[decide] Literal range.** A literal outside -2^62..2^62-1 is a parse
  error, although `Int` is exact. Either lift the limit or state it.
- **[decide] No hexadecimal or binary literals** (`0x…` is refused with a
  message). Bit-level code writes decimal masks today.
- **[is] Float literals:** `1.5` and `1e3` are `F64`; a `d` suffix is `F64`,
  an `f` suffix `F32`. `1.` is the integer 1 and the terminator.
- **[is] String literals** are byte strings; a source character is its UTF-8
  bytes. Escapes: `\n \t \r \0 \{ \} \" \\ \xHH`. `{expr}` interpolates (§5).
- **[decide] String patterns take no escapes.** The pattern `"a\nb"` matches a
  backslash and an `n`. Either give patterns the literal's escapes or refuse a
  backslash in a pattern.
- **[is] Other literals:** `?name` and `??` are typed holes (a hole that is
  reached traps); `@path` is a path literal.

## 2. Top-level forms

Definitions may appear in any order.

| Form | Syntax |
|---|---|
| Value or function | `name pat* = block .` or, with guards, `name pat* \| guard, guard = block .` |
| Signature | `name : part -> part -> result .`, optionally `unsafe` after the colon and resource bounds after a `\|` |
| Type | `T a b = Type (A \| B x y).`; `T = Type Int.` is a new type whose constructor is `T`; `T 1 … = Type …` makes it linear |
| Record shape | `P = { x : Int, y : Int }.` |
| Import | `A = use "path".` or `A = use "path#hash".` |
| Name alias | `T = M.T.` |
| Interfaces | `N = Sig { f : T -> U }.` and `N = Struct Sig1 { f = e }.` |
| Layout | `N = Layout { f : T @off }.` |
| File marker | `unsafe program.`, `unsafe module.`, `profile base.` (also `builtin`, `extbase`, `sol`), `deprecated "path".` |

- **[is] All clauses of one name form one function**, even when other
  definitions sit between them. Clauses of different arity are a type error.
- **[is] A signature part** is a type, `(v : T)`, or `(v : T | predicate)`.
  The predicate is a precondition (§7). `measure e` inside it is a
  termination measure. Trailing bounds are `work f <= e`, `alloc f <= e`,
  `live f <= e`, `size f <= e`. A malformed signature is a parse error.
- **[is] Types:** application, tuples `(a, b)`, functions `a -> b`, records
  `{f : T}` and open rows `{f : T | r}`, `_` for a hole.
- **[is] `main`** is an ordinary nullary definition and the entry. If it
  answers an `Int`, the process exits with that value modulo 256; any other
  answer exits 0. Returning from `main` ends the program even if other actors
  are alive.
- **[is] Operators are not user-definable.** `(op)` is a name only in
  definition and signature position. A user function is written infix with
  backticks.

## 3. Expressions

Precedence, loosest first:

| Level | Operators | Associates |
|---|---|---|
| 0 | `fn x y -> block` | extends as far as it can |
| 1 | `$` | right |
| 2 | `\|>`  `\|>?`  `>>` | left |
| 3 | `or` | left |
| 4 | `and` | left |
| 5 | `==  !=  <  <=  >  >=` | none in effect (`1 < 2 < 3` is a type error) |
| 6 | `::` | right |
| 7 | `+  -` | left |
| 8 | `*  /  %` | left |
| 9 | `^` | right |
| 10 | `!` (index) | left |
| 11 | `` `f` `` | left |
| 12 | application | left |

- **[is]** `not` is a function. There is no `&&` or `||`.
- **[is] `if c then a else b`** is `case c of True -> a | False -> b`.
- **[is] `case e of p -> block | p -> block`.** Arms take no guards; guards
  exist on clauses only. An unparenthesised `case` inside an arm takes the
  arms that follow it.
- **[is] `fn x y -> block`.** Parameters are plain lowercase names.
- **[decide] `fn` refuses `_` and patterns** (`fn k _ -> k` is a parse error).
  Listed as a porting cost in the [Sol review](2026-11-26-SOL-SCRIPTING-REVIEW.md).
- **[is] A block** is `stmt; stmt; expr`. A statement binds: `name = e;`,
  `name params = e;` (a local function), or `pattern = e;`. A bare `e;` is a
  parse error; write `_ = e;`. Blocks appear in clause bodies, case arms, `if`
  branches and lambda bodies, not inside parentheses.
- **[is] Records:** `{a = 1, b = 2}`; update `{r | b = 2, p.q = 9}`; access
  `r.b.c`. **Lists:** `[a, b]`, `h :: t`. **Tuples:** `(a, b, …)` of any width.
- **[is] `spawn`, `send`, `receive`, `print` are functions**, not syntax.

## 4. Evaluation

- **[is] Strict.** Every argument is evaluated before the call, used or not.
  A partial application evaluates the arguments it is given at once. A lambda
  body runs when the lambda is called.
- **[is] Left to right:** the function position, then the arguments in order;
  the operands of a binary operator; the elements of a list or tuple; the
  segments of an interpolated string.
- **[is] `and` and `or` short-circuit.** `a >> b` evaluates `a` then `b` and
  answers `b`. `a |>? f` is `case a of Ok v -> f v | Err e -> Err e`.
- **[is] A block runs its statements in order.**
- **[decide] Record fields are evaluated in field-name order, not source
  order.** `{b = f 1, a = g 2}` runs `g` first, because the desugarer sorts
  the fields. The same holds for the new values of a record update (after the
  base record). Either make it source order or state it; it is observable
  only when the field expressions have effects.
- **[decide] `a |> f` evaluates `f` before `a`**, since it is `f a`. A reader
  expects the left operand first.
- **[is] A nullary definition is evaluated at every reference.**
  `x = expr.` is a function of no arguments: naming `x` runs `expr`, each
  time, and nothing runs at program start. A definition whose body is an
  integer literal is replaced by the literal at its references
  ([nullary literal fold](2026-11-26-NULLARY-LITERAL-FOLD.md)); that cannot be
  observed.
- **[decide] Whether 1.0-rel keeps evaluate-at-each-reference.** It is the
  rule three implementation pages assume and no language page states. It
  surprises (a top-level table is rebuilt on every use, noted as a Sol porting
  cost) and the alternative, evaluate once, needs an initialisation order and
  a rule for effects. Core spec Q3 (the effect bit) is the natural place to
  split it: a pure nullary definition may be evaluated once.
- **[is] Arithmetic** is as core spec §1: `Int` is exact; `/` and `%` are
  floored (`-7 / 2 = -4`, `-7 % 2 = 1`, `7 % -2 = -1`); a zero divisor traps.

## 5. Values: text, equality, order

### Text

- **[is] A `String` is a sequence of bytes.** Lengths and positions count
  bytes, positions start at 0, slices are half-open. `strlen "é"` is 2.
  `charAt s i` answers the byte and traps out of range. `substr s off len`
  clamps. `chr n` makes one byte and traps outside 0..255.
- **[decide] D10 says `String` is valid UTF-8; nothing enforces it.**
  `chr 233` is a one-byte string that is not UTF-8. `String.fromCodes` and
  `String.codes` work on bytes, although their names and one runtime message
  say code points. Sol counts code points. This is core spec §4's open
  `String`/`Bytes` row; the rule for 1.0-rel has to say which operations
  count bytes and which code points, and where validity is checked.
- **[is] Interpolation** `"{e}"` renders `e` with the value printer:
  `True`; `[1, 2]`; `(1, a)`; `{a = 1, b = x}`; `B q 2`; `Some (Some x)`;
  `A (-1)`. Strings inside a structure are printed without quotes or escapes.
  A function prints as `<fn>`, an actor handle or `Vector` as `<type.id>`.
  `F64` prints up to 15 significant digits (`2.0` prints `2`).
- **[decide] The printed form is not a contract today** and cannot be read
  back (`[a, b]` may be two strings or one). 1.0-rel should say whether
  `print` output is stable, and name a round-trip form if one is wanted.
- **[is] Limits.** Printing a structure that holds a float is refused at
  compile time (format the float with `F64.str`). A rendering longer than
  4096 bytes traps.

### Equality

- **[is] `==` and `!=` are structural.** `Int` by value (small or big),
  `String` by bytes, tuples, records, lists and constructors field by field
  to any depth. Two values of different constructors are unequal.
- **[is] Identity types.** A function, an actor handle, a `Vector`, a device
  or a register is equal only to itself. `f == g` is false for two functions
  with the same body.
- **[is] Floats follow IEEE:** `nan == nan` is false, `-0.0 == 0.0` is true.
  A float field declared in a nominal type compares the same way.
- **[defect] `==` on a structure that holds a float crashes.**
  `(1, 1.5) == (1, 1.5)`, the same for a list or a record, and a polymorphic
  `eq : a -> a -> Bool` applied at `F64`, all end the process with exit 139
  and no message (macOS arm64). Printing the same shapes is refused at compile
  time; `==` is not.
- **[decide] `==` on functions** compiles and answers identity. Refusing it
  at compile time is the alternative.
- **[is] A hash map is not canonical under `==`;** use `HashMap.equal`.

### Order

- **[is] `<  <=  >  >=` are defined for `Int` and the float widths only.**
  Strings, tuples and `Bool` are a type error.
- **[is] Ordering other types** uses `std/order`: comparators are plain
  functions answering `Less | Equal | Greater`; `Order.string` is bytewise
  and a prefix sorts first. There is no type class.
- **[decide] `<=` on strings** is refused; the Sol review asks for it.
- **[is] Hashing** is `strHash` and `intHash`, deterministic and unseeded.
  There is no generic hash; mutable and fixed maps take `Int` or `String`
  keys.

## 6. Patterns and definitions

- **[is] Patterns:** `_`, a variable, a non-negative integer literal, a
  string literal, `Con p*`, `(p, q)`, `[p, q]`, `p :: q`, `{f, g}` (binds the
  named fields; cannot fail), `(s : SigName)`. No negative literal, float,
  as-pattern, or pattern nested inside a record pattern.
- **[is] Clauses are tried in source order; the first match wins.** Guards
  are tried left to right; a guard is a Boolean expression or `pat <- e`,
  which binds for the later guards and the body. A failed guard falls through
  to the next clause.
- **[is] Coverage is checked at compile time and is an error.** A `case` that
  does not cover its type is refused; integer and string arms need a
  catch-all; an arm that cannot be reached is refused. The clauses of a
  function must cover their arguments; a guarded clause never counts as
  covering, so a function needs an unguarded last clause.
- **[decide] A refutable pattern in a block is not checked.**
  `h :: t = xs;` compiles and traps at run time when `xs` is empty. Either
  check it like `case` or require a pattern that cannot fail there.
- **[is] Local definitions** capture the names in scope when they are made.
- **[decide] Shadowing is silent,** for a local, a parameter and a top-level
  name alike (Sol warns on shadowed prelude names since `1b1072b2`).
- **[is] Recursion must be accounted for.** Every function in a recursive
  group needs a verified `measure`, or an `unsafe` signature, or the file is
  marked `unsafe program.`/`unsafe module.`. A missing marker is a compile
  error; a caller of a marked function needs the marker too, unless the
  callee is in the prelude or an approved library. A measure is verified
  structurally (a strict subterm) or linearly (a decrease of at least 1 with
  a floor of 0); a measure that cannot be verified is an error.
- **[defect] Local recursion escapes the rule.** A recursive function defined
  inside a block compiles with no marker, and `fpr stdcheck` accepts it. The
  safety graph covers top-level names only.
- **[decide] Two checkers, two rules.** An ordinary compile accepts an
  `unsafe`-marked recursion; `fpr stdcheck` refuses any recursion without a
  verified measure and treats a name containing "unsafe" as the marker.
  1.0-rel needs one definition of "safe" (core spec §2 layers depend on it).

## 7. Failure

- **[is] A trap ends the actor it happens in, with a reason.** In the main
  actor the program prints `[ERR] reason` and
  `*** FPRISC PANIC [actor 0]: reason ***` on standard error and exits 1;
  output already printed stays. In a spawned actor it prints
  `[ERR] actor failed: reason`, the actor ends, anyone waiting on it gets
  `Err "dead actor: reason"`, and the program goes on.
- **[is] A broken runtime invariant ends the whole program** from any actor
  (for example receiving on another actor's handle).
- **[is] What traps:** a zero divisor; `error "msg"`; a failed precondition;
  an index out of range (`!`, `charAt`, `Vec.get`); `chr` outside a byte; a
  float that does not fit an `Int`; a typed hole; a refutable block pattern
  that does not match; the stack reaching its ceiling (1 GiB); the heap
  exhausted; a render over 4096 bytes. A non-exhaustive match is not among
  them: it does not compile.
- **[is] Exhaustion** ends a confined process with a budget reason, panics in
  the main actor, and fails any other actor.
- **[decide] Preconditions: three answers exist.** The core spec gives `/`,
  `%`, shifts and indexing a precondition and stops. [Failure modes](2026-11-10-FAILURE-MODES.md)
  says an obligation lifts to the caller's signature, a program is refused
  where lifting stops, a decidably false one is refused, and no run-time
  check is ever inserted. The compiler does none of the lifting: each
  obligation is discharged, or becomes a run-time check that traps at the
  call site with the caller named, or (for a divisor) is left to the
  division trap. `1 / 0` compiles and traps. This decision changes whether a
  trap is reachable from checked code and whether the check's cost is in a
  bound, so it gates the layer rules.
- **[is] Cleanup when an actor ends:** its received messages are released and
  its mailbox is drained.
- **[decide] Resources are not cleaned up.** A `Handle` is an `Int` with no
  finaliser, so a file or socket owned by an actor that traps stays open. A
  path that ends in `error` owes nothing to the linearity check. 1.0-rel
  needs a rule for linear values on failure (the reflections page asks the
  same).
- **[decide] Diagnostics go to two places:** type errors to standard error,
  parse errors to standard output. Both exit 1.

## 8. Effects and trust

- **[is] Types carry no effect.** `print`, `send`, `receive` and file
  operations are ordinary functions; a function's type does not say whether
  it has effects. Core spec Q3 decides an effect bit; it is not designed.
- **[is] One purity check exists:** the `view` of a `std/game` app may not
  reach a listed effectful primitive or foreign name. The list in
  `Compiler/Compile/Support.hs` is the only enumeration of effectful
  primitives, and it omits `heapUsed`, `Sys.memStats`, `Sys.memInfo`,
  `Sys.arena`, `Sys.loop`, `drop`, `keep` and `arcLive`.
- **[is] `unsafe` means "the compiler cannot bound this recursion".** It says
  nothing about memory. `Mem.*`, `Addr.*` and `CPU.*` carry no marker.
- **[decide] The trust boundary.** 88 library files are approved by a list in
  the compiler, described there as transitional policy, not proof. Three
  hash-map primitives are usable by one std file only. 1.0-rel needs to name
  what is trusted, by whom, and how a module enters or leaves the list.

## 9. Modules

- **[is] `A = use "spec".` resolves** `spec.fpr` relative to the importing
  file; then under the toolchain home (`FPR_HOME`, or the directory of the
  `fpr` binary); then under each `FPR_PATH` root. Cycles are refused.
- **[is] A pin `use "name#hash".`** accepts the file found that way only if
  its hash is the pin. Otherwise the committed copy
  `.fpr/store/<hash>.fpr` is used: looked up under the working directory,
  then the home and path roots. A missing or different module with no stored
  copy is an error.
- **[is] The hash** is 64 bits (FNV-1a, 16 hex digits) over the compiler's
  printout of the module's syntax tree with positions removed and each `use`
  replaced by the hash it resolved to. So it covers the module and everything
  it imports; comments and spacing do not change it.
- **[is] A module's identity is its hash.** A type is `T@hash`: two versions
  of a module can be linked into one program, and their values do not mix
  (`cannot unify T@… with T@…`). Two files with the same hash are the same
  module. A module alias used as a value is its hash as a `String`.
- **[is] `fpr commit file`** stores the source under its hash and records
  `name version hash`. The same hash is a no-op; a signature that only grows
  is a patch; anything else is a major version and needs `--major`.
  `fpr pin` writes pins into a file.
- **[decide] Is the hash an integrity guarantee?** It is not
  collision-resistant, and it changes whenever the compiler's syntax tree
  changes shape (one special case already exists to keep old pins valid).
  Freezing pins at 1.0-rel freezes that printout. Core spec Q10 says packages
  are "identified by hash" without choosing the hash.
- **[decide] The store is found from the working directory,** not from the
  project or the importing file.
- **[decide] Deprecated std names** are rewritten for an unpinned `use` only.

## 10. Actors, linear values, memory

### Actors

- **[is] An actor** is made by `spawn f`; `f` receives the actor's own handle.
  A handle has type `Int` but is not a number. `myself 0` is the main actor's
  handle. `kill a` ends an actor with the reason "killed".
- **[is] `send a m : Result Unit String`** copies `m` into the receiver's
  mailbox and never waits. It answers `Ok`, or `Err "mailbox full"`,
  `Err "dead actor"`, `Err "message too large"`. Library code compares those
  strings.
- **[is] Mailbox.** `spawn` gives each sender a ring of 64 messages; a full
  ring refuses. `spawnCap` chooses a fixed or growing ring; the size is
  rounded up to a power of two between 8 and 2^20.
- **[is] Order.** Messages from one sender arrive in the order sent. Across
  senders there is no order; `receive` takes from the senders' rings in turn.
- **[is] Receiving.** `receive me` waits for any sender. `receiveFrom me a`
  waits for one sender, forever if that sender ends. `receiveNow` answers
  `Err "empty"` at once. `receiveFromRes me a` answers `Err "dead actor"`
  (returned) or `Err "dead actor: why"` (failed or killed) when the sender
  has ended. `receiveUntil me t` and `receiveFromUntil me a t` take an
  absolute deadline in milliseconds and answer `None` / `Err "deadline"`.
  Receiving on a handle that is not the current actor's ends the program.
- **[is] A received message has no declared type;** it is whatever the
  receiver's code uses it as. Core spec Q4 (typed `Actor msg`) changes this
  and is not designed.
- **[is] Supervision** is a library (`std/supervisor`): one monitor per child
  waits on it, restarts by strategy, and fails itself past a restart budget.
  `std/actor` adds request and reply with deadlines.
- **[decide]** which of these are the 1.0-rel contract: the ring size and the
  error strings; fairness across senders; whether `receiveFrom` on a dead
  sender should fail instead of waiting; what Sol does (its mailboxes are
  unbounded, against core spec Q6).
- **[decide] The 0.15.0 release page names `Sys.waitInbox` and
  `Sys.receiveUntil`;** neither exists in this repository (the primitives are
  `receiveUntil`/`receiveFromUntil`; `Sys.waitInbox` is used by QOS). The
  v1.0 pages name `sendFrozen`; the code has `sendArc` only.

### Linear values

- **[is] A type declared `T 1` is linear:** a value of it is used exactly
  once on every path. Zero uses, two uses, discarding with `_`, and branches
  that disagree are compile errors. A function that captures one is itself
  used once. Operations hand the value back
  (`Vec.len : Vector a -> (Int, Vector a)`).
- **[is] `sendLinear`** moves a value to another actor without copying when
  it can, and consumes it in every case, including a refused send.
- **[defect] Four ways to lose a linear value legally:** `print "{v}"` or
  `str v`, `drop v`, and `send a v` each count as the one use and free
  nothing; a path ending in `error` owes nothing.

### Memory

- **[is] A program can read memory use:** `heapUsed` answers the bytes the
  current actor has taken, and `Sys.memInfo`, `Sys.memStats`, `Sys.stkStats`
  answer more. Their values depend on where the compiler placed regions.
- **[decide] "Memory is unobservable"** (core spec §2.1, ARC amendment) is
  therefore not true of the language as it is. Either those primitives leave
  the checked language (as `arcLive` does) or the claim is narrowed to "no
  program's result depends on it unless it asks".
- **[is] A received message lives until the end of the turn that received
  it:** a `Sys.loop`/`Sys.loopWith` step, the compiler-recognised receive
  loop, the end of a `Sys.arena`, `Sys.poolReset`, the actor's body
  returning, or its death.
- **[decide] "Turn" is defined by what the compiler recognises.** A
  hand-written receive loop it does not recognise holds every message until
  the actor ends. The ARC amendment rests the message-lifetime guarantee on
  "the turn boundary" without defining it.

---

## 11. Where the alpha 2 contract (SEMANTICS.md) is wrong today

| SEMANTICS.md says | Today |
|---|---|
| Reserved words include `unsafe`, `measure`; `if then else` not listed | §1 |
| Operators `&&`, `\|\|` | `and`, `or` only |
| "Precedence table: (write it down)" | §3 |
| "Overflow wraps silently today" | `Int` is exact |
| Strings: "(decide) bytes or code points"; "String indexing is one-based" | Bytes, zero-based (§5) |
| "Tuples up to 8" | Any width |
| `==` "gives up at depth 64 and answers equal" | No depth limit |
| A top-level block is a parse error | Only the parenthesised form is |
| `fpr.lock` is the tree's pin set; "the project's store" | No `fpr.lock` in the compiler; the store is under the working directory |
| `use` tries the importer's own suffix first | Only `.fpr` is tried by the native resolver |

Still right there, and restated above: definitions end with `.`; strict,
left to right; every block statement binds; clause groups and first match;
case coverage; `if` as sugar; float suffixes; record update; linear values
used once per path; `unsafe` and `measure`; pins.

## 12. What to do with this page

1. **Fix the defects** (they need no decision): `==` on structures holding
   floats; names beginning with `case`/`of`/`Type`; local recursion escaping
   the safety rule; the four linear leaks.
2. **Decide the [decide] clauses.** In order of how much rests on them:
   preconditions (§7); evaluation of nullary definitions (§4); `String`
   bytes or code points (§5); the meaning of "safe" and the trust list (§6,
   §8); the mailbox and ordering contract (§10); module hash and store (§9);
   then the smaller surface items.
3. **Turn each accepted [is] clause into a conformance case** and run it on
   every target and on Sol; that is stage 0 of the core spec, and it is what
   will show where Sol and the other targets differ from this page.

Not covered yet: the type system (rows, refinements, `Sig`/`Struct`
conformance, generalisation), resource bounds and cost, the per-profile
restrictions, device and foreign code, Sol's transactions, targets and ABI,
and the toolchain commands.

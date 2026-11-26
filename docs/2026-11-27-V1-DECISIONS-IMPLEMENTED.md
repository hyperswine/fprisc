# v1.0: four owner decisions implemented (27 November)

Kind: owner decisions (26 Nov 2026) and their delivery record. Branch
`sol-progressive`. Each one settles a clause of the
[v1.0 semantics draft](2026-11-26-V1-SEMANTICS.md) that was marked [decide] or
[defect].

| Question | Decision | Done |
|---|---|---|
| `==` on a structure holding a float (§5, a crash) | refuse at a concrete type | yes |
| `<=` on strings, guards on local functions, `fn _ ->` (§3, §5) | allow, unless costly to implement | strings and `fn _` yes; local guards skipped |
| Values between Sol statements | allow, with discipline | yes ([statement results](2026-11-27-SOL-STATEMENT-RESULTS.md)) |
| The four linear leaks (§10) | the recommended option for each | yes |

## 1. `==` at a known type that holds a float is refused

`Infer.hs` resolves `==` and `!=` the way it already resolved printing. At a
concrete type that holds a float outside a field its nominal type declares
`F64`/`F32`, they are refused:

```text
(==) on {a : F64, b : Int}: structural equality is tid-directed and floats are
raw bits -- compare the float fields individually with F64.==/F32.== (v1)
```

- A nominal type's own float fields still compare by IEEE value
  (`P 1.5 2 == P 1.5 2`).
- Sol uses the same inference engine, so the rule is the same there, although
  Sol's VM could compare floats: one meaning in both (core spec Q6).
- **Still open:** a polymorphic `==` instantiated at a float-holding type cannot
  be refused where it is defined, and it still crashes. That is
  `conformance:eq-float-polymorphic`, a recorded known failure. The fix would be
  the "constrain the type variable" option that was not chosen.

## 2. Strings, lambdas, local guards

- **`<  <=  >  >=` on `String`:** byte order, the order of `std/order`'s
  `Order.string`. A prefix sorts first, and `"Z" < "a"`. They are members of the
  `Str` struct in both preludes (`core/prelude.fpr`, `Sol.Preamble`), defined by
  `strCompare`, and the resolver sends the operators there, as it does `+`.
  Native and Sol answer the same.
- **`fn _ ->`:** a lambda parameter may be `_`. It becomes a fresh name the body
  cannot refer to (`Frontend/Parser.hs`, `lamParam`). Native and Sol.
- **Guards on local functions: skipped.** A local function is a single clause
  today. Guards imply several clauses that fall through to each other, which
  would mean adding local clause groups to the language rather than relaxing the
  parser. Write a local `if`/`case`, or a top-level function.

## 3. The linear leaks

Each leak counted as a linear value's one use while releasing nothing. All are
in the linearity checker (`Frontend/Linearity.hs`):

| Leak | Now |
|---|---|
| rendering: `"{v}"`, `str v`, `print v` | refused; give the type a `show` that hands the value back, `(String, T)` |
| `drop v` | refused; use the type's own consumer (`Vec.free`, `close`, `BStr.free`, ...) |
| `send a v` | refused; move it with `sendLinear` |
| a path ending in `error` | accepted; a trap ends the actor and the runtime frees its memory |

- **Type variables:** the refusals go through `demandOwnership`, so a type
  variable that reaches rendering, `drop` or `send` must be instantiated at an
  unrestricted type. A polymorphic wrapper cannot launder an owner past them:
  `sh x = "{x}"` applied to a linear value is refused.
- **Unchanged:** `drop` of a received message, the common case in std, is
  unrestricted and unaffected.
- **Still open:** OS resources (files, sockets) held by an actor that traps. That
  is the semantics page's "resources are not cleaned up" clause.

## Conformance cases added

`eq-float-structure` (refused), `eq-float-nominal`, `eq-float-polymorphic`
(known failure), `string-order`, `lambda-wildcard`, and `lin-render`, `lin-str`,
`lin-drop`, `lin-send` (all refused).

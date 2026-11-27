# Polymorphic `==` at a float is refused at the call (27 November)

Kind: delivery record. Branch `eq-float-poly`. It closes the open case of
[V1-DECISIONS-IMPLEMENTED](2026-11-27-V1-DECISIONS-IMPLEMENTED.md) §1 and
removes the known failure `conformance:eq-float-polymorphic`.

## The rule

The owner chose (27 November) to refuse the call. A polymorphic `==` reached
with a float-holding type is refused at the call that fixes the type, with the
message `==` at that type gets when written directly:

```
eq : a -> a -> Bool.
eq x y = x == y.
main = print "{eq (1, 1.5) (1, 1.5)}".
```
```
in main: (==) in eq reaches (Int, F64) here: structural equality is
tid-directed and floats are raw bits -- compare the float fields individually
with F64.==/F32.== (v1)
```

- **Float-holding** means the same as in the 26 November rule: a float outside
  a field its nominal type declares `F64`/`F32`. A bare `F64` counts too:
  `eq 1.5 1.5` crashed the same way (exit 139).
- **The requirement passes through callers.** `same p q = eq p q` called with
  `(Int, F64)` is refused at that call.
- **No signature changes.** Calls at `Int`, `String`, lists, tuples and records
  without floats compile as before.
- **Sol is unaffected.** Sol's checker gives inexact numbers the `Int` type, so
  neither this rule nor the 26 November one applies there, and its VM compares
  floats by value.

## How

In `compiler/Infer.hs`:
- `resolveSites` records each `==`/`!=` site whose operand type still holds
  type variables, with its owner definition.
- Inference records every instantiation of a global, with its owner and
  source position.
- `checkEqInstances` runs after the sites are resolved:
  - it finds where those variables sit in the owner's body type (`iDefTypes`);
  - it reads each call's instantiated type at those places;
  - a float-holding type there is reported at the call;
  - another type variable there becomes a requirement on the caller, until
    nothing new appears.

Not covered: a local polymorphic function's requirement is not passed through
its own name. Only top-level definitions carry it.

## Checks

- `eq-float-polymorphic` is now a `.refused` conformance case.
- `fpr check` over the 204 files in `examples/`, `std/` and `tests/` finds no
  new refusal.
- Sol check suite: 38 run, none unexpected, and no known failures left. All 50 unit suites pass.

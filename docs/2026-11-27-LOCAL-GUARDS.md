# Guards on local functions (27 November)

Kind: delivery record. Branch `local-guards`. Item 2 of the owner's v1.0
answers of 26 November ("allow them if they won't be too problematic"),
recorded as skipped in [V1-DECISIONS-IMPLEMENTED](2026-11-27-V1-DECISIONS-IMPLEMENTED.md) §2.

## The rule

A local function may have guarded clauses, written as top-level clauses are:

```
describe n =
  sign x | x > 0 = "positive";
  sign x | x < 0 = "negative";
  sign y = "zero";
  "{sign n}".
```

- **A group** starts at a guarded clause. It takes the following clauses of
  the same name, up to and including the first unguarded one, which is the
  fallback. Clauses are tried in order.
- **Guards are top-level guards:** conditions, and pattern guards
  (`O.Some x <- v`), separated by commas.
- **Parameter names** may differ between clauses, but the number of
  parameters may not (a compile error).
- **Without a fallback**, a call where no guard holds traps with "no clause of
  local function NAME holds".
- **An unguarded binding is unchanged.** `x = 1; x = x + 1;` is still
  shadowing, not a group.
- **The meaning is the same natively and in Sol,** since the same parser
  serves both.

## Why it was simple after all

The skip assumed local clause groups were new language. They are not needed.
Local function parameters are names, so a clause can fail only by its guards,
and a group becomes one ordinary local function in the parser
(`Frontend/Parser.hs`, `localClauses`):
- the first clause's parameters;
- each clause's guards as a chain of choices falling through to the next
  clause;
- a clause that names its parameters differently rebinding them.

When a clause has several guard items, the rest of the group is bound once as
a local function, so the code grows linearly with the clauses. Inference,
safety, linearity and both back ends see only constructs they already handle.

## Checks

- New conformance case `local-guards`:
  - guards and fallbacks, and multi-item guards;
  - a pattern guard;
  - renamed parameters;
  - shadowing still a binding;
  - a group with no fallback.

  Native and Sol print the same.
- Sol check suite: 38 run, none unexpected (conformance 14 cases). All 50 unit
  suites pass.

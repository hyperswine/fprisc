# Record update on an owned record

Date: 2026-11-10. Kind: a checker change, tested. Branch `linear-record-update`
on `5592869`.

## The problem

A record holding a linear value could not be updated in the ordinary way:

```fpr
Token 1 = Type (Token Int).
St = { tok : Token, n : Int }.
bump : St -> St.
bump s = {s | n = s.n + 1}.
```

was refused twice: "record projection discards linear field(s) ["tok"]" for
`s.n`, and "linear variable 's' used 2 time(s)". The update itself was already
right: `SUpd` moves the untouched fields into the new record. The refusal came
from reading `s.n` inside it, which counted as a second, separate use of `s`.
This was the first blocker found when looking at putting QOS endpoint handles
into state records (QOS `docs/2026-11-10-*`, the linear types survey).

## The rule

`{s | path = e, ...}` on an owned `s` consumes `s` once. Reads of `s`'s own fields
in the new values belong to that one consumption. It is the same as writing
`{tok, n} = s; {tok = tok, n = n + 1}`: destructure and rebuild, nothing borrowed.

- An unrestricted field read (`s.n`) is a copy and is always allowed.
- An owned field read (`s.tok`) takes the field out of `s`. The same update must
  replace that field, or a record that holds it (`{s | tok = f s.tok}`,
  `{s | inner = g s.inner.tok}` is refused, `{s | inner.tok = ...}` with
  `s.inner.tok` read is fine). Otherwise the new record would hold it too.
- Taking an owned field twice, or taking a record and a field inside it, is
  refused.
- Using the whole `s` again in a new value (`{s | n = weigh s}`) is still two
  uses of `s`.
- A name that shadows `s` inside a new value (`fn s -> s.n`) is not `s`.
- A projection outside an update is unchanged: `s.n` alone still refuses the
  owners it leaves behind (`record-metadata-loses-owner`).

Implementation: `compiler/Frontend/Linearity.hs`, `updateOwned`. When the base of
an update is a variable with an owned shape, each `s.path` in the new values is
rewritten to a take variable for `path` (scope-aware, through `transformE`), and
the existing counting checks each one. Owned takes are cleared from the base
shape before `updateOwnership` applies the replacements, so replacing a taken
field is not reported as discarding it. Native and Sol share this checker.

## Tests

- `tests/check_structural_ownership.py`: 10 new cases, 5 refusals (take not
  replaced, take twice, whole base in a value, nested take not replaced, take
  wider than the replaced path) and 5 programs built natively and run in both
  frontends with the same output (metadata read as in MVU `update`, reads in
  both branches of an `if`, replacing a taken owner, a nested take and replace,
  a shadowed base). 39 cases pass.
- Unchanged and passing: `tools/audit_linear_ownership.py` (0 accepted),
  `check_callable_ownership.py` (34), `check_generic_ownership.py` (42),
  `check_owned_products.py`, `check_linear_strings.py`,
  `check_printer_ownership.py`, `check_owned_watchers.py`,
  `check_higher_order_contracts.py`, `check_consuming_reuse.py`,
  `make unit-tests UNIT=Diagnostics`.
- All 643 tracked `.fpr` files through `fprc --check-only`, branch against the
  main checkout's binary: no file newly fails and no linearity verdict changes.
  The baseline binary predates `5592869` (built 14:44, commit 16:24), and 29 std
  files it fails on an unrelated unsafe-signature check pass on the branch.
  None of them involves linearity.
- Not run: the full `check_base` job list and QOS check-all.

## What this does not unlock

Hosted MVU apps still cannot keep an owner in their model. The runtime
(QOS `std/hosted`, `step`) passes the model to `view` and `subs` and also keeps it,
so its `model` type variable must be unrestricted. A linear endpoint in a hosted
app's model is refused there, whatever record updates allow. This change helps
code that threads owned state through records itself (actor loops, service state
such as QOS `system.fpr`'s capabilities). For hosted apps the value-semantics
answer is that a service owns the resource and the model holds plain data.

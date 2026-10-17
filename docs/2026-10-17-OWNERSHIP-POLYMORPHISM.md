# Ownership through polymorphic functions and generic containers

Date: 2026-10-17. Kind: implementation record. Applies from revision
`ee84d90` plus this change, on top of the uncommitted
[ownership corrections](2026-10-17-OWNERSHIP-CORRECTIONS.md) batch. Closes
items 1 and 2 of that page's "next compiler work": the polymorphic and
generic-container rows of the [ownership audit](2026-10-17-LINEAR-OWNERSHIP-GAPS.md),
including the generic buffer duplication example that still compiled.

## The rule

A type variable in a signature is a value whose ownership is decided by
each call. Inside the function it is **possibly owned**:

- used exactly once, it moves, and the function is *ownership-preserving*
  in that variable: `identity : a -> a` hands back what it was given;
- used more than once or not at all, the function *requires the variable
  to be unrestricted*. The body is not refused; the requirement is recorded
  against the function, and every call that instantiates that variable
  with an owned value is refused:

      in main: 'duplicate' duplicates or discards its argument of type `a`,
      so it cannot take an owned value there

Ordinary code is unchanged: `duplicate 21` is legal, `List.repeat 2 1` is
legal. What is new is that `duplicate owner`, `List.repeat 2 owner`,
`Option.withDefault owner None` and `List.length [owner]` are refused. The
last one is the honest answer absent borrowing: a list of owners passed to
`length` is consumed, and `length` does not consume its elements.

A generic type keeps its arguments' ownership. `Box Token` is a Box whose
payload is owned, so `Box x` binds `x` owned and `Box _` discards an owner;
`Result Token String`, `List Token` and a user `Pair a b` behave the same,
whether the type is declared or inferred.

## How it is implemented

All of it is in the pre-desugar linearity checker (`compiler/FPRISC.hs`)
and the inferred-shape bridge (`compiler/Infer.hs`).

**Shapes.** `LShape` gains `LVar a` (a type variable) and
`LCon T own [shapes]` (a generic type applied to arguments with ownership;
`own` marks a linear-named type such as `Connection 1 s`, owned whatever
its arguments are but still instantiable). `shapeOfTy` and the inferred
`linShapeT` produce them; a linear-named type with no arguments stays `LL`.
`isLin` treats `LVar` as owned (symbolic); `hardLin` erases variables
first and says whether a shape is owned whatever they turn out to be.

**Instantiation.** A saturated call matches the callee's declared parameter
shapes against the actual argument shapes (`matchL`, `bindingsL`) and
substitutes into the result (`substL`); unbound variables are
unrestricted. Constructor applications do the same over the type's
parameters, and constructor patterns instantiate their fields from the
scrutinee (`conFields`): a scrutinee that is owned but structureless (a
plain `LL` reached by a join) owns every generic field, conservatively.
The prelude's `Ok`, `Err`, `Cons` and `Nil` are in the constructor table
as generic constructors of `Result` and `List`.

**Constraints.** Every place the checker demands exact use of an owned
value goes through `demandL`: a sure owner is an error as before; a
possible owner (a shape with type variables and no sure owner) becomes a
constraint marker on those variables instead. The clause checker collects
markers into `liUnres :: Map function [variable]`, and `lcheck` iterates
to a fixpoint, because a call that binds a callee's constrained variable to
the caller's own type variable propagates the requirement.

**Builtins.** A primitive has no body, so its variables stay unrestricted
(`eraseVars`): `print owner` consumes as before, and `keep` keeps its
deliberate-escape meaning. `sendLinear` keeps its explicit move shape.

## What it found in the tree

`VList.fold` and `VList.len` in `core/prelude.fpr` dropped the vector
handle the primitive hands back (`foldRes r = (x, _) = r; x`). Under the
old rule the tuple's type variables were unrestricted, so the drop passed;
under the new one the helper requires its second variable unrestricted and
the call with a `Vector` is refused. Both now return `(result, vector)`,
as the comment above them already claimed, and `tests/typed.fpr` frees the
vector it gets back.

The first version of this change collapsed every linear-named type to `LL`,
arguments included. `std/ownedtransport` (`Connection 1 s`) then refused
its own `readSome`: a pattern on the owner could not instantiate `s`, took
the field as owned, and the transport mechanism's helpers, which read their
state more than once, may not take an owner. Keeping the arguments on an
owned type (`LCon T True`) fixed it and `tests/check_printer_ownership.py`
passes; the generic suite has a case for it.

Nothing else in std, the examples, the ideal programs, the Sol examples or
the WASM VM changed meaning: all of them compile and pass unchanged.

## Checked

- `tools/audit_linear_ownership.py`: 19 accepted invalid probes before the
  corrections batch, 11 after it, **5 now**
  ([evidence](evidence/2026-10-17-linear-ownership-after-generics.json)):
  `higher_order_twice`, `closure_return`, `aliased_pap`, `dynamic_pap`
  (callable capture and call multiplicity, item 3 of the corrections page)
  and `keep_escape` (deliberate). Every polymorphic, container, record,
  guard and inference probe is refused by both frontends. The audit still
  exits 1 while item 3 is open.
- `tests/check_generic_ownership.py` (new, in `check_base`): 16 refusals
  and 10 executed legal programs, native and Sol, including std's
  `List.map`/`fold`/`reverse`, `Option.map`, `Result.map` over owners
  and the same helpers' duplicating siblings refused on owners.
- `tests/check_structural_ownership.py` 29, `tools/sol-linearity-check.py`
  8, `tests/check_cases.py`, `examples/ideal/check.py`, the Sol examples
  (21), the WASM suite (57 of 57), and check-only compilation of logbook,
  pos1, report, service, todo and wc: all pass.
- `tests/check_base.py` and the QOS smoke set: see the end of this page.

## Limits

- **No borrowing, by design.** A function that reads an owned argument
  without consuming it (`length`, `isEmpty`, a lookup that returns a copy
  of an Int field) refuses owned instantiations. Threading the value back
  out, or keeping the resource behind a service actor's address, is the
  way through; there will be no borrow form
  ([2026-10-17-VALUE-SEMANTICS.md](2026-10-17-VALUE-SEMANTICS.md)).
- **Callables are still unrestricted** (`TArrT`, `TFn` are `LU`): a
  callback that captured an owner can be called twice through a
  higher-order parameter, a returned closure, an alias or a dynamic partial
  application. Item 3.
- **Row variables.** `{tag : Int | r}` can still hide an owner in `r`; the
  open-row rules apply when the row is known owned.
- **Error names.** A refused std call names the callee with its content
  hash (`repeat@1c3c48ae...`), as the safety pass does.
- **Messages name a type variable** by its source name for a declared
  signature and by an inference number (`?2931`) for an inferred one.

## QOS under the new rule

Every QOS program and test kernel (`programs/*.fpr`, `apps/`, `tests/*.fpr`;
230 files) was check-only compiled for the Portable target with this
compiler. 139 are clean. 88 fail for reasons that are not ownership: library
units with no `main`, programs that need another build mode, and the type
and safety refusals they have on `main` already. Two are refused for
ownership, `apps/editor.fpr` and `tests/appsession.fpr`, both in
`programs/mods/editapp.fpr` (lines 63 and 111): `update` reads
`sized.running` from a model whose `proc` field is an owned `Proc`, and the
record rule of the corrections batch requires an owned record to be
destructured rather than read through. A compiler built with the
corrections batch and without this change refuses the same lines with the
same messages, so that finding belongs to the record rules, not to the
polymorphism rules; it is the value-semantics rule, met by a real program: the model holds a
process rather than a process actor's address
([2026-10-17-VALUE-SEMANTICS.md](2026-10-17-VALUE-SEMANTICS.md)). The QOS smoke set itself (`./qos.py test`) could not be run: at
this pair of revisions `qos/appside/entry.c` fails to compile against
`fprisc` main (`fpr_confined_refuse` undeclared), before any FP-RISC code
is reached.

`tests/check_base.py` passes in full with this change (144 legs, including
the printer ownership suite, the structural and generic ownership suites,
the I64 leg and the live-reload checks).

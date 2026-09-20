# The safe/unsafe line

Source style, including the builtin-first rule that normally avoids custom
recursive helpers in the first place, is defined in `STYLE.md`.

FP-RISC draws a compiler-enforced line through every program:

**Safe code** is code whose worst-case execution time the compiler can
see through: straight-line logic, guards, pattern matches, calls into
the standard library, and the library's *recursion schemes*
(`listFold`, `Std.fold`, `Vec.map/fold/filter`, ...) whose bounds are
the scheme's own.  Safe functions carry no annotation and need no
signature — bare is the preferred, default state.

**Unsafe code** is code with an opaque WCET:

* **implicit recursion** — a custom recursive function (self or
  mutual), as opposed to using a scheme;
* transitively, code that leans on such functions *outside* the
  vetted library.

## The rules (Safety.hs, always on; `--no-safety` is transition-only)

1. Every function in a recursive SCC MUST carry an explicit signature
   of the form `f : unsafe T1 -> T2 .`  Inference never hides
   recursion.  A missing marker is a compile error.
2. Calling a marked-unsafe function from an unmarked function is
   itself unsafe and requires a marker — UNLESS the callee is library
   code (the prelude, or any use-spliced module).  The library is the
   vetted set: its recursive internals are marked too (rule 1 applies
   to it — honesty), but *using* it is the sanctioned way to recurse,
   so the taint stops at the library boundary.  "Core functions
   rather than std functions" is exactly the taint this rule tracks.
3. A safe function marked unsafe is flagged the other way: drop the
   marker.  The set of `unsafe` signatures in a program is intended
   to be exactly its set of WCET-opaque functions — no more, no less.

## Adopting it

`FPR_UNSAFE_SUGGEST=1 fprc ...` prints paste-ready signatures with the
INFERRED types for every violation; `tools/unsafe-fixup.py <prog>`
applies them mechanically (module-spliced `name@hash` forms are routed
to their defining module file, hash-qualified type names stripped).

The better fix is usually not the marker but the refactor the rule is
pressuring you toward: `tests/matvec.fpr`'s reference loop and
`tests/opsugar.fpr`'s checksum both moved from custom recursion onto
fold schemes and dropped their markers; `tests/typed.fpr`'s
sig-generic `total` now composes the carrier with `listFold` — generic
AND safe.  What remains marked in this tree is exactly what should
be: device drivers' poll loops, actor receive loops, and the
library's own scheme implementations.

## Two more lines the compiler draws

Neither is about WCET, but both are the same idea: a definition may not
claim more than it delivers, and the claim is checked rather than believed.

**A function's CLAUSES must cover their arguments** (`Exhaust.checkClauses`).
`case` has been checked since the arm grammar made it necessary; clauses were
not, and a value matching none of them reached a runtime "no matching clause"
error instead of a compile error. The relation is the same usefulness test,
one column per parameter, and the message names the value nothing matches:

    in pick: the clauses are not exhaustive -- nothing matches `pick (C _)`

A **guarded** clause never counts as covering: its patterns can match and its
guard still pass the value on. So `k x | x > 0 = 1.` alone is refused, and
`k x | x > 0 = 1.` followed by `k x = 0.` is not. Int and String literals
never form a complete set, exactly as in a `case`, so clauses over them need
a catch-all.

**A declared signature must be earned** (`Infer.checkDeclared`). A signature
promises to work for every type the CALLER may choose, and it used to be
instantiated with ordinary inference variables -- which are happy to become
whatever the body needs. `f : a -> a.` with `f x = x + 1.` bound that `a` to
Int, reported nothing, and kept the declared scheme, so every caller was
typed against a promise the body does not keep. The definition is now matched
against RIGID constants instead:

    the declared type of f is more general than its definition: the signature
    promises a -> a, but the definition only gives Int -> Int

A signature NARROWER than the body would have inferred is still fine -- that
is what signatures are for. The check applies only to signatures actually
written: a top-level bind whose name happens to match a prelude builtin finds
a scheme there too, and holding it to a type nobody wrote would report a
signature that does not exist. Row variables are not yet checked (there is no
rigid row in the representation), so a row-polymorphic signature can still
over-promise; it can miss a lie, never invent one.

A wrongly-general signature is reported once per FUNCTION rather than once per
clause: every clause breaks it, and four copies bury the one fix.

## What turning them on found

Seven, across both trees, every one of them real:

| where | what it claimed |
| --- | --- |
| `std/term.fpr` `loop`, `feed` | the app as a bare `a`, then projected `.update`, `.subs`, `.view` out of it |
| `std/mvu.fpr` `renderWorker` | `vl` as a bare `b`, then applied it to four arguments |
| `qos` `mods/timer.fpr` `sleeper` | a `send` result -- always a `Result` -- as `a` |
| `qos` `tests/growlog.fpr` `lgNth`, `lgLen` | `a` for something they walk as a `List String` |
| `std/view.fpr` `attrOf` | no `Local` clause; total only because its one caller filters it out |
| `tests/split.fpr` `g` | a single `g 1` clause |
| `qos` `mods/arcsvc.fpr` `arcStep` | Int op codes 1/2/3 with no fallback |

The last is the one to take seriously: an unknown op code would have fallen
through to a runtime error that takes the whole service down with it. A
dispatcher over Int literals can never be complete, so a service's refusal has
to be part of its protocol -- it now answers `(0, 1)`, using the status slot
the three known ops always send as `0`.

What is NOT flagged is as telling: an actor loop declared `-> a` that never
returns keeps its signature, because its result type really is unconstrained.

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

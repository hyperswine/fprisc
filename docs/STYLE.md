# FP-RISC and Sol style

This is the source style guide for shipped programs, modules, tests, and
examples. `SAFETY.md` defines the enforced safe/unsafe boundary; this guide
defines the preferred source shape inside that boundary.

## Builtin-first code

Use an existing builtin, operator, prelude function, or standard structure
method directly at the call site when it already expresses the operation.
Do not introduce a private function merely to rename it or reimplement it.

Prefer:

```fpr
n = List.len rows;
small = List.take rows 8;
hi = Int.max left right;
r = Int.mod index width;
joined = xs + ys;
```

over:

```fpr
len Nil = 0.
len (_ :: rest) = 1 + len rest.
takeN n xs = ...
maxI a b = case a > b of True -> a | False -> b.
imod a b = a - (a / b) * b.
append xs ys = ...
```

The same rule applies to exact forwarding wrappers:

```fpr
# Avoid when all callers can say Core.strEq directly.
strEq a b = Core.strEq a b.
```

Direct calls make the language's standard vocabulary visible, avoid needless
names and unsafe recursive signatures, and keep examples focused on the idea
they are demonstrating.

## When a function earns a name

Keep a function when its name carries domain meaning, centralizes policy,
adapts an interface, or is passed as a value. Typical examples are:

- `readLatest`, `manifestOf`, and `hasGrant`: domain operations or policy;
- `Vec.fold scoreRow 0 rows`: a named callback used as a value;
- `flipGet vec index = Vec.get index vec`: deliberate argument-order
  adaptation for partial application;
- compatibility wrappers that preserve an exported API during a staged
  migration.

A repeated expression alone is not automatically an abstraction. Name it
when callers benefit from the concept, not only because the expression is
shorter.

## Module boundary exception

Use only APIs visible in the current compilation unit. Separately compiled
FP-RISC modules cannot yet resolve every structure member injected by the root
prelude, including some `List.*` and `Int.*` methods. A local implementation or
an explicit shared-module dependency is acceptable there. Mark it as a module
boundary workaround when it would otherwise look like an accidental builtin
reimplementation; remove it when the compiler exports that standard surface.

Do not add a dependency solely to eliminate a two-line helper when it creates
a content-hash diamond, changes a shared ABI identity, or reverses the intended
dependency direction.

## Repository catalogue

This catalogue records the current audit of examples, tests, and shipped
programs. It is a review aid, not a rule to replace functions by name alone.

### Cleaned and verified

| Area | Direct operations now used |
| --- | --- |
| `sol/examples/bboard.sol` | `List.append`, `List.rev`, `Numeric.abs` |
| `sol/examples/dash.sol` | existing `base.pI` and `base.takeN` |
| `sol/examples/dtree.sol` | `List.append`, `Numeric.min`, `Numeric.mod` |
| `sol/examples/mandel.sol` | `Numeric.mod` |
| `sol/examples/prolog.sol` | `List.append`, `List.len` |
| `sol/examples/terra.sol` | `List.len` |
| `tests/dtree.fpr` | `Int.min`, `Int.max`, `Int.mod`, `List.len` |
| `tests/patguard.fpr` | `Int.mod` |
| `tests/pathnotes.fpr` | `List.take`; the safer call also removed stale `unsafe` annotations |
| `tests/paths.fpr`, `programs/maapp.fpr` | `List.len` |

### Keep for meaning or adaptation

- Parsing helpers such as the standalone examples' `pI` add an empty-input
   fallback. Use `base.pI` when `base` is already a dependency, but do not turn
   `Str.parse` into a silent fallback globally.
- Named fold callbacks such as `physics.fmax`, row scorers, counters, and
   accumulators are values passed to higher-order operations. Their names expose
   the fold's meaning even when their bodies are short.
- `tests/linpap.fpr`'s `flipGet` and `programs/voxel-interactive.fpr`'s
   `wGet`/`wSet` deliberately adapt argument order or one-based storage layout.
- Domain helpers such as `cartTotal`, `countOccs`, `readLatest`, and
   `manifestOf` describe application concepts rather than aliases for syntax.

### Current API or module gaps

- Sol exposes `List.rev`, but not `List.take` or `List.drop`. Recursive
   `takeN`/`dropN` in `sol/examples/mandel.sol` and bounded-history examples are
   therefore implementations, not redundant wrappers. Shared Sol code may use
   `sol/lib/base.sol`'s `takeN` when that dependency already fits.
- Root FP-RISC programs can use the full prelude `List.*` and `Int.*` surface.
   Separately compiled modules cannot reliably resolve all of it yet, so
   `programs/mods/coreutil.fpr` remains the shared compatibility surface for
   modules such as `qsys`, `qlog`, `persist`, and `genview`.
- Root FP-RISC has `List.take` and `List.drop`, but no `List.rev`; accumulator
   reversals such as `tests/pathnotes.fpr`'s `revL` remain necessary.

### Follow-up migrations

- `programs/voxel-interactive.fpr`: replace arithmetic aliases `imod`, `minI`,
   `maxI`, and `absI` with `Int.*`, and remove its unused local `len`. This is a
   large interactive program and should be migrated with its live build/run
   checks as a separate change.
- `programs/system.fpr`: review root-level `append`, `takeN`, `dropN`, `minI`,
   and `maxI` against prelude operations. Keep similarly named functions in
   separately compiled modules until their imports expose the required methods.

When this catalogue changes, validate each edited example or test through its
normal compiler or `qos.py run` harness. A source-level equivalence is not
enough if safety inference, linear ownership, or a module interface changes.

## Review checklist

Before adding a private function:

1. Check the builtin environment, prelude, and imported standard modules.
2. Use the standard operation directly if it preserves semantics and is
   visible in this compilation unit.
3. If retaining a function, make sure its name communicates domain meaning,
   policy, adaptation, callback identity, or compatibility.
4. Prefer vetted folds, maps, filters, generators, and list operations over
   custom recursion. See `SAFETY.md` for the enforced recursion rules.
5. In examples, optimize for teaching the language surface: avoid scaffolding
   that obscures the feature being demonstrated.

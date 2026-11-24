# Used definitions of imported units (25 November 2026)

**Decision (Jack, 25 Nov):** the compiler emits only the definitions of imported std (and user) modules that the program uses.

## Why
Each imported module is a separately emitted, cached unit, and until now every unit was emitted whole. The stdlib consolidation (c90d7560, 82fa28fe, 645c4584) merged small modules into large ones, so `pos1` and the `std-live` probe started compiling definitions they never call. On CI (ghc-9.6.6) pos1's compile allocation went from 82.77 G at 151b3eeb to 89.33 G, and std-live's from 40.25 G to 43.49 G, both over the 10% compile budget (fprisc #118 has the attribution).

## What is pruned, and what is not
- **Pruned:** native emission only (`Compiler.Compile.Emit`): the set of definitions each dependency artifact contributes to linking, optimization, regions and code generation.
- **Not pruned:** parsing, loading, struct expansion, preconditions, type checking, linearity, safety, `measure` checks, resource/cost bounds and `fpr stdcheck` all still see the whole merged program. A definition that is not emitted is still checked, so proofs, WCET and fuel stay sound, and an error in an unused std definition is still reported.
- **Unchanged builds:** `--arc`, the builtin profile, `--lib` and `--plugin` keep whole units.
- **Prelude:** the prelude artifact is still emitted whole.

## Reachability
The roots are every definition of the root artifact and of the prelude artifact, after native lowering. From those, a unit definition is kept when it is reached through any of:
1. **Source edges:** every name spelled anywhere in the checked (operator-resolved) definition: variables, operators, constructors, fields and binders. This is a superset of the definition's references, so it can only keep extra code.
2. **List-fusion workers:** `Core.Typed.ListFusion` rewrites pipelines into a sibling worker named by base name and module hash (`foldRange@h`, `mapRange@h`, `lengthRange@h`, `buildRange@h`, `mapFilter@h`, `filterMapped@h`, `mapRangeForward@h`, `sum@h`, `product@h`, `fold@h`). Keeping one combinator of a module keeps its whole worker family.
3. **Checked entries:** a kept function with a precondition also keeps its `$precondK.name` entries, because the module table lists exports under them.
4. **Native fixpoint:** the kept units are lowered, and any unit definition their native code references that is not yet kept is added. This repeats until nothing changes, so a reference introduced by desugaring or specialization is never dropped.

**Run-time lookup by name.** The image's module table (`fpr_modtab`) lists every unit export so that `Mod.resolve`, `Mod.has` (FPRLive resolve probes) and `Mod.fn` can find it by (hash, name). If the program can reach a lookup that may read the image's own table, nothing is pruned: that covers `modResolve`, `modHas`, `Mod.fn`, and any row reader called outside the prelude helpers that read attached plugin tables only (`modFindAt`, `modFind`, `modCompatAt` and their walkers). Otherwise the table lists only the emitted exports. No reachable code can tell the two tables apart.

A missed reference cannot fail silently. It shows up as an undefined `fpr_fn_`/`fpr_obj_` symbol at link time.

The compiler prints `used definitions: K of N imported unit definitions emitted` (or the reason everything was kept).

## Cache soundness
Each unit's `.s` is cached under a path that already includes `coreCacheIdentity` of exactly the program the unit emits, plus its elisions, call arities, target tag and prelude/shape hashes. Keying the cache on the used-definition set therefore needs no extra key: two programs that use different parts of a module get different unit files, and two that use the same part share one. Choice: cache per (unit, used set), not per definition.

## Measurements
See fprisc PR "Emit only the used definitions of imported units" for the before/after compile allocation on CI and locally.

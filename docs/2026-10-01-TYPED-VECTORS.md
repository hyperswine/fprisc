# Typed vectors and explicit output layouts

Date: 2026-10-01. Implementation record; supersedes the opaque-Vector
finding in 2026-09-29-NATIVE-IDEAL-AUDIT.md.

The native and HostedBytecode frontends now expose `Vector a`. The linear
carrier declaration is `Vector 1 a = Type Int` (HostedBytecode retains its
own runtime carrier). Bare `Vector` annotations are refused; use `Vector Int`,
`Vector F64`, `Vector Point`, or a genuinely generic `Vector a`.

## The contract

```
Vec.new      : Unit -> Vector a
Vec.push     : a -> Vector a -> Vector a
Vec.at       : Int -> Vector a -> (a, Vector a)
Vec.put      : Int -> a -> Vector a -> Vector a
Vec.map      : (a -> b) -> Vector a -> Vector b
Vec.mapSame  : (a -> a) -> Vector a -> Vector a
Vec.filter   : (a -> Bool) -> Vector a -> Vector a
Vec.fold     : (b -> a -> b) -> b -> Vector a -> (b, Vector a)
Vec.fromList : List a -> Vector a
Vec.toList   : Vector a -> List a
Vec.free     : Vector a -> Unit
```

`Vec.mapSame` is currently a native frontend helper. HostedBytecode uses
`Vec.map` for generic same-element maps as well as type-changing maps.

`len`, `dup`, `split`, and `Sys.loopWith` preserve the element type too.
`loopWith` cannot change its buffer's element type between iterations.
The fixed numeric/SIMD operations accept `Vector Int`, matching their actual
runtime implementation (including gather and slice). `get`/`set` retain their
1-based convention; `at`/`put` are 0-based. `!` now has its actual native
list contract `List a -> Int -> a`; use ownership-threading reads for vectors.

Type checking rejects mixed pushes/writes, reads at the wrong element type,
and element functions incompatible with their input. Applying a linear type
constructor still produces a linear carrier; parameterization does not relax
consumption, copying or transfer rules. Existing complex measured signatures
can use `Vector _`: that is a monomorphic inference hole solved from the body,
not an independently chosen type at every read.

## Native representation

Typing alone would leave raw-bit float bugs in the runtime. Layout sites on
primitive *values* (not just direct applications) are resolved after numeric
defaulting, retaining source offsets for diagnostics.

- Literal `Vec.newAs "d"` means `Vector F64`, `"s"` means `Vector F32`,
  `"i"` means `Vector Int`, and `"id"` means `Vector (Int, F64)`.
  Dynamic/aliased layout declarations are refused. Boxed `b` fields require a
  known non-float type; they cannot disguise raw floats as object pointers.
- `Vec.new` and `Vec.fromList` use their inferred element types to select
  explicit layouts for floats and flat tuples containing floats. Known
  non-float elements retain the existing first-push layout implementation.
- A map preserving the exact element type retains the specialization and
  generic runtime paths. A type-changing map lowers to an internal `mapAs`
  with the **output** layout, never the input's float layout. For example,
  Int -> F64, F64 -> (Int, F64), and F64 -> String/Bool all work.
- Native builders and type-changing maps require a concrete output layout.
  Fully polymorphic allocation requires passing layout evidence or future
  representation specialization; it is refused today. Generic operations
  on existing vectors work. `Vec.mapSame` explicitly supplies the generic
  representation-preserving contract. Nested/record float outputs are refused;
  scalar and flat 2..8-field tuple layouts are supported.

The legacy `VList` convenience namespace uses Int constructors and a generic
same-element map. Use `Vec.*` directly for other constructors and type-changing
maps. This is a deliberate migration boundary, not silent Int defaulting.
HostedBytecode retains self-describing values and its generic type-changing
maps; its injected Vector signatures now link the element types too.

## Coverage

`tests/check_typed_vectors.py`, run by `check_base.py`, checks fourteen refusal
paths: mismatched pushes/puts/reads/map inputs, wrong scalar/tuple declarations,
dynamic/aliased layouts, boxed floats, missing element parameters, numeric
operations on float vectors, polymorphic allocation, untyped indexing and
linear reuse. It executes generic identity at different element types,
generic same-element mapping, type-changing maps and inferred float builders.
It also emits RV64/x64 code and tests HostedBytecode positive/negative paths.
`tests/base/typedvector.fpr` is the shared execution fixture. QOS's
`tools/typedvector-check.sh` runs it on Portable A64 and Native RV64 QEMU.
The tests cover concrete language/runtime contracts, not physical SIMD hardware
performance. Existing vectors, fusion, float, message and display gates remain.

Validation on 2026-10-01: Base, std, compiler cases, failure-honesty checks,
the typed-vector suite and QOS's 12/12 smoke checks passed. The final QOS
sweep passed its runnable functional gates, including ML/JIT agreement,
vector fusion and both typed-vector execution platforms. Its frontend size
guard initially failed because the new profile flag adds one shim line;
the documented ceiling adjustment passed the guard separately. The legacy
Sol vector example's old `!` access was migrated and rerun successfully.
Other legacy demo exhaustiveness failures remain outside this change.
Graphics/window legs, websocket prerequisites and alternate A64 cross-tools
were unavailable; GPU-requested comparisons used the fallback path.

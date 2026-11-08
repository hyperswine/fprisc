# P2 typed lowering, slice 3: the class widens

Continues [the slice 1 page](2026-11-08-P2-TYPED-LOWERING-SLICE-1.md).
Slice 2 made `Codegen.LowerTyped` the authority at emission: an S1 function
is emitted from its typed lowering wherever the erased lowering of the same
function agrees, the erased function is the assertion, and a disagreement
stops the compile.

Slice 3 widens the class the typed lowering accepts, one rung at a time.
Each widening has the same gate as slice 2:

- code is identical to the `FPR_NO_TYPED_LOWER=1` build on every compiling
  sweep program;
- no refusal and no disagreement anywhere;
- every function in the class is accounted for (typed, worker, placed, arc,
  absent);
- each rung is counted in the census and in the typed-lowering note.

## Order

| Step | Widening | What `LowerTyped` needs |
|---|---|---|
| 3a | `signatures`: calls-shaped bodies with any monomorphic signature | nothing: every value of a public function is a tagged word |
| 3b | the same bodies with polymorphic signatures (30% of definitions keep a type variable after monomorphization; they compile once over the uniform tagged representation) | nothing new in lowering; the census must count them in the rung |
| 3c | `forms`: other primitives (HAL calls through `calleeOf`, the inline ones `Lower` has), sequences, binder-pattern bindings, pattern guards, join calls | the primitive dispatch of `Lower.lowerVal`, `Sequence`, `LetPattern`, guards with patterns, join blocks |
| 3d | `products`: constructors, tuples, records and their patterns | constructor allocation and nullary objects, field projection, variant tests as erasure plans them |
| 3e | `strings`: literals and string patterns | `OString`, string pattern tests |

Lists, closures and vectors follow later; they need the list builders, the
general-apply adapter and the kernel rewrite.

The step 0 census put `products` at the largest jump (2.9% to 37.8% of
definitions), but part of that rung was functions whose bodies were already
in S1 and only their signature was outside `Int`/`Bool`. Step 3a takes that
part first.

## Step 3a record: any monomorphic signature (8 November)

- `TypedCensus` gains the `signatures` rung between `calls` and `forms`:
  bodies whose only feature is calls to known functions, with a monomorphic
  signature that is not all `Int`/`Bool`. The typed lowering's class is now
  t1 + calls + signatures.
- `LowerTyped` refuses only a polymorphic signature, not a non-scalar one.
- The census now counts applying a local (a function parameter) as a
  closure. Before, `twice f x = f (f x)` was counted in `signatures` and
  then refused, because `LowerTyped` lowers only known heads.
- The emission's worker exemption is generalized. The field-worker pass
  turns a function with a product parameter into a wrapper around
  `$worker.fields.NAME`, just as the scalar-worker pass does for `Int`
  (`argLayer` and `envLayer` in logbook, pos1 and inventory disagreed until
  this). A function counts as a worker wrapper when the body it lowers calls
  any `$worker.` function: scalar, field, return, storage and consume
  workers all use that prefix. The note field is now `worker=`.

| | slice 2 | step 3a |
|---|---|---|
| class (sweep, 766 units) | 760 | 1,824 |
| emitted typed | 716 | 1,744 |
| of which from call regions | 16 | 554 |
| worker wrappers | 40 | 71 |
| placed, not ordinary | 4 | 9 |
| refused, disagreement | 0 | 0 |

The corpus (host and RV64) goes from 56 to 74 class functions, 62 typed.
Code is identical to the `FPR_NO_TYPED_LOWER=1` build on all 145 compiling
sweep programs; the same 6 known failures remain.

QOS guishell: 194 class functions, 191 typed (52 from call regions), 1
worker wrapper, 2 placed. Unit suites, baseline (23 contracts, no drift),
bridge, policy D1/D2, compiler options and `make stdcheck` pass. Compile
budget unchanged at +10.4 / +10.6 / +4.8% (kept red).

## Step 3b record: polymorphic signatures (8 November)

- `TypedCensus` gains the `generic` rung: calls-shaped bodies with a type
  variable in the signature. They were counted under `polymorphic` before;
  that rung now holds only the polymorphic functions with other features.
- `LowerTyped` has no signature check left: every value of a public function
  is a tagged word, whatever its type.

| | step 3a | step 3b |
|---|---|---|
| class (sweep, 766 units) | 1,824 | 2,690 |
| emitted typed | 1,744 | 2,591 |
| of which from call regions | 554 | 647 |
| worker wrappers | 71 | 90 |
| placed, not ordinary | 9 | 9 |
| refused, disagreement | 0 | 0 |

Corpus: 116 class functions, 104 typed. QOS guishell: 270 class functions,
266 typed. Code is identical to the `FPR_NO_TYPED_LOWER=1` build on all 145
compiling sweep programs. The other checks pass. Compile budget +10.6 /
+10.7 / +4.9% (+0.1-0.2 points: the typed lowering now runs on 3.5 times as
many functions).

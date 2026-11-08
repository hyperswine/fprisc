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

## Step 3c record: forms (8 November)

The `forms` rung now admits any signature: other primitives, sequences,
join calls and call regions. Pattern bindings and pattern guards move to the
products rung (census feature `FPattern`), since their patterns are almost
always constructor patterns.

- **Primitives go to `Codegen.Lower`'s own dispatch.** A primitive
  application other than the integer operators is handed to
  `Lower.lowerVal` / `Lower.lowerTail` as the Core the plan mirrors. Each
  plan node is the erased form it stands for (`toCore`), with the plan's
  bound values under their own names. The first attempt lowered compound
  arguments in `LowerTyped` and passed them as names. That broke on
  `band x ((1 shl n) - 1)` in `std/digest`: `Lower` untags `x` before it
  evaluates the second argument, an interleaving pre-lowering cannot
  reproduce. Giving `Lower` the whole application shares the dispatch and
  its evaluation order exactly. `Lower` now exports `Env`, `lowerVal` and
  `lowerTail` for this.
- **Sequences** are planned as erasure binds them (a fresh `seq` let).
- **Join calls** are calls to the join's code label, captures first: a
  known function of the program.
- **Literal lets are substituted at their uses**, through every let the
  plan builds (`pLet`), including function-match argument bindings and
  aliases of a literal. The optimizer's `normIn` does this before the
  erased lowering, so the erased function evaluates the constant where it
  is used. `log`, `logErr` and `logWarn` in the prelude disagreed on this
  until the plan did the same.

| | step 3b | step 3c |
|---|---|---|
| class (sweep, 766 units) | 2,690 | 5,703 |
| emitted typed | 2,591 | 5,529 |
| of which from call regions | 647 | 1,182 |
| worker wrappers | 90 | 100 |
| placed, not ordinary | 9 | 74 |
| refused, disagreement | 0 | 0 |

Corpus: 229 class functions, 208 typed. QOS guishell: 486, 476 typed. Code
is identical to the `FPR_NO_TYPED_LOWER=1` build on all 145 compiling sweep
programs. Unit suites 43/43 (`LowerTyped` adds a delegated `band` with a
substituted literal), baseline, bridge, policy, compiler options and
`make stdcheck` pass. Compile budget +10.9 / +10.7 / +4.9% (hello +0.3
points).

The stage dump (`FPR_TYPED_LOWER_STAGES_SHOW=NAME`) now prints a function's
stages whether or not it agreed at the boundary.

## Step 3d-i record: constructors, tuples and atoms (8 November)

Step 3d is split in three, each with its own census feature:

- **3d-i:** constructors, tuples, atoms and their patterns;
- **3d-ii:** records;
- **3d-iii:** pattern bindings and pattern guards.

Records need erasure's type-directed field lookup and shape-dispatched
updates, which is a separate piece of work.

- `TypedCensus` gains the `constructors` rung, with any signature. The
  feature `FConstruct` covers `Construct`, `TupleValue`, `AtomValue`, and
  constructor and tuple patterns other than `True`/`False` and the list
  constructors. Records stay at `products`.
- The plan builds the new values as erasure does:
  - `PMk tid variant fields` for constructors and tuples (`TupN`);
  - `PMk 6 0 [PStr name]` for atoms.

  Constructor and tuple patterns get erasure's variant test and its
  `matchFields`, with the last field's test innermost (`PProj i scrut`
  per field). The covered-last-arm shortcut extends to constructors with
  fields: it skips the tag test and keeps the field matches.
- The new nodes are lowered by `Codegen.Lower` from their Core form
  (`VCore`), like the primitives in 3c. The constructor layout includes the
  wide tuples (`DataLayout.wideTup`), as erasure's does.
- Fallback joins were the expected risk. A multi-test arm with a
  non-trivial fallback makes erasure build a join. The closed program
  already carries its joins explicitly (`MatchTail` with join calls), and
  native erasure refuses to manufacture one, so none appeared: `LowerTyped`
  still refuses them and the sweep had no refusal.
- QOS guishell (reuse is on for QOS profiles) brought two more erased
  rewrites into view. Each is now its own count in the note:
  - **`reuse=`:** constructor reuse (`Reuse.hs`) wrote a fresh cell over a
    uniquely owned one (`$reuse.fresh`, `OReuse` against the typed `OMake`)
    in `ring`, `rrect` and `strips`. Like workers, this is an optimizer
    rewrite and keeps the erased function; P4 plans reuse on typed facts.
  - **`optimized=`:** `normIn` also sinks a pending let into the next let's
    right-hand side (`serveWith`: a function value bound early, used late).
    Mirroring every optimizer rewrite is the typed optimizer's job, not
    this slice's.
- **The three-way rule.** Every function whose typed and erased native
  functions differ, and which is not a worker, reuse or placed function, is
  decided by comparing Core, up to binder names, with literal lets
  substituted (`Core.Alpha`):
  - the plan's Core (`LowerTyped.planCore`) against the Core erasure and
    placement gave (`Regions.resultProgram`): if they differ, the plan is
    wrong, and that is a disagreement;
  - the plan's Core against the Core the emission lowered: if they differ,
    the optimizer reshaped the body, counted as `optimized`;
  - otherwise the same Core was lowered two ways, and that is a
    disagreement.

  So a planning bug cannot hide as an optimization. The unit test's
  typed function for a different body is still a disagreement.

| | step 3c | step 3d-i |
|---|---|---|
| class (sweep, 766 units) | 5,703 | 14,978 |
| emitted typed | 5,529 | 14,625 |
| of which from call regions | 1,182 | 1,749 |
| worker wrappers | 100 | 223 |
| reuse, optimized | - | 0, 0 |
| placed, not ordinary | 74 | 130 |
| refused, disagreement | 0 | 0 |

Corpus: 312 class functions, 282 typed. Code is identical to the
`FPR_NO_TYPED_LOWER=1` build on all 145 compiling sweep programs.

QOS guishell: the first cold run counted 977 class functions, 961 typed,
before the reuse exemption existed; with it, guishell compiles with no
disagreement (3 reuse, 1 optimized). Its later counts are smaller because
some units are cached outside the cache directory the check clears, so
guishell numbers here are evidence of agreement, not a cold count.

Unit suites (`LowerTyped` adds a constructor match and value), baseline,
bridge, policy, compiler options and `make stdcheck` pass. Compile budget
+11.1 / +10.9 / +5.1% (hello +0.2 points).

## Step 3d-ii record: records (8 November)

- `TypedCensus` gains the `records` rung: record values, fields, updates,
  record patterns and the TRMC field store (`SetField`). Pattern bindings
  and pattern guards stay at `products`.
- The plan mirrors erasure's record code:
  - values are sorted by field name into their shape (`PMk shape arity`);
  - a field projects directly when one shape with a closed row has it, and
    otherwise dispatches on the variant through a scrutinee let
    (`recordShapes`, `closedRowShape`, `fieldType`, as erasure uses them);
  - `RecordUpdate` builds one arm per candidate shape, with nested paths
    recursing;
  - `PlannedUpdate` checks the plan against the shapes the checked type
    admits, as erasure does, refusing a stale plan;
  - record patterns project and bind each field;
  - `SetField base 1 v` is the primitive `$trmc.setTail`.
- `Layout` carries the record shapes (`shapeLayouts`). A record pattern's
  dispatching projection needs a temporary but the pattern matcher has no
  counter, so the temporary is keyed by the field's binder (`KField`).

| | step 3d-i | step 3d-ii |
|---|---|---|
| class (sweep, 766 units) | 14,978 | 15,938 |
| emitted typed | 14,625 | 15,557 |
| of which from call regions | 1,749 | 1,846 |
| worker wrappers | 223 | 235 |
| reuse, optimized | 0, 0 | 5, 1 |
| placed, not ordinary | 130 | 140 |
| refused, disagreement | 0 | 0 |

Corpus: 320 class functions, 290 typed. QOS guishell, cold this run: 1,262
class functions, 1,239 typed (4 reuse, 1 optimized, 7 worker, 11 placed),
no disagreement. Code is identical to the `FPR_NO_TYPED_LOWER=1` build on
all 145 compiling sweep programs. The other checks pass. Compile budget
unchanged at +11.1 / +10.9 / +5.1%.

## Step 3d-iii record: pattern bindings and pattern guards (8 November)

- `LetPattern p rhs body`: the value bound to a temporary, then the pattern
  matched against it, with the no-match trap erasure uses (`bindPattern`).
  A vector read pair is a vectors-rung form and stays out of the class.
- `PatternGuard p e`: the value bound to a temporary and matched, with the
  remaining guards inside and the arm's fallback on failure, as erasure's
  `guards` builds it.
- The `products` rung (pattern bindings and guards) joins the class with any
  signature. The class is now t1 through products. Only strings, lists,
  closures, vectors, polymorphic functions using those, and `other` stay
  out.

| | step 3d-ii | step 3d-iii |
|---|---|---|
| class (sweep, 766 units) | 15,938 | 16,868 |
| emitted typed | 15,557 | 16,300 |
| of which from call regions | 1,846 | 2,058 |
| worker wrappers | 235 | 300 |
| reuse, optimized | 5, 1 | 11, 6 |
| placed, not ordinary | 140 | 251 |
| refused, disagreement | 0 | 0 |

Corpus: 331 class functions, 298 typed. QOS guishell: 1,445, 1,399 typed.
Code is identical to the `FPR_NO_TYPED_LOWER=1` build on all 145 compiling
sweep programs. The other checks pass. Compile budget +11.2 / +10.9 /
+5.1%.

Step 3d is done. Against the step 0 census (34,304 checked definitions,
shared units once), the class covers about half of all definitions, and
96.6% of the class is emitted typed. Next is step 3e: string literals and
string patterns.

## Step 3e record: strings (8 November)

- String literals are the plan node `PStr`. A string pattern is
  `PStrEq scrut s`, which stands for erasure's
  `CIf ((==) scrut "s") ok fail`. Both are lowered by `Codegen.Lower` from
  their Core form.
- The `strings` rung joins the class with any signature. The class is now t1
  through strings: everything but lists, closures, vectors, polymorphic
  functions using those, and `other`.
- The plan's Core per function (`loweredCores`) is now built lazily (a lazy
  map, no pattern forcing it). Only functions whose typed and erased native
  functions differ read it.

| | step 3d-iii | step 3e |
|---|---|---|
| class (sweep, 766 units) | 16,868 | 21,993 |
| emitted typed | 16,300 | 21,050 |
| of which from call regions | 2,058 | 3,984 |
| worker wrappers | 300 | 427 |
| reuse, optimized | 11, 6 | 14, 13 |
| placed, not ordinary | 251 | 489 |
| refused, disagreement | 0 | 0 |

Corpus: 396 class functions, 355 typed. QOS guishell: 2,109, 2,025 typed
(5 reuse, 2 optimized). Code is identical to the `FPR_NO_TYPED_LOWER=1`
build on all 145 compiling sweep programs. Unit suites (`LowerTyped`: a
string literal, a string pattern, a lambda still refused), baseline,
bridge, policy, compiler options and `make stdcheck` pass.

**Compile budget** +11.5 / +11.4 / +5.4% allocation (+0.3 to +0.5 points),
still red. hello's peak residency moved from -36.7% to +14.5% against the
baseline (27 MB to 49 MB). That is GC sampling, not retention: hello runs
5 major collections, and the peak depends on where one lands.

| hello, peak live | `-A64m` (the default) | `-A32m` |
|---|---|---|
| typed lowering | 44.5 MB | 43.2 MB |
| `FPR_NO_TYPED_LOWER=1` | 24.9 MB | 41.6 MB |

The typed lowering costs about 1.5 MB at the same collection points. The
25% residency margin is not crossed.

The class covers about 64% of the step 0 census's checked definitions
(21,993 of 34,304), and 95.7% of the class is emitted typed. The rungs
left are lists (list literals, builders and list patterns), closures
(lambdas, closure values, code calls, applying a local, result pipes) and
vectors. Those need the list builders, the general-apply adapter and the
kernel rewrite, which slice 3's plan put after strings.

## Step 3f record: lists (9 November)

- A list literal is the plan node `PList xs`, which stands for erasure's
  `Cons x (Cons y .. Nil)` chain and is lowered by `Codegen.Lower` from that
  Core. A list builder is planned as its body, as erasure does: its stores
  are already `SetField` (the TRMC tail store). Cons and Nil patterns were
  already constructor patterns in the plan; only the census set them apart.
- The `lists` rung joins the class with any signature, so polymorphic list
  functions are in. The class is now everything but closures, vectors,
  polymorphic functions using those, and `other`.
- No new exemption was needed. Everything matched on the first sweep.

| Sweep (151 programs, 766 units) | after 3e | after 3f |
|---|---|---|
| class (S1) | 21,993 | 25,106 |
| emitted typed | 21,050 | 23,948 |
| of which call regions | 3,984 | 4,893 |
| worker wrappers | 427 | 593 |
| reuse, optimized | 14, 13 | 16, 13 |
| placed, not ordinary | 489 | 536 |
| refused, disagreement | 0 | 0 |

Corpus: 432 class functions, 390 typed. QOS guishell: 2,406, 2,311 typed
(10 reuse, 3 optimized). Code is identical to the `FPR_NO_TYPED_LOWER=1`
build on all 145 compiling sweep programs. Unit suites (`LowerTyped`: a
list literal and a list builder), baseline, bridge, policy, compiler
options and `make stdcheck` pass.

**Compile budget** +11.7 / +11.7 / +5.7% allocation (+0.2 to +0.3 points),
still red. hello's peak is +13.7%, inside the 25% residency margin.

The class covers about 73% of the step 0 census's checked definitions
(25,106 of 34,304), and 95.4% of the class is emitted typed. Closures
(lambdas, closure values, code calls, applying a local, result pipes) and
vectors are left. They need the general-apply adapter and the kernel
rewrite.

## Step 3g record: closures (9 November)

- A closure value, a code call, applying a local (any head that is not a
  known name) and the success arm of a result pipe are the plan node
  `PCall head args`, which stands for erasure's curried `CApp` spine and is
  lowered by `Codegen.Lower`'s own application dispatch (known calls,
  `fpr_applyN` staging for partial and over-saturated ones). For now that
  dispatch is the general-apply adapter: the typed lowering doesn't build
  its own. A result pipe is erasure's scrutinee let, `Ok` test and `Err`
  rebuild. A lambda is `PLam`; `Lower` refuses it as it refuses the erased
  lambda (closure conversion runs before this point, so none is lowered).
- The `closures` rung joins the class with any signature.
- New census rule: a closure or code call over a code label that isn't in
  the unit (an inlined lambda from another unit, e.g. std/list's `all`
  inside printer-host) is `other`. Only monomorphization's specialization
  makes such a body lowerable here, and the erased function comes from that
  specialized body. The first sweep refused the 2 functions this covers;
  the rule takes them out of the class.

| Sweep (151 programs, 766 units) | after 3f | after 3g |
|---|---|---|
| class (S1) | 25,106 | 34,223 |
| emitted typed | 23,948 | 32,370 |
| of which call regions | 4,893 | 7,931 |
| worker wrappers | 593 | 878 |
| reuse | 16 | 56 |
| optimized | 13 | 258 |
| placed, not ordinary | 536 | 661 |
| refused, disagreement | 0 | 0 |

Corpus: 575 class functions, 523 typed. QOS guishell: 2,634, 2,525 typed.
Code is identical to the `FPR_NO_TYPED_LOWER=1` build on all 145 compiling
sweep programs. All 43 unit suites (`LowerTyped`: applying a local; a
lambda still refused), baseline, bridge, policy, compiler options and
`make stdcheck` pass.

**Compile budget** +12.4 / +12.7 / +6.7% allocation (+0.7 to +1.0 points,
the largest step yet: closure-heavy functions are big), still red. hello's
peak is +11.6%.

The class is now everything but vectors, functions over another unit's
code, and `other`; 94.6% of it is emitted typed. The earlier "share of
definitions" figures (64%, 73%) divided the sweep's class by the step 0
census total (34,304), which was counted separately and is not the same
population as the sweep's deduplicated units, so that ratio is not a
reliable coverage figure (at this size it would read as nearly 100%). The census note per unit is
the right measure for coverage. The `optimized` exemption grew from 13 to 258: the
optimizer reshapes closure-applying bodies (inlining and beta reduction)
before the erased lowering, so those keep the erased function. Vectors,
which need the kernel rewrite, are the last rung.

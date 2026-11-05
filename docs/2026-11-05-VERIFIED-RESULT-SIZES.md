# Verified result sizes for resource composition

Codegen 177 removes unchecked result-size annotations from the resource
composition path. It follows the [signed-domain correction](2026-11-05-SIGNED-RESOURCE-DOMAINS.md).
This is proof infrastructure for static-arena admission, not a new allocation
optimization or a physical memory certificate.

## Reproduced false proofs

The [native comparison](../bench/2026-11-05-result-sizes.json) uses the previous
codegen-176 compiler as its baseline. Two invalid caller contracts that it
accepted are now refused:

| Source | Previously accepted caller bound | Current result |
| --- | --- | --- |
| A substring helper claims `size make <= 0`; two results are concatenated | 64 requested bytes | Independently proved sizes require an 80-byte bound |
| A traversal emits two cells per input but claims size at most the input length; its result is copied | `72 * len xs + 72` requested bytes | The false size invariant is unproved and cannot supply the copy's input length |

The string fixture takes two eight-byte substrings and concatenates them into
sixteen bytes. Its three string requests total `(16+8) + (16+8) + (16+16) = 80`
bytes. Native allocation counters independently observe **three requests and
112 managed object-block bytes** on one/four harts, including the old executable
built with the falsely accepted 64-byte contract. Requested payload/header
bytes and managed block bytes are deliberately reported separately.

The corrected 80-byte caller bound passes whether the helper's annotation says
zero or eight. The body-derived upper bound is eight in both cases; annotation
text no longer controls that fact. Output remains `16`.

## What is proved

`Resource.ResultSize` derives lemmas from the checked native program's typed
functions and lexical identities. The proof product retains its owned erasure;
a caller cannot attach it to an unrelated program just by supplying matching
names. Publication remaps the checked parameter positions to that erasure.
No lemma is inferred merely from an untyped two-field constructor: the list
spine and String byte sequence have distinct checked kinds. The older literal
length helper also now recognizes only builtin Nil/Cons layouts.

The pass follows variables, lets, constructors, known calls, record/tuple
components and returning pattern branches. A Nil pattern can establish zero
length only for an **exact** size expression. A Cons pattern supplies a tail
one element shorter, and an appropriate nonnegative path fact. Unknown list
elements do not inherit the outer list's length.

Recursive candidates come from a finite family: the source annotation,
checked sequence parameters, a structural measure plus possible accumulators,
and positive parts of linear measures. Every returning path of every member of
a recursive group must preserve the chosen group invariant before publication.
This is induction on successful call trees, not an assumption that a written
annotation is true. More complex candidate combinations may remain unproved.

For example, `revOnto xs acc` preserves the bound `len xs + len acc`. Map and
filter helpers use the same kind of accumulator invariant. The zip helper can
use its measured input length plus its accumulator instead of adding both
input lengths. Repeat uses `max(0,n)`; inclusive range uses
`max(0,b-a+1)`. The old repeat/range/mapRange annotations were corrected to
include those clamps, so empty results at negative counts or reversed endpoints
no longer claim a negative size.

Guard comparisons contribute checked affine nonnegativity facts. The resource
inequality checker accepts a fact only through an explicit positive-multiple
witness plus an independently nonnegative remainder. It does not turn an
arbitrary budget into a fact or claim to solve general nonlinear arithmetic.
An independent integer evaluator tests its claimed inequalities under sampled
path facts, including Base Int and I64 endpoints.

## Exact values and upper estimates

A returned-size lemma is usually an upper bound. Passing that estimate into a
decreasing expression can understate a resource budget, so substitution requires
monotonicity unless the actual argument size is exact. Unsupported substitutions
stay opaque and cannot cancel to a constant. Integer arguments used in a size
formula must likewise have exact symbolic values; an unknown function result
cannot masquerade as a known counter.

Strings count bytes. The frontend already encodes textual characters as UTF-8
and preserves raw byte escapes. The size pass counts that representation once;
it does not UTF-8-encode it again. Native checks cover multibyte text, a zero
byte and a non-UTF-8 raw byte. Substring bounds follow the runtime's clamped
slice contract; concatenation adds its operands' lengths.

## Annotation and failure policy

`size` annotations remain **candidate lemmas**. Unlike enforced work/alloc/live
contracts, a mismatching or unsupported size annotation does not by itself reject
an ordinary program. The cost report shows its independent bound and comparison,
or says that no lemma was proved and the annotation is not used. A caller's
work/alloc/live contract still fails if no adequate resource proof is available.
An independently proved result bound may be used even when the written size
candidate is wrong, as the string fixture demonstrates.

The current native qualification verifies twelve standard list operations:
range, repeat, reverse, append, map, indexedMap, filter, filterMap, take, drop,
zip and zipWith. `unique` and sorting still need richer callback/nested-container
invariants; their annotations remain explicitly unproved and unused.

These are **partial-correctness** lemmas: they bound a result if evaluation
returns. They do not establish termination, eliminate a trap, or reorder effects.
The minimum-Int range still overflows after its preceding `before` print, with
the same output prefix in the baseline and revised executables on one/four harts.
The maximum-Int singleton range still succeeds. Work and allocation equations
must separately account for all execution before a failure.

## Completed validation

All 39 Haskell suites pass, including false recursive candidates, exact versus
upper size substitution, unknown element lists, constructor identity and the
independent signed/path-fact inequality oracles. Native size tests, the earlier
branching/PAP/growing-payload and signed-domain regressions, and existing region
lifetime checks pass. List fusion and all materializing-pipeline regressions
retain their allocation, effect, overflow and rollback results.

The source cost-report suite still verifies the direct pipeline's 2.93 µs
manifest example and reports Todo in 27.0 seconds in this run. This is a priced
source-model example, not measured hardware execution time. The unchanged
compiler budget passes at **1.59/32.68/68.98 GB** for hello/std-live/pos1.
The [16–256-helper C2 gate](../bench/2026-11-05-result-size-specialization-cost.json)
retains exact assembled code/function parity and 1.001–1.002x compiler allocation
against explicit twins. No baseline was raised. Runs overlapped other validation,
so elapsed compilation times are not throughput comparisons.

The [validation manifest](../bench/2026-11-05-result-size-validation.json) records
source/compiler identities and all completed local checks. The new native size
suite is registered in Base and host-extra CI; this is not a claim that remote
CI or a physical-board qualification has run.

## Admission limits

Proving a final list length does not bound every intermediate accumulator or
its cumulative allocation. The older std-map resource fixture still stays
unproved because its reverse work was priced at the initial accumulator size.
Its result-size lemma is now verified independently of that missing work proof.

Static-arena admission still needs final lowered allocation sites, peak-live
storage, ownership/conversion scratch, native stack accounting and exact
image/target enforcement. Hardware timing additionally needs bounded runtime C
costs, composed yield spacing and physical-target evidence. This change does
not qualify the separate historical StdCheck model or establish any of those
physical bounds.

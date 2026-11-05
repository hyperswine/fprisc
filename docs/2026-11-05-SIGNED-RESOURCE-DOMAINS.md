# Signed resource inputs and exact budget comparisons

Codegen 176 makes signed input domains explicit in the source resource
checker. This extends the [resource-equation prerequisites](2026-11-05-RESOURCE-EQUATION-PREREQUISITES.md)
for static-arena admission. It is a correctness change, not an allocation
optimization, a timing certificate or a completed physical-arena implementation.

## Four rejected contracts

The [native comparison record](../bench/2026-11-05-resource-domains.json)
compares against the codegen-175 compiler. It previously accepted all four:

- A measured countdown with `work count <= 5 * n + 5`, despite allowing
  negative `n`. At `n = -2` the old main equation reported negative known
  work, although the function executes its base case and prints normally.
- A structural list fold with `work count <= max (6 * len xs) 6`. Its derived
  equation is `6 * (len xs + 1)`. The old comparator combined the two declared
  arms into a larger polynomial budget that the declaration never supplied.
- An identity function with `work identity <= 1 - n`. The old comparison
  omitted negative monomials occurring only in the declaration, accepting
  a negative work budget for inputs such as `n = 3`.

- A chain builder whose span uses two computed arguments. Both unknown
  arguments used the same placeholder, allowing `limit - start` to cancel
  to zero. The old checker accepted 16 requested bytes for a six-cell chain
  that needs 96. Unknown signed values no longer serve as equality evidence;
  their uncancelled span remains opaque until its actual range is proved.

All four are now compile-time resource-proof failures. Ordinary functions
without these invalid declarations remain legal. Successful native outputs
are checked separately from the proof verdict.

## Domain and algebra contracts

A verified decreasing measure bounds the number of recursive edges above its
floor; a negative entry still executes a base case. The call-count multiplier
is now `ceil(max(0, measure) / step) + 1`. Structural lengths are already
nonnegative and keep their existing form. Negative spans, zero, positive
inputs and the minimum Base Int are covered by native regressions.

Integer parameter atoms are signed by default. Lengths, callback work and
callback allocations are nonnegative. Opaque signed argument values have a
separate internal constructor from opaque costs and lengths. This prevents
an unknown argument from losing its clamp without making every unknown cost
inflate the report with redundant maxima. Manifest primitive prices cannot
replace an opaque signed value.

A source bound can explicitly use `max 0 n` to retain the original input
domain. Alternatively, an existing enforced signature predicate such as
`n >= 0` can establish a nonnegative domain. The resource checker consumes
only facts entailed by that parameter's original value predicate. It does
not invent a precondition from a termination measure or from observed callers.
Direct calls, partial applications and higher-order calls retain precondition
checks. A predicate such as `n >= -5` grants no nonnegative assumption.

The comparator normalizes the exact difference between declared and derived
polynomials, including declaration-only terms. Identical signed terms can
cancel; even powers are nonnegative. Maxima and ceiling divisions remain
exact symbolic atoms until an inequality step has established the sign of
their multiplier. A positive max coefficient can use an individual lower
arm; a negative coefficient must discharge every arm. Ceiling division uses
`e/k` as a lower bound and `e/k + 1` as an upper bound, never the reverse.
Unknown multiplier signs cause conservative refusal. This is not a complete
nonlinear inequality solver, so some valid contracts remain unproved.

The old unrestricted linear countdown fixture is retained as
`bound_signed_unsafe.fpr`. Positive countdown/live/manifest fixtures now
write their explicit clamps; they do not silently restrict valid inputs.
Enforced preconditions do not automatically remove the cost of generated
failure paths: if the existing precondition pass cannot discharge a recursive
call's guard, its diagnostic work may still make a resource equation opaque.

## Validation scope

The `ResourceCosts` checks include an independent integer evaluator over
signed inputs, large integer limits, nonnegative lengths, nested maxima,
negative and signed products, ceiling division and both inequality sides.
The grid has 31 expressions (961 pairs) and 324 valuations per claimed proof.
Every claimed proof in the expression-pair grid must hold at every sampled
valuation. Explicit positive assertions prevent an always-refuse checker from
passing. Native checks cover outputs on one/four harts and success/failure at
direct, partial and escaped precondition boundaries. The native suite is
registered in Base and host-extra CI.

All 39 Haskell suites pass. The new native suite and the preceding
branching/growing-payload/PAP suite pass on one/four harts. Existing nested
region, received-root and persistent `loopWith` checks pass. The source-report
suite retains its positive proofs, explicit refusals, manifest comparisons,
scoped-live equations and Todo reporting (15.1 seconds in this run).

An initial implementation kept every unknown-bearing term separate. It was
correct on the focused regressions but exceeded the unchanged compiler budget:
std-live allocated 33.16 GB, 10.8% above the established baseline's 10% allowance.
That version was rejected. Same-sign terms now remain compact; only opposing
unknown-value coefficients require separate groups. The final compiler passes
at **1.59/32.69/68.96 GB** for hello/std-live/pos1 without raising a baseline.
The [16–256-helper C2 gate](../bench/2026-11-05-signed-resource-specialization-cost.json)
retains exact code/function parity and 1.001–1.002x compiler allocation versus
explicit twins. These runs overlapped other validation; their elapsed times
are not application speedup measurements.

The [validation manifest](../bench/2026-11-05-signed-resource-validation.json)
records final compiler/source identities and test evidence, plus the rejected
bookkeeping experiment. This slice changes neither runtime ABI nor scheduling
policy. Its cache revision changes because resource equations guide regions.

[Codegen 177](2026-11-05-VERIFIED-RESULT-SIZES.md) subsequently added verified
result-size composition for supported operations. This signed-domain slice
itself does not prove result-size declarations, changing-accumulator
recurrences, final lowered allocation/peak-live storage, stack fit or hardware
timing. The separate historical StdCheck model is not qualified by this
change. Admission still needs verified size facts and final image/target
resource accounting; source requested-byte bounds alone remain insufficient.

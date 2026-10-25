# Typed generated traps

Date: 2026-10-25. Kind: implementation and validation record.
Applies after typed vector layout evidence at `162e70d`.

Selected native typed entries now lower anonymous expression holes and
references to constructors with holed fields through checked trap plans.
These forms no longer force the entire source entry through compatibility
desugaring. The generated parameters have distinct binder identities, checked
types and ownership shapes before ordinary typed closure conversion.

## Contracts and evaluation timing

`Compiler.Trap` owns the private plan, its origin, argument/result types and
failure text. An expression hole with a function type consumes **one** argument
before trapping, even when its result is another function. A scalar hole fails
immediately. A holed constructor consumes its declared field count, one curried
argument at a time; partial application stays a value. The constructor plan
rejects an inconsistent arrow spine or a nonpositive field count.

Inference retains explicit constructor-hole provenance separately from ordinary
polymorphic constructor schemes. A type variable in a normal constructor is
not evidence of a hole. The checked source planner requires a matching global
reference and instantiated scheme before creating a constructor trap. It uses
the original checked expression type for anonymous holes, rather than inferring
types from the generated surface wrapper.

The typed plan emits lambdas around the existing intrinsic `Fail` node.
Closure conversion verifies and lifts those lambdas before erasure; failure
becomes `CErr` and then the native IR's `TUnreachable`. A source binding named
`error` cannot redirect this intrinsic. Compatibility/Sol surface rewriting
still uses the existing wrapper shape and shares the trap-delay/message owner.
Named holes remain checking obligations and refuse compilation with their
checked name and type.

The saved compiler and the new compiler agree on the tested native trap text,
exit status and side-effect order, including `error` shadowing. No behavior bug
is claimed from those shadowing probes. Private generated code changes advance
the codegen cache revision from **109 to 110**. Runtime calling conventions,
context/memory structures and source parser Binary formats are unchanged.

## Validation

`tests/TypedTraps.hs` requires these forms to reach typed and closed products.
It verifies constructor provenance, the exact delay contracts, closed-product
lint, malformed-plan refusals and independent machine-IR evaluator answers.
It also checks that named holes retain their inferred type for the driver.

One native fixture selects eight independent paths at runtime, requiring only
one build per hart configuration. On one and four harts it checks immediate
and piped holes, a curried expression hole, partial and saturated constructors,
effect order, and local `error` bindings. Assertions include exact stdout and
exit status; code after a trap must not execute. A separate source checks the
named-hole refusal. The x64/RV32/RV64 checks verify successful portable emission
and the actual length-delimited trap strings. Native execution here is A64;
portable emission alone is not execution proof on those other targets.

The saved `162e70d` compiler and the new compiler both satisfy the same eight
fixed native answers and named-hole refusal. The focused Core suite passes.
The frozen-tree sweep passed **all 136 Base jobs in 470.72 seconds on six
workers**, with no reused CI coverage. The expanded Core subcheck took 22.82
seconds. Existing platform/toolchain subchecks retain their explicit execution
or skipping evidence; no physical-board validation is claimed.

Sol argument/shared-language compatibility and bounded tail calls pass:
3,000,000 self/mutual iterations, peak 85 MB, with TailCall and no following
Ret. The preceding `162e70d` hosted run has reached its Base sweep; this
checkpoint requires its own hosted validation after push.

Local records: `/private/tmp/fpr-traps-build.log`,
`/private/tmp/fpr-traps-focused.log`, `/private/tmp/fpr-traps-baseline.log`
and `/private/tmp/fpr-traps-base.{log,json}`, plus
`/private/tmp/fpr-traps-sol-{args,both,tail}.log`.

## Remaining full-goal work

Specialization/per-unit transformations still decline stale source plans.
Other generated forms, computed recursive initializers, layout temporaries,
optimization/worker/reuse/region transformations, full lint and the remaining
diagnostic and machine-contract table entries remain required. This checkpoint
does not complete the compiler cleanup goal.

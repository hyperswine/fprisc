# Structured checking diagnostics and ownership obligations

Date: 2026-10-25. Kind: implementation and validation record.
Applies after shared compiler options at `355ccb0`.

Inference, safety/termination checking and linearity now produce structured
diagnostics consumed directly by both native compilation and Sol. This is a
producer/consumer migration, not a wrapper that reconstructs metadata from
already-rendered messages. The [compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md)
remains active for the other diagnostic producers, parser ranges and typed
Core transformations.

## Coordinates, diagnostics and rendering

`Source.Span` owns decoded-character offsets, half-open file ranges and source
locations independently of either AST or inference. `Diagnostic.Syntax` owns
severity, semantic error codes, definition context, optional offsets/ranges
and message text. Definition context can prefix a message or supply its source
owner when the established message already names that definition.

`Diagnostic.Render` resolves those fields against a source/definition context
and returns an opaque located diagnostic before rendering CLI text. Explicit
ranges and statement offsets have priority. For unmarked expressions, the
existing token/definition fallback remains display recovery; it is not fed
back into inference as checking evidence. Unknown source ownership remains
unlocated. Invalid coordinates do not resolve outside the source, and literal
marker-looking message text cannot forge a location or owner.

`Frontend.Diagnostics` retains source definition/eval anchor collection and
its compatibility adapter. Old string APIs can still project `in NAME:` and
`@OFF~` spellings at that boundary. Structured producers/renderers do not
inspect message prose for those fields.

## Actual checking products

`Infer.State.iErrs` stores diagnostics. Expression checking records its current
definition and source point; deferred operator/layout sites retain both, even
when full typed-Core evidence capture is disabled for Sol. Clause/eval/final
signature context updates modify data fields. `InferenceResult` exposes the
diagnostic list, while `inferenceErrors` and older tuple APIs are explicit
legacy-format projections. Native compilation and Sol use the structured
reader. Checking evidence, elaboration facts and typed Core expressions now
also carry `SourceOffset` rather than an untyped integer.

This repairs a lost-context error. In a block containing `value = "a" % "b"`,
the old delayed resolver printed only `(%) is not defined for String`.
It now reports the owning function and the actual statement point in native
compilation, Sol and qualified native imports. Safety errors also gain source
locations without changing their established message body.

`SafetyResult` couples structured safety/measure refusals and signature
suggestions. Measure errors are constructed with their owner where the
obligation fails. `LinearityResult` couples diagnostics with the final table
of unrestricted-variable requirements; its constructor is private.

`Ownership.Finding` distinguishes `RequireUnrestricted variable` from
`Violation sourcePoint message`. Shape operations and the linearity checker
use those constructors; they no longer discover obligations through hidden
control characters in strings. Parser marks attach points to violations,
without converting type-variable obligations into errors. Old shape helper
APIs still have explicit string projections for compatibility.

## Complete the ownership fixpoint

The former linearity driver stopped after 64 rounds even if the obligation
table still changed. A chain of 90 generic wrappers around a duplicating
function therefore lost the unrestricted requirement before an owned call.
The saved `355ccb0` compiler accepts the source counterexample; the revised
compiler rejects the owned call at its source position.

The driver now computes the actual fixpoint. Each round unions requirements
into a canonical table over the program's finite functions and shape
variables, so strict growth terminates. The regression checks the requirement
on every wrapper and the final owned-call refusal in native compilation and
Sol. This intentionally rejects an unsafe program that the old cap admitted;
it does not change generated instructions for valid programs.

## Compatibility and remaining work

The parser's cached `SMark Int` representation is unchanged. Existing parser
marks become typed source points when consumed by checking; this stage does
not claim that every surface node retains a complete range. Generated source
origins, imported Sol source context and remaining path/precondition/struct
diagnostic producers still need migration. Some compatibility callers still
use the string adapter. Structured checking errors do not by themselves prove
that closure lifting, optimization, workers or region helpers preserve typed
Core evidence across the current erasure seam.

Codegen revision **106**, generated-unit keys, parser Binary formats and native
physical ABIs remain unchanged. Sol's existing executable-identity cache key
invalidates previous prepared results after the compiler changes. Source error
locations improve intentionally, and long ownership chains are checked fully.

## Validation

`tests/Diagnostics.hs` checks actual inference/safety/measure/linearity
products, stable codes and owners, statement points, Unicode character offsets,
explicit ranges, literal metadata, compatibility projections, typed
unrestricted obligations and propagation through the 90-wrapper chain.
`tests/check_diagnostics.py` verifies native/Sol CLI positions, native imported
module ownership, safety locations and long-chain refusals. The saved compiler
independently reproduces both the unlocated delayed error and acceptance of
the owned-chain counterexample.

All **128** fresh root/dependent-unit emission and key comparisons pass against
the saved pre-frontend baseline with only the earlier explicit g106/g105
revision normalization. This diagnostic stage needs no additional instruction
or unit-key normalization. Full Base passed **136 jobs in 435.56 seconds on six
workers**, with no reused CI coverage, on the frozen final compiler tree.
Existing host/toolchain-dependent subchecks retain their explicit skips. Sol
argument/shared-language fixtures and 3,000,000-iteration self/mutual tail calls
passed (peak 86 MB). Hosted validation follows the push of this stage.
Local records: `/private/tmp/fpr-diagnostics-{build,focused-final,parity,base}.log`,
`/private/tmp/fpr-diagnostics-base.json`,
`/private/tmp/fpr-diagnostics-sol-{args,both,tail}.log` and
`/private/tmp/fpr-diagnostics-probe/long-ownership-{before,after}.log`.

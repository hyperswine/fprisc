# Typed recursive local functions

Date: 2026-10-25. Kind: implementation and validation record.
Applies after typed closure/join conversion at `e0a5d8d`.

The checked source-to-Core path now preserves recursive local functions as
typed bindings through layout planning and closure conversion. A captured
recursive accumulator that inference previously accepted but native lowering
refused as the unknown primitive `$localVector.loop.*` now executes correctly.
The saved preceding compiler reproduces that refusal; the new compiler prints
`recursive local 21` for three additions of captured value 7.

## Binding and closure contracts

`Core.Typed.Syntax.LetRec` scopes one binder over both its function initializer
and continuation. Its scheme, source identity and ownership shape come from
the existing checked inference evidence; no rewritten Core is re-inferred.
Named parameters and direct lambda initializers are supported. `lambdaView`
recognizes a nonempty lambda beneath source notes, preserving their typed
location/origin annotations during conversion.

The verifier checks initialization by a function, scheme/type agreement,
recursive lexical scope, initializer annotations and continuation result type.
Ordinary `Let` retains its nonrecursive scope. Raw erasure refuses `LetRec`:
closure conversion must remove it, and `verifyClosed` checks that invariant.

`Core.Typed.Close` gives the recursive function a code identity and fresh
capture parameters. In its body, a reference to the source self identity
becomes that same code applied to those captures. Self is never captured from
an uninitialized local value and no cyclic heap closure is constructed.
Substitution precedes nested closure conversion, so a nested lambda that uses
self captures the required lexical environment. Nested recursive locals use
the same explicit code/capture contracts. The outer continuation receives an
ordinary initialized closure binding with its original checked scheme.

Free-use discovery, binder enumeration and identity cloning handle `LetRec`.
Record-update layout branches can therefore clone recursive bindings with
fresh introduced identities before closing them, retaining free outer
references. Names remain presentation: a shadowed local with the same spelling
is a different identity and cannot become a recursive reference accidentally.

## Compatibility and validation

This extends native handling of already-checked source functions, advancing
the codegen cache revision from **107 to 108**. Physical native ABIs, source
parser Binary formats and runtime memory/context-switch structures are
unchanged. The captured-recursion fixture fails native lowering with the saved
`e0a5d8d` compiler and succeeds with the new compiler.

`tests/TypedCore.hs` requires the new functions to take the checked path and
checks closed products, independent evaluator answers, recursive scope versus
ordinary-let scope, initializer signature mismatch and strict value-cycle
refusals. Cases cover captured and capture-free recursion, source notes around
a lambda initializer, self inside nested lambdas, escaping/partial function
values, polymorphic local use, nested recursive functions and shadowing.

`tests/typed_core/recursive_locals.fpr` executes on one and four harts, including
recursive bindings cloned inside two record-update layout alternatives. Its
fixed answer is:

```
recursive-locals 21 7 23 29 21 31 37 41 3 43 47 53
```

The same fixture emits native code through x64, RV32 and RV64 selectors in the
focused check. Those checks validate emission; execution evidence here is
host-native AArch64. Sol argument/shared-language and bounded-tail checks pass:
3,000,000 self/mutual iterations, peak 86 MB, TailCall without a following Ret.

All 128 fresh root/dependent-unit assembly comparisons against the saved
`e0a5d8d` compiler pass. The matrix covers eight targets (RV32/RV64, A64/x64
ELF/Mach-O, qa64/qx64), scalar/float/vector/record fixtures, worker/reuse-off
variants and fusion-off variants. Only the exact `-g107`/`-g108` cache revision
marker and its symbol-escaped spelling are normalized. `.abirev` sidecars are
checked separately for 107 and 108. Existing emitted instructions, private
names and capture order otherwise remain byte-identical in that matrix.

All **136 Base jobs passed in 467.51 seconds on six workers**, with no reused
CI coverage. Compiler sources stayed frozen during the full run. Existing
platform/toolchain-dependent skips remain explicit; no physical-board result
is claimed. The preceding `e0a5d8d` hosted run has passed its Linux direct
backend step and reached RISC-V validation; this stage still requires hosted
validation of the integrated head after push. Local records:
`/private/tmp/fpr-recursive-build.log`,
`/private/tmp/fpr-recursive-focused.log`,
`/private/tmp/fpr-recursion-{before,after}.log`,
`/private/tmp/fpr-recursive-base.{log,json}`,
`/private/tmp/fpr-recursive-parity{.log,/results.json}` and
`/private/tmp/fpr-recursive-sol-{args,both,tail}.log`.

## Remaining cleanup

Hidden vector/layout parameters, computed recursive initializers beyond a
direct lambda, generated reference wrappers/holes and specialization evidence
remain explicit source migration work. Strict recursive values do not acquire
lazy knot-tying semantics from this pass. Generated layout temporaries and
optimization/workers/reuse/region passes still cross the erasure boundary.
Structured source ranges and remaining codegen/call-convention contracts also
remain required by the [full cleanup goal](2026-10-25-COMPILER-CLEANUP.md).

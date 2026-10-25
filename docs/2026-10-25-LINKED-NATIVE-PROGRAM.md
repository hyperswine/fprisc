# Linked native program ownership

Date: 2026-10-25. Kind: implemented architecture stage and validation record.
Applies to main `69975b1` plus this stage. The full
[compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) remains active.

## Native artifact boundary

`Compiler.Native.Linked` owns the linked input to native code generation.
A `NativeArtifact` retains its opaque `NativeCore`, artifact identity, exports
and constructor elisions. `LinkedProgram` retains those artifacts and a symbol
catalog. The real driver builds and validates this product before writing or
reusing any native unit assembly; root emission, imported specialization inputs
and unit emission consume projections from the same retained artifact objects.

Source symbols retain their checked calling schemes and physical parameter
counts. Private typed entries retain their source owner, `CodeId` and complete
capture/argument/result `CodeContract`. Compatibility definitions retain their
actual erased physical arity without acquiring an invented type contract; their
source causes remain in the artifact's `NativeCore`.

Exported symbols have image-wide identity. Private spellings have identity
within their artifact. Separate object files may therefore use the same local
spelling without silently losing one definition to a flat left-biased map.
Typed binder identities remain unique across the emitted typed definitions.

## Boundary invariants

Artifact construction checks that exports are emitted and that elisions apply
only to generated constructor entries. The frontend now publishes the exact
set of constructor definitions it generated, and native lowering retains that
set. Merely having a constructor layout is insufficient authority to suppress a
same-named source value.

Linking rejects duplicate artifact identities, duplicate exported symbol owners,
shared typed binder identities, inconsistent checking namespaces/layouts and
constructor elisions without an exported home. Typed cross-artifact references
must reach exported definitions and agree with their checked published schemes
and physical arities. A function returning a function remains physically
curried; counting logical arrows cannot satisfy the arity check.

The existing per-program verifier checks reference occurrences and their exact
source recursive-assumption permissions before this boundary. Linking compares
published provider/import interfaces, without promoting provisional signed-SCC
assumptions into proofs of ABI type equality. Unknown runtime/foreign globals
remain external. Compatibility bodies remain explicitly outside the typed
reference checks.

Private typed code currently remains within its home artifact. Importing a
private code contract requires a future explicit declaration and object-visibility
contract; this stage does not copy private bodies into a typed importer or export
private closures implicitly.

## Behavior and next boundary

This stage changes compiler ownership and checks, with no intended assembly,
public native ABI, runtime/context layout, source Binary, unit-cache format or
codegen revision change. The codegen revision remains 116.

The driver still passes erased projections to `ReceiveTurns`, `Mono`, inlining
and later legacy transformations. These results are not described as typed
transformation products. Global/imported callback specialization and `Mono`
retirement still require explicit imported private-code declarations, stable
closure/PAP identity and preserved region/cost provenance. Remaining source
compatibility forms, later typed passes, source diagnostics and machine/call
contracts remain part of the full cleanup goal.

## Validation

All 136 Base jobs passed in 589.73 seconds on five workers with a fresh
cache, no reused CI coverage and fixed compiler/test sources. One worker was
reserved for the emission comparison. The suite retains its explicit
platform/toolchain skips; in particular, x64 execution is skipped on this Mac.
Native AArch64 execution and the registered RV32/RV64 QEMU gates passed.

Expanded `TypedProgram.hs` checks cover linked owner/contract lookup, independent
machine-IR execution across artifact projections, duplicate artifact/export and
binder refusals, missing constructor homes, private imports, mismatched
namespaces/layouts, absent exports, constructor/source-value shadowing,
provider/import scheme disagreements and flat-versus-curried physical arities.
A public spelling can coexist with the same local spelling in another artifact.
The full native suite covers imported caches, callable identities/effect order,
region modes, shared prelude units and one/four-hart execution.

All 128 fresh saved/new emission cases matched byte for byte, including root
assembly, dependent-unit assembly and unit cache keys, without normalization.
The final comparison used immutable snapshots of both compiler binaries; the
final snapshot matches the binary used by Base. Sol arguments and the
shared-language fixture passed, as did self/mutual 3,000,000-iteration tail calls
with an 85 MB peak and a TailCall-ending bytecode listing.

Local records: `/private/tmp/fpr-linked-base.{log,json}`,
`/private/tmp/fpr-linked-final-parity.log`, `/private/tmp/fpr-linked-contracts.log`,
`/private/tmp/fpr-linked-units.log` and `/private/tmp/fpr-linked-sol-*.log`.
Hosted validation for the integrated commit follows the push; no physical board
execution is claimed.

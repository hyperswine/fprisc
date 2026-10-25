# Checked global callback cloning

Date: 2026-10-26. Kind: compiler architecture stage and validation record.
Applies to main `bd2830b` plus this stage. Codegen revision 119.
The full [compiler cleanup goal](2026-10-25-COMPILER-CLEANUP.md) remains active.

## Typed templates before regions and erasure

Global callback specialization now consumes checked closed source bodies,
including bodies supplied by linked modules. The driver closes artifacts with
callbacks preserved, verifies their linked ownership/interfaces, specializes
the checked graph, then verifies the new linked graph before region placement
and erasure. The standalone typed pipeline can specialize a complete checked
program through the same transformation.

`Core.Typed.Callback.Catalog` owns a snapshot of checked source/private
templates, their home owners, complete code contracts, schemas and callback-role
analysis. The analysis is shared across the callers in a program view. Template
cloning instantiates checked annotations and generates new binder identities;
it never re-infers a type from erased Core. Physical hidden layout arguments
remain arguments, and function-valued results retain their own arrows.

The catalog also shares its complete type-variable, binder-ID and spelling
inventories. An opaque verified `CodeLibrary` derives owned declarations once;
callers attach that snapshot instead of repeatedly checking/generalizing all
providers. The large POS compilation exposed that repeated work as a timeout
during integration; validation retains its existing time limits.

Program-owned schema maps replace repeated function-level unions. Opaque
`ClosedFunction`/`ClosedProgram` producers verify their changed graphs; consumers
reuse that proof and check their own new relationships. Native replacement uses
the owned symbol inventory instead of erasing the old graph a second time just
to recover its keys. The changed graph and each erased function remain checked.
A separate-cache compile probe on `examples/ideal/todo.fpr` measured 12.14 s for
the saved revision-118 compiler, 38.54 s for the initial global implementation,
and 12.78 s after fixing the repeated work. This is a compile-regression probe,
not a statistical kernel-performance claim.

The typed callback machinery preserves the callback object wherever it is
returned, compared, stored or captured. It removes only proven
forwarding/invocation-only object parameters. Argument/capture effects retain
their evaluation order, and private arity/depth/size limits restore original
calls rather than publishing malformed clones. Source recursive assumptions
keep their existing checked/reinstantiated identity ledger.

## Imported code stays at home

`ClosedFunction` distinguishes owned private definitions from imported code
declarations. Declarations come from verified closed providers. A source clone
may refer to the original private closure and its PAP, without copying their
definitions into the caller. The linked verifier compares an imported contract
with the actual emitting home's complete contract, including capture schemes,
ownership shapes and quantified identities. Owned-code discovery does not
mistake imported declarations for definitions.

Contract generalization propagates ambient rigid variables through imported
code references as well as locally owned code. An import cannot accidentally
turn a captured or global monomorphic type variable into a new quantifier.
Only declarations referenced by the transformed graph survive publication.

The full sweep exposed a separate producer bug: generated generic equality
calls used monomorphic occurrence schemes. A forwarding map-equality clone then
mistook its generic key variable for ambient rigid state. Generated calls now
retain a checked source/constructor scheme when available, or explicitly
quantify a checked intrinsic instance. Unknown/user calls retain their original
evidence. The fix is covered by generic Int/Bool forwarding checks and the
live-writer dependency graph that first exposed the mismatch. Code-call
diagnostics now identify the target contract, capture schemes and occurrence.

## Source and parameter provenance

Each typed clone retains its source owner, template code identity and ordered
mapping from original physical parameters/captures to surviving clone binders.
An omitted callback object has an explicit absent target in that mapping;
additional specialized capture/leading-argument binders remain checked members
of the clone's actual interface. Verification checks the template/source mapping
and that surviving parameter identities belong to the generated entry.

The region interface carries this origin alongside actual checked physical
binders, ownership shapes and result types. Costs still come from the actual
transformed analysis projection, not from a source name after specialization.

## Remaining erased transformations

The driver restricts `Mono` to compatibility definitions and helpers introduced
by the remaining erased region rewrite. Checked source/private targets have
already been specialized and cannot be cloned again by that fallback.
`Mono` still has live users; this stage does not retire it. Typed region helper
bodies and their existential receive-step protocol are the next requirement.
Inlining/fusion/workers/reuse and the other remaining table entries also remain
part of the full cleanup goal.

Revision 119 versions specialization, emission and cache changes. Source AST
Binary identity, runtime structures and physical native ABIs are unchanged.

## Validation

The final fixed-source, empty-cache `check_base.py -j 6 --times` run passed all
136 jobs in 540.74 seconds on six workers, with no reused configurations and
unchanged test timeouts. The preceding region stage took 509.31 seconds under
the same worker count. The integrated run includes:

- Linked source/physical-parameter provenance, imported ambient rigidity,
  changed-home contract refusals and malformed clone-identity refusals.
- Generic forwarded equality at Int and Bool, plus the live-writer dependency
  graph that exposed the generated-intrinsic scheme bug.
- Native/Sol specialization differential checks, strict effects/panics, warm
  mode caches and the existing 64,000-to-zero callback allocation fixture.
  The emission oracle explicitly requires typed clone labels on all targets.
- Native one/four-hart callback, capture-free/captured/alias identity and
  private home/PAP linkage checks, import cache independence, typed-Core
  staging/trap/structure/layout checks, and available object assemblers.
- The POS application and independent numeric/contract oracles, AArch64 native
  execution and the registered RV32/RV64 QEMU gates.

The suite skips native Linux x64 execution on this macOS host and the POSIX RV64
artifact check when clang lacks its RISC-V backend; shared IR/emission checks
pass. No physical-board execution is claimed.

Sol argument preservation and the shared-language fixture also pass. Self and
mutual tail calls complete three million iterations with an 85 MB reported
peak and the expected terminal `TailCall` bytecode.

Local records are `/private/tmp/fpr-globals-complete.{log,json}`,
`/private/tmp/fpr-globals-program-unit.log`, the `fpr-globals-sol-*.log` files,
and the separate-cache compile probes described above. Initial failed
integration runs are superseded by the complete fixed-source run, not counted
as passing coverage.

The preceding region-interface commit `bd2830b` passed
[hosted CI run 40205756522](https://github.com/hyperswine/fprisc/actions/runs/40205756522);
that result does not substitute for this stage's own hosted run. The integrated
global-cloning commit `134a992` subsequently passed
[hosted CI run 40210518302](https://github.com/hyperswine/fprisc/actions/runs/40210518302).

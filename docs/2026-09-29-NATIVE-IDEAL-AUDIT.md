# Native language architecture against the original ideal

Date: 2026-09-29. Status: source-grounded assessment, not a new language contract.
Source revision: `cb71302adf0f023949b5b382574094183d47b251`.

The intended native language is relatively minimal, strict and functional: no
tracing GC or heap closures, lambda lifting and reference counting, actors as
the concurrency model, bulk Vector computation, SoA, SIMD and stream fusion,
and inexpensive calls into C and device code. Sol's hosted VM/bytecode profile
may have a richer runtime.

The implementation substantially matches this direction, but its strongest
pieces currently live in different profiles. The ordinary native runtime has
actors and vectors with pool/message ownership; Builtin has first-order automatic
ARC and the raw C boundary. They are not yet one consistent execution model.

## Current implementation

| Intended property | Current source | Assessment |
|---|---|---|
| Strict evaluation | `compiler/Codegen.hs`, `stageArgs` and generic application | Arguments are evaluated left to right before calls. |
| Lambda lifting | `compiler/FPRISC.hs`, lambda lifting and `liftFix` | Captures become additional parameters of top-level functions. |
| No runtime closures | `runtime/fpr.h`, `pap_t`; `runtime/runtime.c`, `fpr_apply` and `fpr_applyN` | Partial applications can allocate code-plus-argument objects. These are effectively captured function environments despite lifting. |
| No tracing GC | `runtime/runtime.c` | No tracing collector found in the native runtime reviewed. Pools and message-root RC provide reclamation. This does not imply automatic per-value RC. |
| Automatic reference counting | `compiler/Arc.hs`; `compiler/Compile.hs` profile gates | First-order retain/release lowering exists, restricted to scalar RV64 Builtin. Indirect calls and partial applications are rejected. |
| Actor concurrency | `runtime/actors.c`, `fpr_acb`, scheduler, fuel checks | ACBs contain execution context, stack, mailbox state, allocation pool and scheduler links. Workers multiplex actors with affinity and donation/stealing. |
| Thread/hardware-backed workers | `machine/unix/main.c`, `machine/virt/crt0.S` | Hosted workers use pthreads; bare-metal secondary harts enter the runtime scheduler. |
| Bulk vector computation | `runtime/vec.c`; `compiler/Codegen.hs`, `vecSpec` | Linear vectors, bulk kernels and specialized map/filter/fold loops exist. General Vec operations do not automatically partition work among actors. |
| SoA | `runtime/vec_layout.h`, `runtime/vec.c` | Contiguous unboxed columns, up to eight product fields, boxed fallback and explicit float layouts. |
| SIMD | `compiler/Codegen.hs`; `runtime/vec.c` numeric tier | Selected integer RVV loops; C kernels intended for host autovectorization. Compiler column specialization is scalar on AArch64 and disabled on x86-64. |
| Fusion | `compiler/Codegen.hs`, `fuseVecFix`, `vecSpec` | Eligible map chains and scalar-integer write-back map/fold fusion. Not a general stream optimizer. |
| Native/C calls | `compiler/Codegen.hs`, known calls; Builtin library/export path | Native assembly, direct saturated calls and tail transfers. Generic values still use the runtime ABI; plain C exports are restricted to the Builtin ARC/raw boundary. |

## Architectural gaps

### Ownership is split

Ordinary native allocations belong to actor pools. Actor death or an explicit
reset reclaims a pool; message roots have RC and escaped slabs can outlive their
owners. `std/actor.fpr` offers `boundary` and `tidy` to preserve state through a
message copy before resetting a long-lived actor's pool. Such boundaries carry
an unsafe lifetime contract. They are not equivalent to compiler-inserted release
of every dead local value.

The Builtin ARC pass is a separate first-order execution path. Unifying local
values, actor state, message transfer, shared values and vector buffers under an
explicit ownership contract is the largest remaining design task.

### Lifting does not eliminate captured function objects

A lifted function with unbound remaining arguments can still become a heap PAP.
To promise no heap closures, the native compiler must specialize or reject
remaining captured function values. Capture-free code pointers and statically
specialized higher-order functions need not be forbidden.

### Vector layout and optimization are not fully expressed in types

`compiler/Infer.hs` defines an opaque `Vector`, not `Vector a`. In particular,
the runtime documents width-preserving float maps as a caller contract because
the type system cannot enforce the element type. Generic mapping can rebuild
rows and allocate replacement storage; specialized loops can operate in place
without per-element boxing or generic apply. These have very different costs.

Parameterizing vectors by element type and deriving layout information would
make optimization admission and rejection more reliable. Actor-backed parallel
vector operations also need ownership partitioning, transfer and joining rules;
SoA storage alone does not supply those rules.

### Actor machinery is close, but is not runtime-free

The actor design matches the desired ACB/worker architecture. Host watcher and
job helper threads are implementation machinery behind this model. Scheduling
is cooperative through compiler fuel checks and explicit blocking/yielding;
arbitrary foreign calls still need bounded or integrated blocking behavior.
Actor handles are currently typed as `Int`, messages are unconstrained by a
protocol type, and dead ACBs retain storage for stale-handle checks.

### Native interoperability has more than one boundary

Ordinary native functions use tagged/runtime values and runtime-aware C
adapters. Known saturated calls are direct; general applications use apply
helpers. Builtin library exports support raw C boundary types, with conversion
wrappers where needed and restrictions on managed values crossing the boundary.
`tests/builtin_export.fpr` and `tests/builtin_export_probe.c` define coverage,
but those tests were not freshly executed for this audit.

## Verification on 2026-09-29

The compiler was rebuilt with `make fpr`. Temporary native executables were
built with `fpr build` and run on the development AArch64 Mac with
`FPR_HARTS=2`; a temporary `XDG_CACHE_HOME` kept build caches isolated.

| Program | Fresh result |
|---|---|
| `tests/actors.fpr` | Built and ran, exit 0. |
| `tests/vecfuse2.fpr` | Built and ran, all five chain/write-back assertions passed. |
| `tests/matvec.fpr` | Built and ran, specialized/reference results agreed; reported specialized loop execution with heap delta 0. |
| `tests/fvec2.fpr` | Compilation failed: `A64: unmapped register s10`, from `compiler/A64.hs:106`. |

These checks do not establish benchmark performance, RVV hardware behavior,
full backend parity, or complete ownership correctness. Older comments and
test messages are not authoritative where current source differs.

## Suggested sequence

1. Define and unify the native ownership contract.
2. Specify whether captured PAPs are permitted; specialize or reject them to
   enforce a strict no-heap-closure native profile.
3. Strengthen vector element types and actor protocol types.
4. Repair backend gaps and establish portable scalar/SIMD vector lowering.
5. Implement parallel vector schemes on the existing actor workers, with
   explicit partition/transfer/join ownership and cost contracts.

See also the [tooling and meta-semantics audit](2026-09-29-TOOLING-SEMANTICS-AUDIT.md) for module identity,
typing, termination, resource contracts and the hosted optimization tiers.


## 2026-09-30 follow-up pointer

The [operator-resolution follow-up](2026-09-29-TOOLING-SEMANTICS-AUDIT.md#2026-09-30-follow-up-operators-and-compile-time-profiles)
examines row-based signatures, compile-time overload selection, mixed operand
types, ambiguity and the remaining runtime dictionary fallback, with fresh native
probes. It refines the static-dispatch boundary without changing this dated audit.

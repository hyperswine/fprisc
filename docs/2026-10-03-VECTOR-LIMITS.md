# Vector layout and kernel limits: follow-up implementation

Date: 2026-10-03. Kind: implementation record. Follows
[VECTOR-AUDIT](2026-10-03-VECTOR-AUDIT.md),
[VECTOR-DESCRIPTORS](2026-10-03-VECTOR-DESCRIPTORS.md) and
[VECTOR-KERNELS](2026-10-03-VECTOR-KERNELS.md).

This removes several remaining construction and scalar-kernel restrictions.
It does not complete the audit's pipeline, portable SIMD or Matrix work.

## Generic construction without manual layout strings

Native helpers such as `build x = Vec.push x (Vec.new Unit)` now work at
integer, float and boxed element types. The checker infers hidden layout
parameters and supplies their evidence at references. Requirements propagate
through wrappers and recursive calls, including local named functions,
lambda bindings and imported modules. `Vec.fromList` and type-changing
`Vec.map` use the same mechanism. Existing-vector operations keep their
representation-preserving path.

The source API remains `Vector a`; callers do not write layout strings.
An allocation whose element type cannot be established from a concrete
entry point or a caller is refused as ambiguous. Floating values inside
opaque containers such as a list field remain unsupported: a product
recipe cannot make raw float bits into ordinary boxed values.

## Nested float products

Finite nested tuples and closed records, including singleton records, can
store their float leaves in raw columns. A preorder product recipe records
the identities needed to reconstruct a row. Integer and float leaves are
unboxed; ordinary nonnumeric fields retain boxed columns. Nonfloat nested
fields retain their existing boxed representation.

Push, update, reads, map, filter, duplication, actor-message copying and
`keep` copy the recipe with the column descriptor. Generic callbacks still
reconstruct nested rows; this is representation support, not a nested-row
unboxed callback kernel.

Unsafe mailbox receive needs a declared protocol type to retain float
information. The fixture declares `receiveR : unsafe Int -> Vector R`;
the runtime cannot infer a raw float's type from its bits.

## Captured and wide folds

Integer scalar folds admit captured arithmetic callbacks. Integer record
folds admit captures and more than seven used columns. Arguments beyond
the eight register positions use the existing per-hart argument cells;
the shared ABI still has a 64-argument ceiling. Capture and accumulator
guards preserve the ordinary runtime fallback for other representations.

Mixed float record folds, floating captured arithmetic and record-valued
accumulators retain the correct generic implementation. Their optimized
plans need per-argument kinds rather than guessed accumulator semantics.

## Type-changing scalar maps

A known callback over scalar input can now use a direct-call kernel for
`Vec.mapAs`, preserving the inferred output layout. Captures remain tagged;
the ordinary callback ABI handles integer, float and boxed scalar inputs.
This removes per-element PAP application, but still pushes each output
through the runtime and may allocate output objects. Record inputs and
nonliteral layout evidence use the generic implementation. This is not yet
a fully unboxed arbitrary type-changing column kernel.

The kernel retains eager visitation and failure order. A callback that
prints for elements 0 and 1 and fails on 2 must never visit 3.

## x64 scalar kernels

x64 now enables the shared scalar vector kernels. The extra IR saved
registers use XMM2–7 as a shadow bank, with balanced instruction-local
borrowing of physical registers and bank preservation around calls.
These are scalar loops, not SIMD kernels.

The execution test uses generated kernels with only platform symbol and
test TLS linkage adapted. Independent C references cover lengths 0–99,
nine-column maps and filters, and a captured nine-column fold. Fuel and
allocation callbacks deliberately overwrite the shadow-bank registers.

## Verification and compatibility

`tests/check_vector_limits.py` exercises generic/local/imported/recursive
construction, nested and singleton float records, copying and retention,
captured folds, empty inputs and exact map failure order. It compares
native execution with the inliner and higher-order specialization enabled
and disabled on one and four harts. It also emits RV64, A64 and x64 code and assembles x64; RV32 emission
uses an integer-only captured wide-fold fixture. RV32 F64 does not fit the
current word-sized value representation and is not enabled by this work.

`tests/check_x64_vectors.py` runs generated x64 kernels on native x64 or
Rosetta; it reports a skip when neither is available. Both suites are part
of `tests/check_base.py`. Existing typed-vector refusals remain covered.

On the development Apple Silicon Mac, the full Base and standard-library
suites, case/signature/measure refusals, resource-bound checks and
specialization differential checks passed. x64 kernels executed under
Rosetta. One concurrent Base rerun failed the existing cleanup fixture's
10 ms wait; that fixture passed 80 isolated repetitions and the subsequent
full Base run passed. No RV32/RV64 hardware execution was performed here.

The vector header appends recipe metadata, preserving existing field
offsets but increasing its size. Hidden evidence changes generated helper
arities, including module export tables. Codegen revision 33 and x64
revision 8 invalidate compiled-unit caches. Rebuild runtime and application
images together; old and new runtime objects must not be mixed. QOS's
compiler pin has not been changed by this implementation.

Remaining audit work includes per-argument typed kernel plans, legal
map/filter/fold pipeline fusion, A64/x64 SIMD, broader RVV coverage,
compact F32 storage, generic Matrix/direct bulk builders and compute
examples. No target hardware performance or WCET claim follows from these
semantic and backend checks.

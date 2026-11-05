# Checked builtin scalar-product values

Codegen 171 / arcRev 19 connects the private product convention to checked
builtin representation evidence. A complete single-constructor product with
2–8 immediate fields can travel through private calls, local bindings and
branch joins without allocating its nominal constructor. This is separate
from its heap representation: storing the value in a list, crossing a generic
entry, printing it or exporting it still uses the established nominal box.

## Representation and calling contract

Eligibility comes from the complete instantiated checked definition, not the
first constructor or call that happens to be visited. Immediate fields include
Word, Addr, F64, F32, tagged Int/I32, Bool/Unit and eligible nested scalar
wrappers. String, unresolved/Uniform fields, boxed nested products, recursive
products and multiple variants do not qualify. Existing scalar-wrapper
selection and heap layout descriptors are unchanged.

The target's private result capacity bounds product width: AArch64/RV64 admit
up to eight words, x86-64 up to two, and unsupported native targets retain
boxed values. The execution evidence in this milestone is RV64 builtin;
AArch64/x86-64 register mechanisms have the preceding hosted evidence, not a
new builtin execution qualification.

Private product parameters expand into ordered scalar words. A function whose
expanded parameter list would exceed the existing 64-word internal limit keeps
one-word boxed parameters instead; entry unpacking copies every immediate
field before releasing that box. Private results use the existing verified
`$worker.retN` convention. Public entries, `main` and `machineInterrupt` retain
one-word result contracts. Public C exports continue to use the existing
Uniform adapters, including soft/hard floating-point ABI conversion. This is
not a new platform C aggregate ABI.

`$product.packN` and `$product.valueN` are compiler-private lowering forms.
They carry ordered words and branch joins after checked evidence has selected
the shape; their names cannot establish source-type eligibility. Lowering
handles nested lets, aliases, nullary calls and branches with a trapping arm.
A join has N scalar block parameters, not a temporary constructor cell.
These markers are absent from the external runtime contract and emitted calls.

Packets contain no owned heap references. A heap boundary materializes the
original constructor and exact raw-field descriptor. A product projected from
a heap object is retained before the parent is released; its fields are copied
before the product box is released. Generic/public boundaries retain the U1–U3
nominal conversion and graph ownership rules. Constructor fields and call
arguments still execute left to right, including fields unused by a consumer.

`FPR_NO_PAIR_RETURNS=1` disables this value ABI as well as the earlier hosted
return optimization. `FPR_NO_TYPE_SPEC=1` independently disables clone-based
specialization: complete checked monomorphic product evidence still applies.
Raw units and interrupt handlers retain their conservative pre-lowering
allocation checks. This milestone does not admit product construction there.

## Executed evidence

`python3 tests/check_builtin_products.py` executes generated RV64 programs in
QEMU, with ARC metadata checks enabled. The matrix combines both C and FP-RISC
allocators, soft/hard C float ABIs, default specialization, specialization
rollback, and product-ABI rollback. Inlining is disabled to retain the private
helper boundaries under test.

| 10,000-step loop | Constructor allocation requests | Result |
| --- | ---: | ---: |
| Boxed product rollback | 10,001 | 20,002 |
| Checked product values | 0 | 20,002 |
| Checked products, type-specialization rollback | 0 | 20,002 |
| Explicit scalar loop | 0 | 20,002 |

The counts are assertions against intercepted allocator requests, separate
from live-allocation checks. This is allocation evidence, not emulator timing
or a physical latency claim.

The suite also checks:

- Local and conditional products, nullary producers, nested scalar-wrapper
  fields, eight-field returns and the oversized-argument boxed fallback.
- Shared public values, generic identity, products stored in lists, nominal
  printing, nine-field fallback and owned String-field fallback.
- All mixed scalar field kinds across public boundaries, high Word/Addr bits,
  NaN payloads and signed zero, with the live-allocation count restored after
  every ownership cycle.
- Argument and constructor effects, unused-field division failure, both Int
  overflow endpoints, and selection of the live branch when the other traps.

All 39 Haskell test suites passed, including checked product evidence, parameter
expansion, target width admission, nested local bindings, branch joins and the
existing packet verifier/register-placement tests. The new execution suite is
registered in the normal checks and RISC-V CI group; this records local checks,
not a claim that remote CI has run.

## Regression and compiler-cost qualification

The strict typed ARC execution suite, scalar wrappers, Uniform aggregate
conversion, hidden fields, hosted product returns, RV64 result oracle and
legacy pair/actor suites passed on the same compiler. The registry tests
passed with 38 explicit CI configurations. No remote CI or new physical-board
execution is claimed.

The unchanged compiler budgets passed: hello 1.59 GB allocated, std-live
32.73 GB and pos1 70.33 GB. Std-live remains at +9.4% against its baseline,
close to its existing +10% ceiling. The [16–256-helper C2 cost record](../bench/2026-11-05-builtin-product-specialization-cost.json)
retains exact code-byte and function-count parity with explicit monomorphic
twins; compiler-allocation ratios are 0.999–1.000x. This checks the established
specialization workload; it is not a scaling benchmark for every new product
shape. The [allocation and validation record](../bench/2026-11-05-builtin-products.json)
identifies the matching compiler hash and the source test hash.

## Remaining scope

Owned-reference packets, nested multiword flattening, variant-specific product
storage, raw/interrupt admission, and open-row generic contracts remain open.
The broader Base representation path must retain its ownership and scheduling
contracts when these checked layouts are introduced. Scheduling latency and
physical peak-live/stack arena admission remain independent gates. In
particular, eliminating constructor requests says nothing by itself about
conversion scratch space, allocator metadata or a physical WCET bound.

## Follow-up: raw and interrupt admission

Codegen 172 adds two-stage allocation-free admission for checked scalar
products in raw units and interrupt helpers. The source proof is followed by
verification of actual physical arguments, result packets and absence of
materialization or heap projection. See [the contract and executed probes](2026-11-05-RAW-PRODUCTS.md).
The codegen-171 measurements above retain their original scope.

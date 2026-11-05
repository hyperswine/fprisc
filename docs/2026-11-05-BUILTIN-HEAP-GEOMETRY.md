# Builtin heap geometry for arena admission

The builtin allocator now exposes allocation-free, read-only physical geometry
queries. Heap initialization and allocation use the same checked arithmetic
as the queries, so an admission layer need not maintain a second copy of the
allocator's prefix, alignment and bitmap formulas. This is a physical-accounting
foundation, not yet compiler admission of allocating programs.

`fpr_builtin_heap_plan_range(start, end, out)` reports the aligned block range,
bitmap reservation, block prefix and smallest block. It refuses too-small or
overflowing ranges and configured-maximum violations. Refusal leaves the
output unchanged; planning neither initializes nor inspects the current heap.
The caller must still own mapped RAM at the proposed addresses.

`fpr_builtin_heap_request_size(bytes, out)` checks the allocator's existing
overflow limit and reports the **minimum** physical block size. Both ordinary
allocation and growing reallocation use its shared inline arithmetic. Zero
requests retain their existing nonempty allocation semantics. Shrinking a
block retains its previous capacity, and an unusable split tail belongs to
the allocated block: the query must not be interpreted as an exact peak-live
or reallocation bound.

| Physical obligation | RV32 | RV64 |
| --- | ---: | ---: |
| Block prefix, including the public object-size/RC metadata | 48 bytes | 80 bytes |
| Minimum payload | 16 bytes | 16 bytes |
| Minimum complete block | 64 bytes | 96 bytes |
| Maximum extra unsplittable tail on an ordinary allocation | 48 bytes | 80 bytes |

The live-start bitmap uses one bit per 16-byte slot in the aligned supplied
range, rounded up to 16 bytes. It lies outside the allocatable block range.
Global free-list/allocator state belongs to static sections and is not part
of this bitmap or per-object block budget.

## Independent execution evidence

The [geometry record](../bench/2026-11-05-builtin-heap-geometry.json) covers host
ASan/UBSan and RV32/RV64 QEMU execution. The fixture does not decode private
block headers or free lists. It compares query results with payload addresses,
physical live-byte counters, memory contents, guard bytes and actual failures.

- 16,384 alignment/short-range combinations check a separately written bitmap
  and alignment oracle. Address-space overflow, reversed ranges, configured
  maxima and unchanged outputs on refusal are covered.
- Every request size from 0 through 4,096 executes. Actual block strides and
  live-byte counts match the predicted minimum when splitting is possible.
  Planning while a payload is live preserves its contents and ownership.
- All possible aligned unsplittable tails up to the block prefix execute and
  count toward actual physical residency. Shrinking a 4,096-byte allocation
  to one byte demonstrably retains the larger block.
- The request sequence `0, 1, 16, 17, 31, 32, 33` has only 130 requested bytes
  but needs a **544-byte RV32 arena or 768-byte RV64 arena**, including bitmap
  and all seven simultaneously live blocks. Exact capacity succeeds and fully
  reclaims. A one-byte-short supplied range refuses the final request, preserves
  all six earlier payloads and leaves surrounding guards intact.

The existing heap regression suite also passes sanitizer, hostile-pointer,
reallocation, fragmentation, exact-layout/deep-release and configured 64 KiB/
8 MiB tests. Each XLEN executes all 21 explicit failure cases. Generated
ARC/raw ownership, exports and interrupt checks and the four target-image
build/preservation configurations are recorded in the
[validation manifest](../bench/2026-11-05-builtin-heap-geometry-validation.json).
The new geometry check is registered in Base and requires execution in the
RISC-V CI configuration; local execution is not a remote CI claim.

## Cost and qualification limits

The [controlled comparison](../bench/2026-11-05-builtin-heap-geometry-cost.json)
uses the same fixture and compiler flags for the baseline and revised heap,
with statistics/lookup counters disabled. Allocation plus iterative release
of 512, 2,048 and 8,192 list nodes has **identical guest instruction counts**
before and after, on both RV32 and RV64. An initial arithmetic refactor added
one instruction per allocation; the accepted shared helper preserves the
original arithmetic form and removes that regression. These QEMU `icount`
measurements do not establish physical cycles, wall-time performance or WCET;
initialization and printing are outside the measured interval.

Reproduce the comparison with:

```
python3 tools/bench_builtin_heap.py --baseline-ref 22e1e5537370f48ed1c7bd8f3435aa4a0b74836c --record /tmp/heap-cost.json
python3 tests/check_builtin_heap_geometry.py --require-execution
```

No compiler-generated-code/cache revision or cost baseline changed. Runtime
images are rebuilt with the revised C allocator. Compiler source cost equations
still lack authority over all lowered physical allocation sites, conversions,
reallocations and region scratch storage. The next admission layer must connect
verified request/count bounds to these actual target layouts, account for
peak-live storage/fragmentation, and enforce the resulting arena contract.
Runtime C stack, callback/startup/interrupt composition and reference-target
timing remain separate unfinished obligations. No new physical-board deployment
or hardware timing qualification was performed.

# Uniqueness tracking and private consuming workers

The next step after [fresh constructor reuse](2026-10-20-REUSE-AND-PIPELINE-ROADMAP.md)
lets a proven fresh allocation cross a helper call without allocating its
replacement. Code generation revision is **55**; the runtime ABI is unchanged.

```text
swap r = {left=r.right, right=r.left}
entry n = r={left=n, right=n+1}; alias=r; swap alias
```

`entry` can call a private consuming version of `swap`. The public `swap`
continues to borrow: `u=swap r; (r,u)` preserves the original `r`.
This also works with ordinary function inlining disabled.

## Proof and scope

`compiler/Reuse.hs` canonicalizes lexical aliases of a freshly allocated root.
A branch join can establish freshness when every returning branch constructs
the same type, variant and field count. Continuations are checked path by path.
A transfer in a let binding requires that no old root or alias is mentioned in
the following continuation. The result of a consuming call can become a new
unique root, allowing successive helper updates.

There are two separate proofs: a last-use transfer may feed an arbitrary
continuation, while propagating uniqueness requires that the expression returns
the original allocation. A scalar result after a transfer must never be
mistaken for an owned constructor. Core tests exercise this distinction.

One parameter per eligible helper receives a private `$worker.consume.*` entry.
The caller knows the constructor shape and proves the root cannot be reachable
through the other arguments. Other arguments may borrow projected children,
which cannot point back to a newly allocated immutable parent. Only saturated,
statically resolved calls in the same compilation unit select the private entry.
Ordinary entry points, function values, exported module interfaces and dynamic
calls retain their existing borrowing behavior. Private entries have no function
value descriptors and are emitted only when selected.

The helper may inspect the root's fields/tags and rebuild the same shape, or
fail. Every replacement field is evaluated in source order before any store.
The existing reuse emitter stages fields and performs the overwrite without an
intervening call. Entry fuel checks, stack checks and ordinary argument staging
remain in force.

Whole-value escape, retained aliases, closure/actor capture, unknown calls,
invalid projections, shadowed roots and mismatched shapes decline optimization.
The pass does not derive uniqueness from the last use of a borrowed parameter.

Bounds remain 1–64 constructor fields and 256 Core nodes per candidate body or
continuation; there are at most 128 candidate helpers per compilation unit and
at most 64 arguments per entry. This first consuming tier is nonrecursive.
It uses the existing `FPR_NO_REUSE=1` fallback, including its cache identity.
RV32, Builtin and ARC retain their previous paths. Recursive record-update loops,
general list traversal and ARC retain/drop integration remain future work.

## Validation

The complete `tests/check_base.py` suite passed with exit status 0. Its first
sandboxed attempt could not start a localhost listener; the host-access rerun
passed, including the live-writer lifetime checks.

- Core proof tests cover aliases, branch joins, escaped/retained roots, invalid
  projections, budgets, callee shadowing, argument aliasing and excluded units.
- Native differential execution covers inlining/register promotion on/off,
  reuse off/on/off, one/four harts, shared list tails, actor capture, ordered
  effects, failure before the second field, and allocation counts.
- A shared library containing a consuming worker is called by a host with reuse
  disabled; dynamic calls preserve retained inputs.
- A64/RV64/x64/RV32 emission checks verify worker selection and absence of private
  function descriptors. Builtin and ARC checks verify fallback.
- Pi 4 and STAR64 execute the same fixture with one/four harts and verify uploaded
  binary hashes. Their installed QOS services are left running.

The focused cost fixture constructs a fresh two-field record, calls `swap` with
ordinary inlining disabled, and reads the result. Across 10,000 iterations,
allocation requests fall from **20,000 to 10,000** and allocated bytes from
**960,000 to 480,000** on both boards.

One-million-iteration timings, medians of seven alternating-order samples:

| Board | Reuse off | Consuming entry | Less elapsed time |
|---|---:|---:|---:|
| Pi 4 | 622.841 ms | 362.393 ms | 41.8% |
| STAR64 | 362.830 ms | 221.691 ms | 38.9% |

These are allocation-instrumented microbenchmarks beside live services, with
unpinned CPU clocks. Allocation totals are not RSS, and these timings do not
establish an application-wide QOS speedup.

The [evidence JSON](evidence/2026-10-20-consuming-workers.json) records source
and executable hashes, correctness results, allocation ledgers, timing samples
and test cleanup.

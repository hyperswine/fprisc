# Shared scalar selection and arena admission

Codegen 182 closes a mismatch between native selection and heap analysis.
Builtin RV64 ARC already emitted pure Word, comparison and address operations
inline, but the resource checker saw their earlier foreign-call form and
refused them. Both stages now consume the same checked adapter description.
This expands admission without changing the selected instructions or adding
runtime checks. It is proof coverage, not a new runtime speedup.

## Contract

`Codegen.Target.RV.ScalarAdapters` recognizes 21 exact, saturated adapter
signatures: Word add/subtract/and/or/xor/not, Int/Word conversions, Word width,
Word/raw equality and inequality, signed Int comparisons, address conversion,
null, addition and equality. Word arithmetic wraps at 64 bits; conversion to
Int keeps the existing tagged 63-bit behavior. Address arithmetic manipulates
bits and does not grant permission to dereference an address.

A source name alone is insufficient. The callee must have the exact foreign
symbol, parameter count and word-value result/parameter signature. Heap facts
are collected only after successful builtin RV64 ARC native selection, with
fixed stacks and no scheduler fuel. Local, forged or incomplete callees do
not acquire this evidence. Normal and tail calls use the same description.
The controlled builder's audited dependency contract now also covers the RV64
selector and this shared module, binding resource facts to their implementation.

These selections neither allocate nor call a runtime slow path. Checked Int
arithmetic, guarded shifts/masks, memory access and CPU control remain outside
this description. A potentially failing path must acquire its own explicit
contract; it is never silently treated as allocation-free successful work.

## Execution and code parity

The [execution record](../bench/2026-11-05-scalar-admission.json) compares the
saved codegen-181 compiler with codegen 182 on the same source and options.
Instructions and data match exactly. The old heap gate refuses the source;
the new gate admits it, and enabling admission still leaves code unchanged.
Guarded shifting and overflowing Int addition continue to refuse admission.

The 76 RV64 QEMU cases compare actual results with independent Python bit
calculations: full-width Words, wraparound, conversions, both Int endpoints,
equality/comparison outcomes, null and wrapped address offsets. Each controlled
image checks complete heap reclamation and arena guards. Three loop cases also
execute with exactly their admitted heap and linked whole-activation stack:

| Loop iterations | Heap requests / requested bytes | Reserved heap | Linked stack limit |
| --- | ---: | ---: | ---: |
| 0 | 3 / 72 | 624 bytes | 368 bytes |
| 10,000 | 3 / 72 | 624 bytes | 368 bytes |
| 100,000 | 3 / 72 | 624 bytes | 368 bytes |

The loop body allocates nothing. The three requests are boundary conversion
costs, so iteration count does not increase storage demand. The resource proof
accepts zero-allocation cycles without assuming a bound on their iterations;
these successful executions do not prove termination for every argument.
The final stack gate includes the generated caller, allocator and reporting
paths as well as the callback. Its limit is a bound, not a traced high-water.

All 41 Haskell suites pass, including the independent allocation-graph oracle
and checked adapter identity/arity/refusal cases. Existing ARC/raw execution
checks pass, including 879 independent Word/Int calculations, every shift/bit
index, checked failures, public conversions, ownership and interrupt paths.
The unchanged compiler budgets pass at 1.59/32.68/68.97 GB allocated for
hello/std-live/pos1, with std-live peaking at 428 MB. The
[C2 cost record](../bench/2026-11-05-scalar-admission-cost.json) preserves exact
code-size/function-count parity through 256 helpers, at 1.000–1.001 times the
compiler allocation of explicit monomorphic twins. No baseline was relaxed.

The regression is registered in Base and requires execution in RISC-V CI.
The [validation manifest](../bench/2026-11-05-scalar-admission-validation.json)
binds the final compiler, sources and evidence. Registration does not imply a
remote CI run or physical-board proof.

## Remaining scope

The [controlled activation contract](2026-11-05-STATIC-ACTIVATION-ARENAS.md)
still applies: one fresh C-runtime arena, ordinary interrupts disabled, a
closed caller/link recipe and scalar boundary. Allocating loops, tighter live
storage, general conversion graphs, concurrent entries, resumable interrupts,
Base arenas and physical timing qualification remain unfinished. This milestone
makes useful nonallocating computational loops admissible while preserving
those boundaries.

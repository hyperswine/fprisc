# Persistent list storage for scalar constructors

Codegen 201 stores an eligible element's scalar fields in the list cell. A list of 1,000 wrapped integers and a list of 1,000 two-way variants each allocate 1,000 cells and 32,000 bytes, exactly matching the two explicit layouts. Codegen 199 allocated 2,000 objects and 64,000 bytes in both programs. Each list stays live across two reads. The results held with inlining enabled and disabled and with one and four workers. [Before](../bench/2026-11-05-base-persistent-storage-before.json) · [After](../bench/2026-11-05-base-persistent-storage-after.json)

## Where the compiler can use the layout

A hosted 64-bit Base producer must build a list of a known, closed scalar constructor type. All uses of the shared binding must agree on private readers. Checked constructor arities and the largest alternative determine the layout. A single-field wrapper uses the ordinary cons cell. For a product of up to eight scalar fields, or a variant with a discriminant and up to seven scalar fields, a private cell carries its physical width and constructor in the header. Smaller alternatives pad unused slots. The recursive tail remains a managed list. A producer evaluates strict operands at their original sites, preserving evaluation order and failure prefixes.

The compiler retains tagged entries for general use. If a shared binding is returned, captured, printed as a whole, sent to an actor or passed to an unknown consumer, that binding keeps the public layout for every reader. Mixed representations, stale plans, recursive element fields and oversized elements also fall back. Both the type-specialization and product-return rollback switches restore tagged storage. [Transformation](../compiler/Core/Opt/StoredLists.hs) · [Admission and semantic tests](../tests/check_base_stored_lists.py)

The runtime traverses the actual field count and tail when copying, retaining, inspecting or releasing private cells. A foreign-value fixture places a live managed string in a declared scalar slot and traverses 6,000 elements twice across an active region. A separate C fixture exercises shared graphs, 16,000-deep spines, dynamic Nil, actor copies, both cell modes and widths up to eight. The native ARM64 and x86-64 suites each passed 178 cases, and RV64 Linux userspace passed 72 under QEMU. The full Haskell run passed 41 suites. [Runtime fixture](../tests/base/stored_spine.c) · [Validation record](../bench/2026-11-05-storage-validation.json)

## Time, code size and compiler cost

Uninstrumented hosted times are medians of 13 alternating samples. Each workload builds 1,600 lists and reads each twice. Before and after use their respective runtime sources. The rollback column uses the current compiler and runtime with tagged storage. Instrumented allocation counters were collected separately. [Samples and disassembly hashes](../bench/2026-11-05-storage-throughput.json)

| Workload | Codegen 199 | Codegen 201 | Explicit | Rollback | 201 wins vs 199 | 201 wins vs rollback |
|---|---:|---:|---:|---:|---:|---:|
| Scalar wrapper | 25.75 ms | 24.14 ms | 23.79 ms | 22.74 ms | 10/13 | 6/13 |
| Variant | 25.80 ms | 25.17 ms | 24.04 ms | 25.84 ms | 8/13 | 7/13 |
| Ordinary integer-list copy control | 36.78 ms | 35.48 ms | 36.47 ms | 36.13 ms | 7/13 | — |

The first implementation lost time branching on the variant after evaluating the tail. Codegen 201 writes the already computed ordinal directly into the cell header. At equal allocation count and with the same runtime, the variant median fell from 22.01 ms to 20.14 ms and won all 13 pairs. Across the whole change, allocation removal is repeatable while elapsed-time gains depend on the workload. [Initial experiment](../bench/2026-11-05-storage-initial-throughput.json) · [Isolated header comparison](../bench/2026-11-05-storage-header-throughput.json)

Root RV64 text grew from 3,576 to 4,104 bytes for the scalar wrapper and from 3,960 to 4,840 for the variant. The ordinary control retained identical root code. With 256 eligible producer/reader pairs, the compiler emitted 256 private entries of each kind. Compilation allocated 5.53 GB and emitted 298,848 text bytes, compared with 4.41 GB and 164,876 bytes for explicit storage. The three absolute build-cost checks passed at 1.61, 32.90 and 67.63 GB. The standard-library fixture was 9.9% above its baseline against a 10% limit. [Scaling data](../bench/2026-11-05-storage-scaling.json) · [Build gates](../bench/2026-11-05-storage-validation.json)

## Physical scheduling and static admission

The Pi 4B running QOS passed 210 cases using a separately staged ARM64 Linux bundle. It confirmed exact allocation and byte counts and passed both watchdogs. Across nine route, worker and contention configurations, the 6,912 uninstrumented replies per mode had a median of 191 µs. Sampled p99 was 1,679 µs with private storage and 2,354 µs with rollback. The maxima were 3,031 and 3,957 µs, and 555 versus 757 replies exceeded 1 ms. The installed QOS desktop kept PID 17227 and recorded zero restarts. Main boot and memory qualification remains at codegen 197. These observations cover this Pi workload; general deadline admission remains open. The separate host suite passed 297 configurations. [Device telemetry](../bench/2026-11-05-storage-pi.json.gz) · [Host scheduling](../bench/2026-11-05-storage-scheduling.json)

The private storage operation is limited to the hosted profile. Adding the cell tag and changing the RV selector invalidated two source pins for the audited builtin heap contract. The codegen 199 and 201 builtin allocation fixture produced identical machine code, relocations, heap-demand reports and stack reports. Host, RV32 and RV64 allocator geometry, ARC ownership, cumulative heap bounds and linked-stack checks passed before refreshing those pins. Single-entry and finite sequential RV64 arena images then passed execution, tight-budget refusal and publication-preservation checks. Concurrent application lifetimes still require a separate admission proof. [Contract comparison](../bench/2026-11-05-storage-contract-recheck.json) · [Single entries](../bench/2026-11-05-storage-static-arena.json) · [Finite sequences](../bench/2026-11-05-storage-static-sequences.json)

## Next measured storage gap

A shared binary tree of 1,023 nodes stores a scalar variant in each branch. The current compiler allocates 2,046 objects and 81,840 bytes. The explicit version embeds the same variant in each branch and uses 1,023 objects and 49,104 bytes. Both produce the same independent result across both inlining settings and both worker counts. This isolates a general aggregate-field opportunity beyond list storage. A candidate should preserve shared recursive children, keep tagged public and foreign entries, and measure code growth as well as allocation parity. [Tree fixture and measurements](../bench/2026-11-05-base-tree-storage-before.json)

# Scalar fields in persistent Base aggregates

Codegen 202 embeds an eligible scalar wrapper or variant in its containing node. The shared binary tree of 1,023 nodes now uses 1,023 allocations and 49,104 bytes, matching the explicit tree. Codegen 201 needed 2,046 allocations and 81,840 bytes. The same tree is read twice. An independent recursive oracle checks its result with one and four workers and with inlining enabled and disabled. [Before](../bench/2026-11-05-base-tree-storage-before.json) · [After](../bench/2026-11-05-base-tree-storage-after.json)

## Admission and representation

The compiler looks for a closed, unrestricted nominal type with one payload-bearing constructor and zero or more nullary alternatives. Exactly one field in that constructor must have a known, closed scalar layout. The private producer stores the scalar fields, including a discriminant when needed, in an ordinary managed tuple of two to eight words. Nullary outer constructors keep their original representation. Recursive children remain managed values, including when both child positions refer to the same tree. Other fields keep their ordinary representations. A wrapped field can occur at any position in the constructor.

The private reader must establish the outer constructor before projecting its fields. Matching a nested constructor narrows the set of available fields. All uses of a shared binding must agree on the private layout. A capture, a public return, an unproved child, an unknown call using the tree or one of its private children, or a disagreeing reader sends that binding through the ordinary entry. Private callers may use the same function's public entry elsewhere. Constructor arguments retain strict evaluation order and named constructor calls preserve their entry fuel. The implementation extends the existing list producer/reader analysis and uses the current tuple allocator and walkers. [Layout evidence](../compiler/Core/Opt/ProductParameters.hs) · [Producer and reader transformation](../compiler/Core/Opt/StoredLists.hs)

## Execution and cost

Both native ARM64 and x86-64 passed 152 cases. They cover shared children, three-way variants with different widths, multiple empty outer constructors, a managed sibling, captures, actor sends, signed endpoints, and which output and failure occur first. A foreign fixture returns a live string in a declared integer field. A balanced tree retained and validated all 8,191 such values twice, producing 16,382 after a verified region close. RV64 Linux userspace passed 72 cases under QEMU. The 41 Haskell suites include wrong binders, undominated projections, unknown child producers, escaped fields and ordinary ABI retention. [Native](../bench/2026-11-05-tree-storage-native.json) · [x86-64](../bench/2026-11-05-tree-storage-x64.json) · [RV64](../bench/2026-11-05-tree-storage-rv64.json)

| 800 shared trees | Codegen 201 | Codegen 202 | Explicit representation | Specialization disabled |
|---|---:|---:|---:|---:|
| Instrumented allocation requests | 1,637,601 | 818,801 | 818,801 | 1,637,601 |
| Instrumented allocated bytes | 65,497,760 | 39,296,160 | 39,296,160 | 65,497,760 |
| Median elapsed time, 13 uninstrumented runs | 15.67 ms | 15.39 ms | 15.07 ms | 15.67 ms |
| Root RV64 text | 3,964 B | 5,176 B | 4,508 B | 3,964 B |

Codegen 202 won 12 of 13 paired timings against each tagged compiler mode. The source-level abstraction now has allocation parity; its emitted code remains larger. With 256 producer/reader pairs the compiler emitted exactly 256 private entries of each kind. Compilation allocated 9.20 GB and emitted 568,392 bytes of root text, versus 6.86 GB and 327,876 bytes for explicit code. The existing absolute compiler budgets passed at 1.61, 32.90 and 67.63 GB. The standard-library fixture is near its 10% headroom limit. [Paired samples and compiler cost](../bench/2026-11-05-tree-storage-throughput.json) · [Scaling](../bench/2026-11-05-tree-storage-scaling.json)

## QOS Pi 4B and arena qualification

Two separately staged runs exercised the tree workload alongside the installed QOS desktop. Each scheduling run collected 6,912 ordinary replies per mode across nine routing, worker-count and contention configurations.

| Run | Cases | Median, private / rollback | p99, private / rollback |
|---|---:|---:|---:|
| Initial | 186 | 206 / 209 µs | 1,321 / 1,589 µs |
| Expanded, including effect order and active regions | 218 | 206 / 210 µs | 1,455 / 1,618 µs |

The expanded run confirmed the 1,023/2,046 object counts and their exact byte totals, passed both watchdogs, and recorded 348 versus 572 replies over 1 ms. The desktop continued under PID 17227 with zero restarts. The host scheduling suite passed 315 configurations. Static-arena single-entry and finite-sequence gates also passed on RV64. These are workload measurements and existing arena regressions. Main boot/memory qualification remains at codegen 197. General response-time and concurrent-arena admission remain open. [Physical and host validation](../bench/2026-11-05-tree-storage-validation.json)

## Next C2 workload

An imported standard-library AVL map still allocates once per inserted scalar wrapper. With 512 integer keys and default inlining, inserting wrapped integers and folding over the same map twice used 6,139 allocations and 360,032 bytes. The identical program using plain integers used 5,627 allocations and 343,648 bytes. Disabling inlining gave the same 512-allocation and 16,384-byte differences. With 128 keys the difference was exactly 128 allocations. Both programs preserve the same ordered map operations and produced the independent arithmetic sum on one and four workers. This puts a measurable cost on the imported polymorphic insert/fold path. Its ordinary Map API, persistent subtree sharing and comparison callback must survive a specialization. [Workload sources and counters](../bench/2026-11-05-std-map-storage-before.json)

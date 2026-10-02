# docs/: a chronological record

Kind: index. Every document in this directory is named
`YYYY-MM-DD-NAME.md`, dated by the day it was first written, so a listing
of the directory is the timeline of the project's thinking. Older and
newer pages are not reconciled with each other: a page says what was true
or intended when it was written, and a later page may supersede it without
the earlier one being rewritten. When two pages disagree, the later date
wins unless the earlier page is one of the living registers below.

## Adding a page

Name it with today's date, add one line to the end of the list below, and
say near the top what kind of page it is and what revision it applies to
(the policy is 2026-09-16-DOCUMENTATION.md). Do not rename a page when it
changes: its date is when it began, and the record of what changed goes in
dated sections inside it, the way 2026-09-23-ESP-IDF.md does. Do not fold an
older page into a newer one to make them agree; write the newer one and
point back.

## Living registers

A few pages are kept current rather than superseded, because code comments
point at them as the place a fact is registered. Their date is still when
they began.

| page | what it registers |
|---|---|
| 2026-08-25-MEMORY.md | the memory model and allocator contract |
| 2026-09-19-BOUNDS.md | every fixed limit, why it is fixed, what happens at the edge |
| 2026-09-19-PROFILES.md | the profile and system matrix, and the posix hosts |
| 2026-09-19-HAL.md | runtime, machine layer and HAL: which is which |
| 2026-09-18-BASE.md | what the Base profile grants |
| 2026-09-20-STD.md | the standard library as it ships |
| 2026-09-19-LAYOUTS.md | typed memory layouts |
| 2026-10-02-SCHED-MODEL.md | the scheduler's structures, policy and bound: in admissions as enforced, in time under stated assumptions |

## The record, oldest first

| date | page | what it is |
|---|---|---|
| 2026-08-25 | [MEMORY.md](2026-08-25-MEMORY.md) | the memory model, v2: linear by default, Rc fallback, ARC by promotion, one allocator contract |
| 2026-08-25 | [NOTES.txt](2026-08-25-NOTES.txt) | working notes; not part of any contract |
| 2026-08-25 | [SAFETY.md](2026-08-25-SAFETY.md) | the compiler-enforced safe/unsafe line |
| 2026-08-25 | [TRANSACTION.md](2026-08-25-TRANSACTION.md) | Sol: the whole script run is the transaction |
| 2026-08-25 | [VEC.md](2026-08-25-VEC.md) | `Vec a`, the compute-bound default: columns, fusion, dense loops |
| 2026-08-27 | [PATHS.md](2026-08-27-PATHS.md) | first-class paths, the MVU message port, live iteration in value space |
| 2026-08-29 | [MEMORY-V2-PLAN.md](2026-08-29-MEMORY-V2-PLAN.md) | the migration plan for MEMORY v2, phase by phase, with what landed |
| 2026-08-30 | [SPANS.md](2026-08-30-SPANS.md) | source spans for diagnostics: the staged plan |
| 2026-09-01 | [STYLE.md](2026-09-01-STYLE.md) | the source style guide for FP-RISC and Sol |
| 2026-09-02 | [API-REVIEW.md](2026-09-02-API-REVIEW.md) | consistency review of builtins, APIs and examples against DESIGN_PATTERNS, with corpus counts |
| 2026-09-02 | [DESIGN_PATTERNS.md](2026-09-02-DESIGN_PATTERNS.md) | the fixed conventions of FP-RISC and Sol |
| 2026-09-02 | [JIT.md](2026-09-02-JIT.md) | Sol's hand-rolled native JIT tier (x86-64 and A64) |
| 2026-09-02 | [SCRIPTING.md](2026-09-02-SCRIPTING.md) | scripting with Sol: transforming values, files, the host, external tools |
| 2026-09-04 | [SOL-REVIEW.txt](2026-09-04-SOL-REVIEW.txt) | Sol robustness ledger, reviewed 2026-08-31: bugs, edges, what was fixed |
| 2026-09-04 | [TOOLCHAIN.md](2026-09-04-TOOLCHAIN.md) | inventory of the build toolchain on the development Mac; not minimum versions |
| 2026-09-07 | [MAILBOX.md](2026-09-07-MAILBOX.md) | mailboxes: per-sender rings, capacity as a choice, a full ring as an answer |
| 2026-09-08 | [SOL-TEXT.md](2026-09-08-SOL-TEXT.md) | Sol as a text tool, measured against awk, sed and the shell |
| 2026-09-11 | [API.txt](2026-09-11-API.txt) | the QOS service and driver API, for v2 |
| 2026-09-11 | [SEMANTICS.txt](2026-09-11-SEMANTICS.txt) | semantics notes for v2 (the contract itself is ../SEMANTICS.md) |
| 2026-09-12 | [V2.md](2026-09-12-V2.md) | V2 goals and workstreams: real hardware and real applications; working notes, not a spec |
| 2026-09-16 | [DOCUMENTATION.md](2026-09-16-DOCUMENTATION.md) | documentation policy: kinds of page, authority, evidence |
| 2026-09-16 | [PLATFORM.md](2026-09-16-PLATFORM.md) | the language platform: language, Base and the standard ecosystem; proposed 2.0 framework |
| 2026-09-16 | [STD-PLAN.md](2026-09-16-STD-PLAN.md) | the core and std libraries for 2.0: inventory, tiers, the gate |
| 2026-09-16 | [V2-AUDIT.md](2026-09-16-V2-AUDIT.md) | the earlier review's findings re-checked against the tree |
| 2026-09-18 | [BAREMETAL-BUILTIN.md](2026-09-18-BAREMETAL-BUILTIN.md) | the builtin profile: standalone unsafe RV64, `--arc`, `--raw`, library units and C exports |
| 2026-09-18 | [BASE.md](2026-09-18-BASE.md) | the Base profile: FP-RISC as a language for this machine |
| 2026-09-18 | [MACHINE-PRIMITIVES.md](2026-09-18-MACHINE-PRIMITIVES.md) | the opaque machine primitives of the builtin profile |
| 2026-09-18 | [PROJECT-PROGRESS-SUMMARY.md](2026-09-18-PROJECT-PROGRESS-SUMMARY.md) | snapshot of QOS and FP-RISC progress from the first review to 2026-09-18 |
| 2026-09-19 | [BOUNDS.md](2026-09-19-BOUNDS.md) | the register of fixed limits in the runtime and compiler |
| 2026-09-19 | [C-REDUCTION.md](2026-09-19-C-REDUCTION.md) | the plan that moves policy and limits out of C, with what landed |
| 2026-09-19 | [HAL.md](2026-09-19-HAL.md) | runtime, machine layer, HAL: three things that were one word |
| 2026-09-19 | [LAYOUTS.md](2026-09-19-LAYOUTS.md) | typed memory layouts in the builtin profile |
| 2026-09-19 | [PRELIM_BASE_LIBRARY_DESIGN.md](2026-09-19-PRELIM_BASE_LIBRARY_DESIGN.md) | preliminary Base and ExtBase library design; a planning proposal |
| 2026-09-19 | [PROFILES.md](2026-09-19-PROFILES.md) | profiles and systems: what a program is written against, where it runs, and the posix hosts |
| 2026-09-19 | [WHAT_IS_SOL.md](2026-09-19-WHAT_IS_SOL.md) | what Sol is: design rationale and proposed standalone architecture |
| 2026-09-20 | [LIVE.md](2026-09-20-LIVE.md) | can FP-RISC host a real application? the FPRLive goal, measured, and what followed |
| 2026-09-20 | [STD.md](2026-09-20-STD.md) | the standard library: what ships, module by module |
| 2026-09-21 | [PERSISTENCE_FAILURES.md](2026-09-21-PERSISTENCE_FAILURES.md) | how `KvLog` and Live handle a failed append |
| 2026-09-22 | [KEYED-VIEWS.md](2026-09-22-KEYED-VIEWS.md) | keyed views: structural snapshots without replacing the page |
| 2026-09-23 | [VIEW-CACHE.md](2026-09-23-VIEW-CACHE.md) | explicit per-session view caching in `std/viewcache` |
| 2026-09-23 | [ESP-IDF.md](2026-09-23-ESP-IDF.md) | the ESP32-P4 port: decisions, workarounds, and the dated record of its merge into the posix system as a host |
| 2026-09-29 | [Sol-Improvements-Needed.md](2026-09-29-Sol-Improvements-Needed.md) | Consolidated timestamped assessment, implementation updates, measurements and remaining Sol work |
| 2026-09-29 | [NATIVE-IDEAL-AUDIT.md](2026-09-29-NATIVE-IDEAL-AUDIT.md) | Source-grounded comparison of native ownership, actors, vectors, optimization and C interoperability with the original language ideal |
| 2026-09-29 | [TOOLING-SEMANTICS-AUDIT.md](2026-09-29-TOOLING-SEMANTICS-AUDIT.md) | Modules, static typing, refinements, termination, resource proofs, hosted optimization and MVU: implemented guarantees, verified gaps and proposed acceptance criteria; September 30 operator-resolution follow-up |
| 2026-09-30 | [FAILURE-HONESTY.md](2026-09-30-FAILURE-HONESTY.md) | Ambiguous operators refused, `--stdcheck` exit status, the A64 `s10` crash, `receiveFromRes`/`std/actor call`, and Sol commit honesty (G1-G4, `log`) |
| 2026-09-30 | [NATIVE-PERF.md](2026-09-30-NATIVE-PERF.md) | The benchmark ratchet (`tools/bench.py`) and the first base-profile code-generation steps: sha 3.6x, byteloop 3.1x, fib 1.9x |
| 2026-10-01 | [ACTOR-RESULT-LOSS.md](2026-10-01-ACTOR-RESULT-LOSS.md) | A losing channel claimant erased a queued Result; counter ownership repair, deterministic regression and 240 parallel SHA stress runs |
| 2026-10-01 | [F64-FAST-PATHS.md](2026-10-01-F64-FAST-PATHS.md) | Scalar F64 instructions and literal folding, independent C-reference and x64/RV64 checks, focused comparison benchmark |
| 2026-10-01 | [REGISTERS-AND-COSTS.md](2026-10-01-REGISTERS-AND-COSTS.md) | Preserved-register private slots, differential/backend tests, paired performance and allocation/message cost ledgers |
| 2026-10-01 | [XHART.md](2026-10-01-XHART.md) | Cross-hart messages profiled (OS park/wake was ~90%), then spin-before-sleep, spin-before-block and split ring cache lines: round trips 19.6x faster |
| 2026-10-01 | [LOOPWITH.md](2026-10-01-LOOPWITH.md) | `Sys.loopWith`: every step an arena, one linear Vector threaded by identity; a long-lived loop runs in O(1) memory |
| 2026-10-01 | [INDEXING.md](2026-10-01-INDEXING.md) | The 0-based / 1-based split as it stands (strings, `!`, `Vec.get/set` 1-based; `Vec.at/put`, offsets 0-based), and a proposed migration to 0-based everywhere |
| 2026-10-01 | [PROCESS-IMAGES.md](2026-10-01-PROCESS-IMAGES.md) | Mortal process images: an O(1) image map for `fpr_in_heap`, the reap hook, and what the deep copier lets leave another process's image (data copied, functions refused) |
| 2026-10-01 | [CODE-PUBLICATION.md](2026-10-01-CODE-PUBLICATION.md) | Loaded code publication: local fence and a generation acquired and fenced by every remote hart before actor dispatch |
| 2026-10-01 | [TYPED-VECTORS.md](2026-10-01-TYPED-VECTORS.md) | Vector a links element reads/writes/maps, preserves linearity, derives raw-float output layouts and refuses unsupported representation-polymorphic allocation |
| 2026-10-01 | [VEC-PEEK.md](2026-10-01-VEC-PEEK.md) | `(x, v2) = Vec.at i v` builds no (value, handle) pair: a Core rewrite to pair-free reads; 50M reads 2.9x faster, 2.4 GB -> 19 MB |
| 2026-10-02 | [ZERO-BASED.md](2026-10-02-ZERO-BASED.md) | Every position is 0-based: the primitives, Sol, std (a major version) and every call site in both repos flipped in one change; -1 = not found; slices half-open |
| 2026-10-02 | [TOOLING-SEMANTICS-AUDIT.md](2026-10-02-TOOLING-SEMANTICS-AUDIT.md) | Second pass against the intended language: commit now type-checks, Sol applies preconditions, imported unsafe taints main, Vector a typed; new: malformed signatures silently dropped, Sol has no TCO (1.8 GB per million iterations), stdcheck and Safety disagree on measures |
| 2026-10-02 | [SIGNATURES-AND-TAIL-CALLS.md](2026-10-02-SIGNATURES-AND-TAIL-CALLS.md) | A malformed signature is a parse error (it used to be dropped; record types `{ f : T | r }` were never signature grammar, so 13 std modules had unchecked headers); Sol `TailCall` replaces the frame, 30M iterations in 30 MB |
| 2026-10-02 | [RESOURCE-BOUNDS.md](2026-10-02-RESOURCE-BOUNDS.md) | Proposal: work/alloc/live bounds in signatures; one measure language first, a cost pass on the typed Core, bounds in interfaces, target manifests that turn ops into time, live memory from linearity and arenas |
| 2026-10-02 | [SCHED-MODEL.md](2026-10-02-SCHED-MODEL.md) | Living register: per-hart queues, the two tiers, donation; the admission bound the code enforces and the time bound it does not |
| 2026-10-02 | [ONE-MEASURE-LANGUAGE.md](2026-10-02-ONE-MEASURE-LANGUAGE.md) | Stage 0 of resource bounds: Safety.measureCheck is the only termination verifier and stdcheck consumes it; mutual recursion measured as a group; `x >= 0 and measure x`; safety before precondition insertion |
| 2026-10-02 | [COST-PASS.md](2026-10-02-COST-PASS.md) | Stage 1 of resource bounds: `fpr build --cost` prints work/alloc equations per root function from the Core; measured groups close to (measure/step + 1)·body, `work f` through parameters, ω for unmeasured helpers and undeclared primitives |
| 2026-10-02 | [BOUNDS-IN-SIGNATURES.md](2026-10-02-BOUNDS-IN-SIGNATURES.md) | Stage 2 of resource bounds: `| work f <= e | alloc f <= e` in signatures, checked coefficient-wise (PROVEN / OVER / UNPROVED, errors), callers compose on the declaration, commit sees bounds; `size f <= e` as a declared result length; std/list and std/string loops measured, string primitives costed |
| 2026-10-02 | [TARGET-MANIFESTS.md](2026-10-02-TARGET-MANIFESTS.md) | Stage 3 of resource bounds: `--manifest=FILE` names compiler/runtime/hardware, prices ops and primitives, binds named coefficients (`omega * n`), and judges budgeted functions (PROVEN within / OVER / UNPROVED), as a compile gate |
| 2026-10-02 | [LIVE-MEMORY.md](2026-10-02-LIVE-MEMORY.md) | Stage 4 of resource bounds, the part the memory model supports: `live` is alloc under the pool model, credited back inside Sys.arena and Sys.loopWith steps; persistent loops report a per-step cost; `live f <= e` declarable; what is not done and why |
| 2026-10-02 | [ARENA-OVERRIDE.md](2026-10-02-ARENA-OVERRIDE.md) | A runtime fix: the Sys.arena/loopWith pool override was a hart field, so actors run while another was parked inside its arena allocated into it; it is an ACB field now |
| 2026-10-02 | [IDEAL-EXAMPLES.md](2026-10-02-IDEAL-EXAMPLES.md) | Six native examples using clauses, guards, contracts, measures and pipelines; behavior comparisons with the originals, proved resource declarations, refused broken guarantees and remaining style limitations |
| 2026-10-02 | [ACTOR-MEMORY-LIFECYCLE.md](2026-10-02-ACTOR-MEMORY-LIFECYCLE.md) | Admission, actor-local allocation, growth, escaped ownership and exit; first fixed-heap grant implementation and remaining total-budget work |
| 2026-10-03 | [LIVERELOAD.md](2026-10-03-LIVERELOAD.md) | Proposal: LiveReload as an `EReload` event in std/mvu, live modules as row-typed values the runner owns and swaps between turns, `fpr watch` driving commit-classified reloads (patch) or restarts (major), the attach step moved from qos into the runtime |
| 2026-10-03 | [SPECIALIZATION.md](2026-10-03-SPECIALIZATION.md) | Plan: no closures exist, only PAPs; a Core pass cloning higher-order functions per statically known function argument (captures become parameters) removes PAPs and fpr_apply at known sites; semantics, cost equations and live modules untouched; five steps with a differential gate |
| 2026-10-03 | [SPECIALIZATION-IMPLEMENTED.md](2026-10-03-SPECIALIZATION-IMPLEMENTED.md) | Core function specialization across recursive/imported helpers and Sol; captures become parameters; differential, allocation, timing and code-growth evidence; dynamic ABI and remaining limits |
| 2026-10-03 | [VECTOR-AUDIT.md](2026-10-03-VECTOR-AUDIT.md) | Source audit and target contract: effect-order fusion defect, arbitrary record widths, inferred layouts, shared scalar/SIMD kernels, Matrix a, performance evidence and acceptance gates |
| 2026-10-03 | [FUSION-EFFECT-ORDER.md](2026-10-03-FUSION-EFFECT-ORDER.md) | Vector audit step 0: map/map and fold-of-map fuse only when both element functions are effect- and failure-free (`fusionSafe`); declined pairs are reported; the ownership-only argument in VEC.md is superseded |
| 2026-10-03 | [VECTOR-DESCRIPTORS.md](2026-10-03-VECTOR-DESCRIPTORS.md) | Vector audit step 1: `vec_t` gains a per-column kind byte array and a column directory behind pointers, no VMAXCOLS and no bitmaps; any record width is SoA; declared layouts adopt the first value's shape; record float layouts inferred; copiers, loopWith snapshot, codegen and qos gfx mirror migrated |

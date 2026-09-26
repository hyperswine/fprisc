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

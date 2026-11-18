# FP-RISC feature-set audit: is it complete, what can be frozen (2026-11-18)

Kind: read-only audit and freeze proposal. It changes no code. Checked against
`origin/main` at `89a09f86` (merge of #103). Behaviour marked **verified** was
run on this date with the compiler built at `912c4957` (the #103 head, the same
compiler code as `89a09f86`), `fpr build` for the posix system on x86-64 Linux.
Everything else cites the file it was read from. Where an older dated page is
quoted, its date is given, and it is not re-verified unless marked.

The question (Jack, 2026-11-18): is the current feature set complete for a
general-purpose functional language that spans bare metal, library and
application programming, and can its spec be frozen so that the compiler can
be cleaned up?

## Verdict

**Not complete, and not ready to freeze as one piece. A large core can be
frozen now.** The core language is substantial and mostly implemented:
strict HM inference with records and row variables, parametric sum types,
pattern matching with exhaustiveness, linear types, termination measures,
precondition contracts, resource contracts (`work`/`alloc`/`live`), actors,
regions with automatic copy-out, and five native targets plus the Sol VM.

What blocks a full freeze:

1. **The 10 November numeric and string decisions are not implemented.**
   D5 (floored `%`), D6 (exact `Int`), D7 (`ofInt` returns `Option`), D8 (floored
   `/`), D9 (floored I64/I32 and `min / -1` wraps), D10 (`String`/`Bytes`) and
   D11 are recorded in [FAILURE-MODES](2026-11-10-FAILURE-MODES.md#decisions-d6d12-2026-11-10-expected-semantics), but
   main still truncates (`(0-7) % 2` prints `-1`, `(0-7) / 2` prints `-3`,
   **verified**), traps on `Int` overflow (**verified**: `Int overflow: 4611686018427387903 + 1 does not fit an Int`),
   types `I64.ofInt : Int -> I64` (`compiler/Infer.hs:725`, `I32.ofInt` at :684),
   and still panics on `INT64_MIN / -1` (`runtime/runtime.c:6118`,
   `runtime/i32.c:19`). Freezing now would freeze text the compiler does not do.
2. **The abstraction mechanism is half-built.** `Sig`/`Struct` conformance is
   by field name only, with no type-level check and no abstract type members
   (`compiler/Struct.hs` header: "deliberately name-level (no inference yet)";
   [DEVICE-SIGS](2026-11-18-DEVICE-SIGS.md) "What has to be built" items 1–2).
   Libraries cannot hide a representation, and that also blocks device Sigs.
3. **Effects and actor messages are untyped.** `send : Int -> a -> Result Unit String`
   (`compiler/Infer.hs:544`). An actor is an `Int`, `receive` is "typed unsafely"
   ([SEMANTICS §1](SEMANTICS.md)), and IO is a `Sys.*` call that any function may make.
   Adding an effect or protocol discipline after a freeze would break programs.
4. **Three execution engines disagree.** Native traps on `Int` overflow, the Sol
   interpreter is exact and the Sol JIT wraps. `strlen "é"` is 2 natively and 1 in Sol
   (FAILURE-MODES integer and string tables, verified 2026-11-10; no later
   commit on main changes this).
5. **The bare-metal tier rests on experimental ARC.** The builtin profile's
   memory model is manual `Rc.retain`/`release` or opt-in `ARC=1`. Resumable
   interrupts need `ARC=1` ([BAREMETAL-BUILTIN](2026-09-18-BAREMETAL-BUILTIN.md#resumable-machine-interrupts)),
   while the decided memory model is "reuse + regions, no ARC in Base"
   ([MEMORY-RECLAMATION-INTENT](2026-11-11-MEMORY-RECLAMATION-INTENT.md)).
6. **There is no executable conformance suite for the spec.** 26 of the 51
   distinct file targets in SEMANTICS.md's `[test: …]` slots no longer exist in
   this repo. Most are Python/shell checks removed by the [Sol-only transition](2026-11-13-SOL-ONLY.md);
   a few are QOS tests that left with the repository split.
   The language tests that remain (`tests/eq.fpr`, `linpap.fpr`, `mailbox.fpr`,
   `paths.fpr`, `holes_named.fpr`, `split.fpr`) are not referenced by any
   `tests/sol-checks/*.sol`, `tools/*.sol` or the Makefile.

Smaller gaps: no unsigned narrow integers or `Byte` type (D10 assumes `chr`
returns a `Byte` that does not exist); no fixed-size arrays; FFI only through
the runtime's value ABI; no package version solving; std mixes the core library
with application modules.

## 1. Status matrix

Status key: **I** = implemented and tested; **P** = implemented, partial;
**D** = documented or decided only; **M** = missing; **X** = implemented, but
inconsistent with a decision or another surface.

### Surface and syntax

| Feature | Status | Evidence |
|---|---|---|
| Clauses, guards, `case`, `if`, blocks, lambdas, `\|>`, `\|>?`, `$`, interpolation | I | `compiler/Frontend/Parser.hs`; `tests/if-precedence-check.hs` (cabal suite); SEMANTICS §1–2 |
| Exhaustive `case`, unreachable-arm refusal | I (cited test gone) | `compiler/Exhaust.hs`; SEMANTICS cites `tests/check_cases.py`, removed |
| Duplicate clause refused | M | FAILURE-MODES compiler-gaps table: "compiles; second clause unreachable" |
| Zero-based positions everywhere | I | [ZERO-BASED](2026-10-02-ZERO-BASED.md); SEMANTICS §2/§3 still say strings are 1-based (stale) |
| Operator precedence table | D | SEMANTICS §2: "(write it down)" |
| Reserved words | X | Lexer `reserved` = `fn case of if then else Type Sig Struct use` (`compiler/Frontend/Lexer.hs:43`); SEMANTICS §2 lists `unsafe measure`, not `if then else` |
| Typed holes `?name`, `??` | I | SEMANTICS §3; `tests/holes_named.fpr` (not wired into CI) |
| `Layout` declarations (typed raw memory) | I (builtin, rv64) | `Parser.hs:507`; [LAYOUTS](2026-09-19-LAYOUTS.md); its `tests/check_layout.py` is gone |

### Types

| Feature | Status | Evidence |
|---|---|---|
| `Int` tagged 63/31-bit | X | Native traps on overflow (verified). Sol interpreter exact, JIT wraps (FAILURE-MODES). SEMANTICS §3 says "wraps silently today" (stale) |
| Exact `Int` with bignum promotion (D6) | D | FAILURE-MODES D6, order-of-work item 7 (L). No bignum in `runtime/` |
| Floored `/` and `%` (D5/D8) | D | Verified truncating: `-1 -3` |
| `I64`, `I32` | I | `compiler/Type/Syntax.hs`; `tests/i64.fpr`; sol-check `i64-raw-locals` |
| `I32/I64.ofInt -> Option` (D7) | D | `Infer.hs:684,725` are `Int -> I32/I64`. `I64.toInt` returns `Result` (verified `Ok 5`) |
| `min / -1` wraps (D9) | D | `runtime/runtime.c:6118`, `runtime/i32.c:19` still `fpr_trap` |
| `F64`, `F32` (IEEE) | I | `tests/float.fpr`; FAILURE-MODES float table |
| `Word`, `Addr` | I (builtin) | `Infer.hs:447–`; [MACHINE-PRIMITIVES](2026-09-18-MACHINE-PRIMITIVES.md) |
| Unsigned narrow ints / `Byte` | M | No `Byte`/`U8`/`U32` in `Type.Syntax` or `builtinEnv`; D10 assumes `chr : … -> Byte` |
| Bool, Unit, tuples up to 8 | I | builtin constructors `Tup2`–`Tup8` |
| Records, update, nested update, row polymorphism | I | `Type.Syntax` `TRec`/`RV`, `Scheme` row vars; [OPEN-RECORD-BOUNDARIES](2026-11-05-OPEN-RECORD-BOUNDARIES.md) |
| Typed paths `@Model.field` | I | SEMANTICS §8; `tests/paths.fpr` (not wired) |
| Parametric sum types | I | e.g. `Option a = Type (None \| Some a)` in `std/option.fpr` |
| Abstract/opaque types, existentials, GADTs | M | DEVICE-SIGS item 1, "Opaque state" |
| HM inference, let-polymorphism | I | `compiler/Infer.hs` (2476 lines) shared by Sol (`compiler/Sol/Infer.hs` header) |
| Rebinding type-check gap | X (bug) | FAILURE-MODES: `v = "x" :: v` with `v : List Int` compiles |
| `Sig`/`Struct` (interfaces, ML-style modules) | P | `compiler/Struct.hs`: name-level row check, monomorphised for literal structs, record fallback otherwise. Prelude sigs `Arith Add Eq Ord Functor Seq` (`core/prelude.fpr:44–49`) |
| Implicit instance resolution (typeclasses) | M | none; `std/test.fpr` needs `equalInt`/`equalString` |
| Monomorphisation / specialisation | I | `Core.Typed.Monomorphize`; [SPECIALIZATION-IMPLEMENTED](2026-10-03-SPECIALIZATION-IMPLEMENTED.md) |
| Linear types (`T 1 = Type …`) | I | `compiler/Frontend/Linearity.hs`; prelude `Handle 1`, `Vector 1`, `MutMap 1`, `FixedMap 1`, `SString 1` (`core/prelude.fpr:16–40`); sol-checks `linearity`, `ownership` |
| `List 1` (VList backend when linear) | D | [PARALLEL-MAP-FOLD](2026-11-15-PARALLEL-MAP-FOLD.md); no code |
| Safe/unsafe line, `measure` termination | I | `compiler/Safety.hs`; `tests/measure.fpr`; sol-check `trust` |
| Preconditions `(x : T \| p)` | P | `compiler/Precond.hs`: linear Int arithmetic only. No `len` atoms (FAILURE-MODES item 12). Literal-false preconditions not refused (item 4). `/` falls back to a trap |
| Effect types | M | Effects are `Sys.*`/HAL calls (SEMANTICS §9). Resource roadmap R3 "Higher-order and effect contracts" is planned |
| Deep `==`, no depth cap | I | `runtime/runtime.c:4880` comment; SEMANTICS §4 still says depth 64 (stale) |

### Memory model

| Feature | Status | Evidence |
|---|---|---|
| Static in-place reuse of unique cells | P | `compiler/Reuse.hs` (local proofs; MEMORY-RECLAMATION-INTENT "What (a) does") |
| TRMC list builders | I | `Core/Typed/Trmc.hs`; [SPLITTING-LOOPS](2026-11-18-SPLITTING-LOOPS-AND-REGION-FLOOR.md) |
| Regions with automatic copy-out (default on) | I | [AUTOMATIC-COPY-OUT](2026-11-11-AUTOMATIC-COPY-OUT.md); `FPR_NO_LOOP_REGIONS`, `FPR_NO_CALL_REGIONS` |
| No ARC in Base | X | Decided 11 Nov. Yet `sendArc`, `Rc.retain/release`, `arcLive` are builtins (`Infer.hs`). SEMANTICS §10: messages "ARC-shared … the ARC table grows". Builtin profile `ARC=1` (README) |
| Out-of-memory contract | D | SEMANTICS §16 "(decide)" |

### Resource bounds, WCET, fuel

| Feature | Status | Evidence |
|---|---|---|
| `work`/`alloc`/`live` contracts, `--cost` | I | `compiler/Cost.hs`; sol-check `cost`; [RESOURCE-CONTRACTS roadmap](2026-11-07-RESOURCE-CONTRACTS-WCET-AND-QOS-ROADMAP.md) baseline table |
| Native instruction bounds between safepoints | I | `compiler/Codegen/Bounds.hs` (`native-insns-v1`) |
| Stack / heap / static-arena admission | P | linked stack, scalar arena and static activation pages (2026-11-05); `tools/build-static-arena.sol` |
| Fuel / weighted ticks, preemption | I | builtins `fuelQuantum`, `fuelPreempts`; [WEIGHTED-TICKS](2026-11-11-WEIGHTED-TICKS.md) |
| Cycle WCET on the cached-SDRAM simple-risc | D | RESOURCE roadmap T1–T4; [RELIABILITY roadmap §4](2026-11-01-RELIABILITY-CORRECTNESS-WCET-ROADMAP.md) |
| Bounded/no-heap code must prove `Int` small (D6 stage 2) | D | FAILURE-MODES item 8 |

### Concurrency

| Feature | Status | Evidence |
|---|---|---|
| Actors, mailboxes `Static n`/`Dynamic n`, harts, stealing | I | `runtime/actors.c`; SEMANTICS §10; `tests/mailbox.fpr` (not wired) |
| Typed actor handles / protocols | M | `send : Int -> a -> …` (`Infer.hs:544`) |
| `parMap` / `parFold` | D | PARALLEL-MAP-FOLD; no matches in `compiler/`, `core/`, `std/` |
| `par2`, receive turns, supervision | I | `core/prelude.fpr`; `compiler/ReceiveTurns.hs`; `std/supervisor.fpr` |
| Scheduling fairness/latency promise | D | SEMANTICS §10 "(decide)" |

### Errors, strings, collections

| Feature | Status | Evidence |
|---|---|---|
| `Option` (std), `Result` (builtin), `error` → actor crash | I | `std/option.fpr`; `Infer.hs` constructors |
| Indexing never traps (D3) | P | `L.get` → `Option`; `xs ! i`, `Vec.get`, `charAt`, `SStr.push` still trap (FAILURE-MODES string table) |
| Structured error values | P | Sol `FsError` is the model (SEMANTICS §9); most `.fpr` APIs return `Err String` |
| `String` = bytes natively | X | Native bytes, Sol code points (FAILURE-MODES) |
| `String`/`Bytes` split (D10/D11) | D | FAILURE-MODES item 6 |
| `Bytes` | X | Two surfaces: Sol builtin `Bytes` (SEMANTICS §9) and native `std/bytes.fpr` over `Vec`, which is off the safety allow-list (`tests/sol-checks-known-failures.tsv`) |
| `List`, `Map` (tree), `HashMap` (hash trie), `Set`, keyed list | I | `std/map.fpr:24` is a balanced tree; [HASH-TRIE](2026-11-14-HASH-TRIE.md) |
| `Map` defaults to a HAMT (Jack's direction) | D | `std/map` is still the tree; the HAMT is `std/hashmap` |
| `Vector 1` (SoA, `VMAXCOLS 8`), `MutMap 1`, `FixedMap 1`, `SString 1` | I | runtime `vec.c`, `sstr.c`; [MUTMAP](2026-11-10-MUTMAP.md) |
| Fixed-size arrays (`Array n a`) | M | none |

### Bare metal, targets, FFI, packaging, tooling

| Feature | Status | Evidence |
|---|---|---|
| Builtin profile (RV64 QEMU virt): `Word`/`Addr`/`Mem`, CSR, IRQ masking, atomics, fences, `--raw` units | I | BAREMETAL-BUILTIN, MACHINE-PRIMITIVES; `machine/builtin/machine.S` |
| Resumable machine interrupts | P | RV64 only and needs `ARC=1`. `compiler/Interrupt.hs` contract. Nesting/NMI out of scope |
| MMIO / volatile | P | Out-of-line asm `Mem.*`, `reg8`/`reg32`, `device`; no typed volatile. DMA "(decide)", SEMANTICS §14 |
| Inline assembly | M (by design) | Opaque primitives in `machine.S` instead |
| Device Sigs / driver contract | D | DEVICE-SIGS (2026-11-18) |
| Targets: x86-64 Linux/macOS, AArch64, RV64 Linux, RV32 Tang Nano 20K, ESP32-P4 | I | README; `machine/{posix,virt,builtin,tangnano20k,esp-idf,unix}` |
| Sol bytecode VM + JIT | I | `compiler/Sol/VM.hs`, `JitCore.hs`, `HandJIT.hs` |
| FFI in (`--foreign=FILE`) | P | Signatures resolved to `fpr_g_` symbols over the runtime value ABI (`compiler/Compile.hs:334–350`). No plain C struct/pointer types |
| FFI out (`--lib`/`--export`) | P | Builtin profile, scalars only (SEMANTICS §7; cited `tests/check_export.py` gone) |
| Modules: `use`, aliases, `#hash` pins, `fpr commit`, `fpr.lock` | I | SEMANTICS §7; `compiler/Modules.hs` |
| Projects: `fpr.toml`, `new/check/build/run/test/doctor` | I | `compiler/Project.hs`; [PROJECT-WORKFLOW](2026-10-31-PROJECT-WORKFLOW.md) |
| Version solving / registry | M | PROJECT-WORKFLOW: "no version solving" |
| Toolchain manager `fprmeta`/`qosmeta` | I | [FPRMETA](2026-11-01-FPRMETA.md), [published](2026-11-02-FPRMETA-PUBLISHED.md) |
| Binary ABI across compiler versions | M | `codegenRev = 257` (`compiler/Codegen.hs:62`); SEMANTICS §19 still says `codegenRev 8` |
| Test runner `fpr test` + `std/test` | I | `std/test.fpr` |
| LSP / editor JSON | I | `lsp/`; [EDITOR-INTEGRATION](2026-11-01-EDITOR-INTEGRATION.md) |
| Doc generator, formatter | M | no `doc`/`fmt` command in `compiler/Main.hs` or `Project.hs` |

## 2. Gap analysis per domain

"Before freeze" means that adding it later would change the meaning of existing
programs or the frozen text. "Later" means it can be added compatibly.

### Bare metal

| Gap | When | Why |
|---|---|---|
| Builtin-profile memory model decided (static arenas + regions, or keep manual RC/ARC) | **Before freeze** | The interrupt contract and `--raw` units are defined relative to ARC today |
| `Byte` and unsigned fixed widths (`U8`/`U16`/`U32`) | **Before freeze** for `Byte` (D10 depends on it); later for the rest | Register and protocol code currently uses `Word`/`Int` masks |
| Fixed-size inline arrays (`Array n a`) for no-heap code | Before freezing the bare-metal tier | `SString 1` (128 B) and `FixedMap 1` are the only fixed-capacity values |
| Typed MMIO (volatile register blocks via `Layout`) | Later | Can extend `Layout`; today's `Mem.*` calls are already ordered effects |
| Interrupts on RV32 and AArch64, nesting, priority | Later | The contract shape (`machineInterrupt`) can stay |
| Device Sigs (opaque state, ABI rows, header generation) | Later, but needs abstract types first | DEVICE-SIGS items 1–5 |
| Cycle-level WCET | Later (experimental) | Contracts are already target-independent `work` |

### Library programming

| Gap | When | Why |
|---|---|---|
| Abstract types in Sigs, type-level conformance | **Before freeze** | Without them no library can protect an invariant. Tightening conformance later rejects programs that pass today |
| Effect discipline (at least pure vs effectful, inferred) | **Decide before freeze** | Retrofitting purity breaks every library that prints |
| Typed actor handles `Actor msg` | **Before freeze** | `send`'s type is part of the public surface |
| Module visibility / export lists | **Before freeze** | Every top-level bind is a module export (`compiler/Modules.hs:74`), and the parser has no export-list syntax. Adding privacy later would change which names importers can see |
| Stable C ABI for exported Sigs, plain C types in FFI | Later | Additive (DEVICE-SIGS item 2) |
| Version solving, registry | Later | `fpr.toml` already records name, version and hash |
| Doc generator | Later | Tooling |

### Application programming

| Gap | When | Why |
|---|---|---|
| Exact `Int`, floored `/` `%`, `Option` conversions (D5–D9) | **Before freeze** (S items), D6 before freezing `Int` | Decided semantics, not yet true |
| `String`/`Bytes` (D10/D11), one meaning across native and Sol | **Before freeze** | `strlen` disagrees today |
| Indexing never traps (D3) | Before freeze for the names; the warnings and discharge can come later | Names and types change |
| Error context (structured `Err` types across std) | Later | Additive per module |
| `parMap`/`parFold` | Later (experimental) | Explicit functions are additive |
| Persistence (`Persistent a` or `Live.field` journals) | Later | [DESIGN-GOALS-AUDIT](2026-10-15-DESIGN-GOALS-AUDIT.md) item 2 |
| Safe-by-default apps | Ongoing | `unsafe` file headers: terra-ii 21 of 21 `.fpr`, qrepo 3 of 5, examples 10 of 50, inventory 0 of 2, grapher 0 of 17 |

## 3. Inconsistencies

### Docs against the implementation

- **SEMANTICS.md is stale in at least five places.** `Int` "wraps silently"
  (native traps). "Equality gives up at 64" (no cap, `runtime.c:4880`). String
  indexing "one-based" (zero-based since 2026-10-02). `codegenRev 8` (257).
  Reserved words differ from the lexer.
- **26 of SEMANTICS.md's 51 distinct test file targets are missing**, among them every
  `tests/check_*.py` and `tools/sol-*-check.py` it cites, and QOS tests such as
  `tests/sysdisk.fpr` and `tests/uartsvc.fpr`. There are 16 empty
  `[test: ]` slots and 22 `(decide` markers. By the file's own rule ("a clause
  without a test is a proposal"), most of the contract is now a proposal.
- **D5–D12 are recorded as decided but not implemented** (§1). Docs that still
  assert the old behaviour are listed in FAILURE-MODES item 18.
- **"No ARC in Base" against ARC builtins and the message ARC table.** `sendArc`,
  `Rc.*` and `arcLive` remain in `builtinEnv`.

### Surface against surface

- **The prelude `List` and `std/list` disagree on argument order.** Prelude
  `List.take l n` (`core/prelude.fpr`) against std `take n xs`. Folds differ
  too ([census](2026-11-18-STD-USAGE-CENSUS.md#semantic-mismatches); terra-ii
  uses only the prelude form).
- **Three `min`/`max`/`abs`/`mod`.** Prelude `Int.min/max/abs/mod`,
  `std/math` `min/max/abs/mod/rem` (`std/math.fpr:12–48`), and `%`. The census
  found all of `std/math` unused.
- **Two `VList`s.** The prelude `VList` is a `Struct` over `Vector Int`
  (`core/prelude.fpr:733`). The `List 1` proposal uses "VList" for a
  VList-backed linear list.
- **Two preludes and two builtin tables.** `core/prelude.fpr` and
  `compiler/Sol/Preamble.hs` both declare `Vector 1`, `MutMap 1`, `FixedMap 1`.
  `Infer.hs` `builtinEnv` (357 entries) and `Sol/Infer.hs` `solBuiltins` type the
  same operations separately.
- **Builtin naming has no convention.** `mutmapInsert`, `sstrNew`, `BITSET`,
  `band`, `strcat`, `reg32` sit beside namespaced `Vec.*`, `I64.*`, `Sys.*`.
- **`parseInt` (lenient, `0` on junk natively, panics in Sol) beside `S.toInt` (`Result`)**
  (FAILURE-MODES string table).
- **`Map` against `HashMap`.** Jack's direction is a HAMT `Map`. Today `Map` is the tree
  and the HAMT is `HashMap`, with identical APIs except iteration order.
- **std holds application modules.** `printeralerts`, `printertelemetry`,
  `printeralertcodes`, eight `browser*` modules, `javascript`, `tangnano20k`,
  `esp` and `gitrevision` sit in the same namespace as `list` and `map`. The
  five linear and mutable modules (`bytes`, `fixedmap`, `hashmap`, `mutmap`,
  `vector`) are the only std modules off the safety allow-list
  (`compiler/Safety.hs`; known failures).

### Proposal against proposal

- **`List 1` → VList (proposal) against regions and copy-out (implemented).**
  Both claim the unbounded-list case. The spec should say which the language
  promises (bounded memory) and leave the backend unspecified.
- **WCET in the type system (decided 2026-11-01) against exact `Int` (D6).**
  These are reconciled only by D6 stage 2 (refuse unbounded `Int` in bounded
  code), which is not built.
- **`unsafe` file headers against "safe by default".** DESIGN-GOALS-AUDIT item 1
  is still open for terra-ii and qrepo.

## 4. Freeze plan

### Tier A: freeze now (implemented, tested or exercised, no open decision)

- Grammar core: clauses, guards, `case` (with the nested-case rule), `if`,
  blocks (every statement binds), lambdas, pipes, interpolation, `.`-terminated
  tops, zero-based positions.
- Deep structural equality with no depth limit.
- HM inference, records with row polymorphism, record update, typed paths,
  parametric sum types, tuples up to 8.
- Linear types: the `T 1` declaration, exactly-once per path, linear closures,
  record-update consumption (SEMANTICS §5).
- Safe/unsafe line and `measure`. Precondition syntax `(x : T | p)`; the
  fragment may grow compatibly.
- Resource contract vocabulary `work`/`alloc`/`live`, as syntax and meaning in
  abstract operations, not cycles.
- `Option`/`Result` conventions and data-last std argument order.
- Profiles and systems matrix (SEMANTICS §1, §20). `use`/pins/`fpr.toml`.

### Tier B: freeze after a decision or an implementation

Numerics (D5–D9 landed, D6 stage 1), strings and bytes (D10/D11), indexing (D3),
`Sig`/`Struct` semantics (abstract types, type-level conformance), effects,
typed actors, the memory-model text (reuse + regions; the fate of ARC), the
collection names (`Map`/`HashMap`, `VList`, prelude `List`), the frozen core std
list, the FFI/export ABI, the builtin profile.

### Tier C: experimental (outside the frozen spec)

`parMap`/`parFold`, the `List 1`/VList backend, cycle WCET and admission,
device Sigs, keyed-list and owned-map rewrites (`FPR_SHARED_MAP`), the Sol JIT,
live reload, the QOS ABI, and the finer Sol transaction rules.

## 5. Decisions for Jack

1. **Do D5, D7, D8, D9 and D12 land before the freeze?** (a) Implement them now
   (each S in FAILURE-MODES) and freeze numerics once D6 stage 1 lands. (b)
   Freeze the text now, marked "pending". **Recommend (a).** They are small,
   and `%`/`/` change program output.
2. **Interface mechanism.** (a) `Sig`/`Struct` stay explicit (`(s : Sig)`),
   with type-level conformance and abstract type members added. (b) Add
   implicit typeclass-style resolution. (c) Both. **Recommend (a) now.**
   Implicit resolution for `Eq`/`Ord`/`Show` can be added compatibly later.
3. **Effects.** (a) Keep effects untyped. (b) An inferred two-level effect
   (pure / effectful) carried on function types, reusing the row machinery.
   (c) Algebraic effects. **Recommend (b).** `parMap`, fusion and WCET R3 need
   purity, and it is breaking to add later.
4. **Actors.** (a) Keep `Int` handles. (b) A typed `Actor msg` with typed
   `receive`, and `Int` as an unsafe escape. **Recommend (b).**
5. **Builtin-profile memory.** (a) Keep manual RC + `ARC=1`. (b) Static arenas
   + regions, with ARC removed from the language spec and the interrupt contract
   decoupled from ARC. **Recommend (b),** consistent with 11 November.
6. **Sol.** (a) Sol is the `.fpr` language plus hosted effects, with identical
   meaning for shared operations (bytes, exact `Int`). (b) A separate dialect
   spec. **Recommend (a),** plus the native/Sol differential corpus (FAILURE-MODES item 1).
7. **std scope.** (a) Split into core (frozen), platform (`os*`, `tcp`, `gpio`, …)
   and application libraries (`printer*`, `browser*`, `javascript`, …) outside `std/`.
   (b) Keep one std. **Recommend (a).**
8. **Collection names.** Should `Map` become the HAMT (with the tree as
   `SortedMap`)? Should the prelude `VList` be renamed? Should the prelude
   `List` struct delegate to std's data-last order? **Recommend yes to all three.**
9. **Fixed-width family.** (a) Add `Byte` only. (b) `Byte` + `U8/U16/U32` +
   `Array n a`. **Recommend (a) before freeze and `Array n a` before freezing the bare-metal tier.**
10. **Distribution.** (a) Source-only packages identified by hash, with no
    binary ABI except exported Sigs and C exports. (b) Promise a binary ABI.
    **Recommend (a).** `codegenRev` moves with nearly every optimisation.
11. **Precondition fragment.** Is `len` (and `Vec.len`) an atom before the
    freeze? **Recommend yes.** D3's precondition form of indexing needs it.

## 6. Compiler refactor outlook

### What is there

236 Haskell modules, 65,555 lines under `compiler/`. The C runtime is 15,781
lines (`runtime/*.c`, `*.h`). Largest modules: `Infer.hs` 2476,
`Sol/VM.hs` 2361, `Sol/Txn.hs` 2112, `Codegen/Target/X64.hs` 1820,
`Compile.hs` 1742, `Codegen/Target/A64.hs` 1718, `Reuse.hs` 1584,
`Cost.hs` 1272, `Sol/Main.hs` 1173, `Codegen/Lower.hs` 1106. The Sol
subsystem is 31 modules and 12,146 lines in `compiler/Sol/`.

The pass order is in [PIPELINE-PASS-INVENTORY](2026-11-07-PIPELINE-PASS-INVENTORY.md):
checked typed passes, then a compatibility erasure (`Compiler.Native.Core`), then
an erased pass pipeline that still runs on every unit, then lowering. Pairs that
duplicate authority today:

| Typed | Erased / old | Lines (typed / old) |
|---|---|---|
| `Core/Typed/Fusion.hs` | `Core/Opt/Fusion.hs` (+ `Core/Opt/Vector.hs`) | 239 / 122 (+780) |
| `Core/Typed/Specialize.hs` | `Mono.hs` | 182 / 302 |
| `Core/Typed/Inline.hs` | `Inline.hs` | 223 / 309 |
| `Core/Typed/Normalize.hs` | `Core/Opt/Normalize.hs` | 158 / 183 |
| `Codegen/LowerTyped.hs` | `Codegen/Lower.hs` + `KernelKinds.hs` | 721 / 1106 + 122 |

Switches: 42 distinct `FPR_*` environment names are read in `compiler/` and `app/`,
31 of them `FPR_NO_*` kill switches (`compiler/Compiler/Options.hs:111` builds
them). The config-differential check runs 15 configurations
(`tests/sol-checks/config-differential.sol:9–18`). Some switches are read outside
`Options` (`Compile.hs:904` `FPR_NO_TYPED_LOWER`).

### How a frozen spec enables cleanup

- **Fewer semantics to preserve.** Today every rewrite must preserve the
  behaviour of three engines and of documented legacy forms. A frozen Tier A
  plus a conformance suite makes the suite the oracle, not the old pass.
- **Switches can become facts.** Once a feature is frozen, its `FPR_NO_*`
  switch is a debugging aid, not a semantic mode. Most configurations can then
  leave config-differential.
- **Name-level passes can move into the checker.** `Struct.hs` expansion
  before inference and `Precond.hs` before inference exist because the type
  checker did not own those features. Once their semantics are frozen, they
  become checker rules over typed Core.
- **One builtin table.** A frozen std/builtin surface lets `builtinEnv`,
  `solBuiltins`, `core/prelude.fpr` and `Sol/Preamble.hs` be generated from one source.

### Staged order

1. **R0: conformance suite (no spec dependency).** Wire `tests/*.fpr`
   language tests into a sol-check, and replace SEMANTICS.md's 26 dead
   targets with live ones. Add the native/Sol/JIT differential corpus
   (FAILURE-MODES item 1).
2. **R1: land the decided semantics.** D5/D7/D8/D9/D12 (S each), then D6
   stage 1 before more unboxing work (FAILURE-MODES says the same).
3. **R2: finish typed authority (pipeline P2).** Move let-bound closure
   specialisation and imported clones into typed passes (PIPELINE-REFACTORING-CHECKPOINT
   "Recommended next sequence" 2), then delete the five erased duplicates above
   and `KernelKinds`, gated on the compile budget.
4. **R3: one surface table.** Generate both preludes and both builtin tables.
   Namespace the bare primitives. Align the prelude `List` with std.
5. **R4: one representation and ownership planner (P3).** Fold `Workers`,
   `Reuse`, `Representation`, region placement and `Arc*` together. If decision
   5 removes ARC from the spec, `Arc.hs`/`Arc/` shrink to the builtin profile or go.
6. **R5: front end into the checker.** `Struct` and `Precond` become typed
   checks after decision 2. Linearity moves onto typed Core.
7. **R6: switch collapse.** Retire `FPR_NO_*` switches for frozen features,
   move every env read into `Compiler/Options.hs`, and shrink config-differential.
8. **R7: Sol on typed Core.** After decision 6, the VM and JIT consume the same
   checked Core, and Sol's separate builtin typing goes.

## Evidence

- Probes (outside the repo): `/tmp/probe/p1.fpr`, `p2.fpr`, built with the
  `912c4957` compiler. Output: `-1 -3`, then the `Int overflow` panic. `Ok 5`
  for `I64.toInt (I64.ofInt 5)`.
- Counts: `grep` over `docs/SEMANTICS.md` test targets (51 distinct file paths, 26 missing);
  `find compiler -name '*.hs' | xargs wc -l` (65,555); `FPR_*` and `FPR_NO_*`
  names via `grep -rhoE` over `compiler/` and `app/`; `unsafe` headers via
  `grep -l '^unsafe '` over the census clones at the SHAs in the census note.

# FP-RISC v1.0 core spec proposal

Date: 2026-11-19 (Australia/Sydney). Status: **proposal for Jack's decision**. No compiler code changed.

Companion to [the feature-set audit](2026-11-18-FEATURE-SET-AUDIT.md) (Page: https://cursor.com/canvas/store-fdd3dfac-2483-4a11-9493-f54c0b094376/a822a6aa-0b76-47cb-844b-8920680b0a48).
Evidence base: `main` at `5504e2cb`. Usage counts are word-match lines (comments included) over `std/`, `core/`, `examples/`, `tests/`, `sol/`, the bare-metal tree and four app repos: inventory `af2efed`, terra-ii `00cc105`, qrepo `2d78c8b`, grapher `018057d`. Dead-code evidence comes from weeder 2.11.0 over `.hie` files built with GHC 9.8.2, rooted at `app/Main.hs` `main`, plus `-Wunused-top-binds` / `-Wunused-imports`.

Jack's saved decisions are taken as given, not reopened: exact `Int` never overflows or traps; `I32.ofInt`/`I64.ofInt` return `Option`; `/` and `%` are floored with precondition `b /= 0`; `min / -1 = min` and `min % -1 = 0` on fixed widths; fixed widths wrap by contract with no checked/wrapping family (D4); indexing returns `Option` or carries a precondition; partial operations fail visibly; memory is in-place reuse plus regions with copy-out, with no ARC in Base; raw words only for proven-small `Int` locals, `F64` always raw, raw fields only for fields declared `I64`; the platform calling convention is kept; `List 1` gets a VList backend when linear; `parMap`/`parFold` are explicit; `Map` is a HAMT with a `Map 1` path; the WCET reference is cached-SDRAM simple-risc; D10 (`String` is valid UTF-8, `Bytes` holds any bytes); D11 (renames happen in one change, with no aliases).

---

## 1. Primitive types

### 1.1 The v1.0 list

| Type | Meaning | Representation | Status today |
|---|---|---|---|
| `Int` | Exact integer (Haskell `Integer`) | Small: tagged immediate `(n<<1)\|1` in uniform slots (63-bit on RV64/x64/A64, 31-bit on RV32). Raw machine word when proven small. Big: heap bignum. | Exact semantics, but overflow **traps** (verified probe). There is no bignum yet. |
| `I8` `I16` `I32` `I64` | Two's-complement fixed width, wrapping | Raw in registers. Raw in fields declared with that type (decided for `I64`; same rule extended). Boxed leaf only in uniform/polymorphic slots. | `I32`, `I64` exist. `I8`/`I16` are new. |
| `I128` | Same, 128-bit | Register pair; runtime helpers for `*` `/` on RV32/RV64 | New. **Decision Q14** |
| `F32` `F64` | IEEE 754 binary32/binary64 | Always raw (`F64` decided; `F32` the same) | Exist |
| `Bool` | Two values | Immediate everywhere (see 1.3). Raw 0/1 in registers and fields. | Today a pointer to the static objects `fpr_true`/`fpr_false` (`runtime/fpr.h:73,75`) |
| `Byte` | Unsigned octet 0..255; no arithmetic | Immediate; 1 byte in `Bytes` / packed fields | New (audit D10 needs it) |
| `Unit` | One value | Immediate | Static object `fpr_unit` today |
| `String` | Valid UTF-8 text (D10) | Heap, immutable | Exists |
| `Bytes` | Any octets (D10) | Heap; `Bytes 1` linear for in-place writes | Exists in std (`std/bytes.fpr`) and Sol Preamble |

**Not primitive in v1.0:**
- `Char`: code points are `Int` via `String.codes`.
- `Bit`: see 1.4.
- `Word`: merged; see 1.6.
- `Atom`: removed.
- U-types: replaced by unsigned operations; see 1.2.

### 1.2 `Int`: exact, raw fast path, promote on overflow

**Semantics.** Mathematical integers. `+ - *` are exact. `/` and `%` are floored with precondition `b /= 0` (decided). Comparisons and `==` are by value across both representations. A value is **normalised**: anything that fits the small range is always small, so equality on small values stays a word compare.

**Where tags remain.** Tagged immediates (low bit 1, `runtime/fpr.h:4,69-70`) remain in every uniform slot:
- `List` elements, type-variable fields, closure captures, `Map` keys and values, actor messages;
- any `Int` the interval analysis (`Codegen/Interval.hs`, 553 lines) cannot prove small.

A raw machine word is used only for locals and loop variables proven small (decided). A field declared `Int` stays tagged.

**Overflow detection.** On the tagged fast path the add is `add` then branch on overflow:
- x64: `jo`
- A64: `adds` + `b.vs`
- RISC-V: the 3-instruction `add`/`slt`/`xor` check

The slow path calls a runtime bignum constructor. On a raw proven-small local no check is emitted (that is what "proven" buys).

**GC / region pointer maps.** No change to the contract. A tagged small `Int` is a non-pointer by its tag bit. A bignum is an ordinary heap object with its own `typeid` (new `T_BIGINT`), so the existing typeid-directed walkers see it. Raw-word fields are already masked per constructor by `fpr_layout_raw_mask` (`runtime/fpr.h:23-27`). Bignums in a region are copied out like any boxed leaf.

**WCET / fuel.**
- Small ops keep today's cost model (`compiler/Cost.hs`).
- Every bignum op charges per limb (operand size), so fuel (`Sys.fuel*`) bounds it.
- The static WCET analyser treats any reachable promotion as unbounded unless the operand range is proven. That means a bounded unit must prove smallness (next point).

**No-heap / bounded units (WCET, ISR, `builtin` no-alloc).** Promotion is **forbidden**: the compiler must prove every `Int` operation stays small (interval analysis, or preconditions over `measure`d values), or reject the unit with "use `I32`/`I64`". This is D6 stage 2 from the audit, restated. Fixed widths are always legal there.

**Cost of the change.**
- One overflow branch per tagged `+ - *` that today traps. The trap branch already exists (probe: `Int` overflow traps), so the instruction count is the same; only the target changes from trap to slow path.
- New runtime: about one bignum module (add/sub/mul/divmod/compare/str/parse).
- `Sol` must match (audit decision 6).

### 1.3 `Bool`, `Unit` and other immediates

Jack wants `Bool` unboxed. Today `BOOL(b)` returns `&fpr_true`/`&fpr_false`.

A Bool tagged like `Int` (0/1 with low bit 1) would be indistinguishable from `Int` in a polymorphic slot. Polymorphic `str` and `==` read the typeid today.

**Proposal: a second immediate class.** Heap objects are 8-aligned (`fpr.h:5`), so the low 3 bits of a pointer are 000.
- `xx1` = small `Int` (unchanged).
- `010` = small immediates with a 5-bit type code above it: `Unit`, `Bool`, `Byte`, empty `List`, and nullary constructors of user ADTs (where an ADT has only nullary constructors).
- `000` = pointer.

Pointer maps treat `010` as a non-pointer. This removes the static-object loads for `True`/`False`/`Unit`/`[]` and gives `Byte` a free representation. **Decision Q12.**

### 1.4 `Bit` and `Byte`

- **`Bit` is not a type.** One bit is `Bool`. Packed bits are a storage concern:
  - a field width in a `Layout` declaration (MMIO registers), or
  - a packed `Vector Bool` / `Bytes`.

  `Word.bitSet`/`bitClear`/`bitTest` become `I32`/`I64` operations `setBit`/`clearBit`/`testBit` with precondition `0 <= i < width`.
- **`Byte`** is an octet, not a number:
  - Comparisons, `land/lor/lxor/lnot`, and shifts within 8 bits.
  - `Byte.toInt : Byte -> Int` (total), `Byte.ofInt : Int -> Option Byte`, `Byte.truncI32 : I32 -> Byte` (low 8 bits, named so it is visible).
  - No `+`. Byte arithmetic goes through `Int` or `I32`.
  - It is the element type of `Bytes` and of `Mem.read8`/`write8`.

  **Decision Q13** (whether `Byte` gets wrapping `+`).

### 1.5 Fixed widths: no U-types

Recommend **no `U8..U128`**. A distinct unsigned family doubles the conversion matrix (5 widths × 2 signs) for little gain. Wasm, Java and OCaml use signed storage plus unsigned operations.

Each `In` provides unsigned interpretations:
- `divU`, `remU` (precondition `b /= 0`);
- `ltU`, `leU`, `compareU`;
- `shrU` (logical shift right), with `shr` arithmetic;
- `toIntU : In -> Int` (zero-extending) beside `toInt` (sign-extending);
- `ofIntU : Int -> Option In` (accepts `0 .. 2^n-1`).

`Byte` covers the one unsigned type with real demand (D10).

**Shift amounts (Decision Q15).** Options:
- (a) precondition `0 <= k < n`;
- (b) mask `k mod n` like x86/RISC-V hardware.

Recommend (a). It is consistent with "partial operations fail visibly", and the precondition is free when `k` is a literal.

### 1.6 `Word` and `Addr`

`Word` is the machine word (XLEN), so its meaning changes by target. That is the imprecision Jack flagged. Its 16 prims:

`Word.fromInt toInt bits and or xor add sub not shl shr mask eq bitSet bitClear bitTest`

These map to `I32`/`I64` operations with the same names (plus `shrU`). `Mem.readWord`/`writeWord` become `Mem.read32/read64` and `write32/write64`; `Mem.read8`/`write8` take `Byte`.

`Addr` stays: an opaque pointer-sized type in the Builtin **unsafe** tier, with no arithmetic except `Addr.add : Addr -> I64 -> Addr`. Its other prims, `Addr.fromWord`/`Addr.toWord`, become `Addr.ofI64`/`toI64` (the XLEN cast is now explicit and checked on RV32).

Migration: `Word` appears in 121 test lines, 7 example lines, 54 lines in the bare-metal tree, and none in std or apps.

### 1.7 Floats: F8–F128, honestly

| Type | Recommendation | Why |
|---|---|---|
| `F32`, `F64` | **Core** | Hardware on all three hosted targets; existing users: `F64` 274 test lines and 62 in examples, `F32` 56 tests and 14 examples |
| `F16` (IEEE binary16) | **Decision Q14**; recommend storage + convert only in v1.0 | A64 has native F16, x64 only F16C convert (AVX-512 FP16 aside), RV needs Zfh. Arithmetic would be software on most targets. |
| `BF16` | Optional storage-only kernel type | No IEEE semantics to freeze; convert to/from `F32` only |
| `F8` | **Omit** from v1.0 | Two incompatible formats, E4M3 and E5M2 (E4M3 has no infinity); no scalar hardware outside accelerators. If needed later, as `F8E4M3`/`F8E5M2` storage types. |
| `F128` | **Omit** from v1.0 | Software emulation on every target (quad on RV only with Q extension, absent on our boards) |

**Float semantics:**
- IEEE round-to-nearest-even, with NaN ≠ NaN.
- `F.compare` is a total order (NaN last).
- There is no `%` (`F.rem` is named).
- `F.toInt : F64 -> Option Int` (None on NaN/inf), with `truncate`/`floor`/`round` as named `F64 -> F64`.
- The software `sqrt` added on main (`5504e2cb`) is the RV fallback.

### 1.8 Conversions matrix

✓ = total, ? = returns `Option`, T = named truncation (`truncN`, keeps low bits), — = not provided.

| from \ to | Int | I8 | I16 | I32 | I64 | I128 | F32 | F64 | Byte | Bool |
|---|---|---|---|---|---|---|---|---|---|---|
| **Int** | – | ? T | ? T | ? T (`ofInt` decided) | ? T (decided) | ? T | ✓ round | ✓ round | ? T | — |
| **I8–I128** | ✓ (`toInt`, and `toIntU`) | widen ✓ / narrow ? T | | | | | ✓ round | ✓ (exact up to I32) | ? T | — |
| **F32/F64** | ? | ? | ? | ? | ? | ? | F64→F32 round ✓, F32→F64 ✓ | | — | — |
| **Byte** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | – | — |
| **Bool** | — | — | — | — | — | — | — | — | — | – |

- No implicit conversions anywhere.
- `Bool` has no numeric view (`if b then 1 else 0`).
- Literals are typed by context (`5 : I32` legal).

**Decision Q16:** whether the `T` (named truncation) functions exist or narrowing is `Option`-only. Recommend they exist, since bare-metal code needs low-byte extraction.

### 1.9 Arithmetic semantics per type

| Op | `Int` | `I8..I128` | `F32/F64` | `Byte` |
|---|---|---|---|---|
| `+ - *` | exact (promotes) | wrap (decided) | IEEE | — (Q13) |
| `/` `%` | floored, pre `b/=0` (decided) | floored, pre `b/=0`, `min / -1 = min`, `min % -1 = 0` (decided) | `/` IEEE; no `%` | — |
| `quot` `rem` | truncated, pre `b/=0` | truncated, same min rules | — | — |
| `divU remU ltU shrU` | — | yes (1.5) | — | n/a (already unsigned) |
| shifts | `shl`/`shr` exact, pre `k>=0` | pre `0<=k<n` (Q15) | — | within 8 bits |
| bit ops | two's-complement infinite (like Haskell `Bits Integer`) | yes | — | yes |
| `==`/`compare` | by value | signed (`compareU` unsigned) | IEEE `==`, total `compare` | unsigned |

**Gaps between this table and today's compiler:**
- `Int` overflow traps instead of promoting.
- `%`/`/` are truncated: probe `-7 % 2 = -1`, `-7 / 2 = -3` (audit D5).
- `min / -1` traps (`runtime/runtime.c:6118`, `i32.c:19`).
- `I64.ofInt` returns `I64`, not `Option`.

These are D5/D7/D8/D9/D12 from the audit and have to land before the freeze (Q1).

### 1.10 Keep / rename / merge / remove for every type in the compiler today

Type names from `compiler/Type/Syntax.hs` TCs, `core/prelude.fpr` and `compiler/Sol/Preamble.hs`.

| Type | Verdict | Into | Migration (lines that mention it) |
|---|---|---|---|
| `Int` | keep, semantics change (promote) | – | everywhere; no source change |
| `I32`, `I64` | keep, add unsigned ops | – | `I32` std 20 / tests 117 / grapher 29; `I64` examples 61 / tests 133 |
| `F32`, `F64` | keep | – | – |
| `Bool`, `Unit` | keep, representation change (1.3) | – | none |
| `String` | keep (D10) | – | – |
| `Result`, `Option`, `List` | keep, Core data | – | – |
| `I8`, `I16`, `I128`, `Byte` | **add** | – | 0 |
| `Word` | **merge** | `I32`/`I64` + unsigned ops | tests 121, examples 7, bare-metal 54, std/apps 0 |
| `Addr` | keep (Builtin unsafe) | – | tests 42, examples 3, bare-metal 37, sol 3 |
| `Atom` (`:x`) | **remove** | ADT constructors / `String` | about 1 std, 1 test, 13 sol; 0 apps |
| `SString` | **merge** (Q19) | fixed-capacity `Bytes 1` | core 4, tests 4 |
| `Vector`/`Vec` | **rename to one name** (Q18) | see Q18 | `Vector`: std 20, core 5, ex 18, tests 151, terra 3, qrepo 1, grapher 9. `Vec` (prim prefix): std 19, core 15, ex 52, tests 773, sol 159, terra 5, qrepo 7, grapher 25 |
| `VList` (prelude struct, `core/prelude.fpr:733`) | **remove** | VList is now the `List 1` backend (decided) | core 4, tests 6 |
| `MutMap` | **merge** | `Map 1` (decided HAMT mutable path) | std 55, tests 121, inventory 16 |
| `HashMap` (`std/hashmap`) | **becomes** `Map` | – | std 7, tests 28 |
| tree `Map` (`std/map`) | **rename** `SortedMap` (Q17) | – | `use std/map`: examples 13, tests 16, qrepo 3; 19 std importers |
| `FixedMap` | keep (no-growth linear; insert returns `Option`) | – | std 28, tests 76 |
| `Set` | **remove** | `List` / `Map k Unit` | std 35, tests 4, qrepo 33 (2 files `use std/set`), std/view |
| `Bytes` | keep (D10), move into Builtin types | – | std 9, tests 37, inv 3, terra 8, grapher 13, bare-metal 6, sol 5 |
| `Handle` (prelude) | move to Base | – | core 5, tests 1 |
| `Wire` (prelude) | move to `std/wire` (Builtin lib) | – | std 76, core 13 |
| `LogSt` (prelude) | move to the QOS live host file | – | prelude 13 |
| `Rc` prims | **remove** with ARC (decided) | regions | tests 43 |
| Sol `FsError FsKind WalkEntry ShError` | keep, Base (Sol host) | – | – |
| Sol Preamble duplicate `Vector 1`/`MutMap 1`/`FixedMap 1` | **delete** the duplicates; import the one definition | – | `compiler/Sol/Preamble.hs` |

### 1.11 Core data types

- **Core:** tuples, records, ADTs, functions, `Option a`, `Result e a`, `Ordering`.
  - `Option` is Core because Core primitives return it (`ofInt`, `F.toInt`).
- **Builtin:** `List a` (persistent; VList backend when `List 1`), `String`, `Bytes`, `Vector a` (contiguous, `Vector 1` in-place), `Map k v` (HAMT, `Map 1`), `SortedMap k v`, `FixedMap 1 k v`.

No `Set`, `Char`, `Atom`, `Word`, `HashMap`, `MutMap`, `VList` or `SString` names in v1.0.

---

## 2. Layers

### 2.1 Definitions

| Layer | Contains | Allocation | Profiles that may use it |
|---|---|---|---|
| **Core** | The language: functions, records, ADTs, pattern matching, `Sig`/`Struct`, preconditions/`measure`, linearity, the primitive types of §1 and their operations, `Option`/`Result`/`Ordering` | Values may allocate (closures, ADTs, bignums); no allocator API | all |
| **Builtin** | Bare-metal runtime: the allocator (bump/buddy, arenas, regions with copy-out, in-place reuse), `List`/`String`/`Bytes`/`Vector`/`Map`/`SortedMap`/`FixedMap`, pure libraries, `print`, `test`. **Unsafe tier** inside it: `Addr`, `Mem.*`, `CPU.*`, MMIO (`reg8/reg32/device/read/write`), `Sys.irq*`/`timer*`/`arena`/`poolReset`, board packages | Explicit arenas/regions; no GC daemon | `builtin`, `base`, `extbase`, `sol` |
| **Base** | OS programming: files, processes, clocks, sockets, TLS, HTTP, MQTT, logging, persistence, actors and supervision, `parMap`/`parFold` on harts | plus OS heap | `base`, `extbase`, `sol` |
| **ExtBase** | End-to-end apps: MVU, views/UI, browser, live reload, sessions | – | `extbase`, `sol` |

**Restricted modes:**
- **WCET, no-heap and bare-metal units may use only Core + Builtin.** That means no Base imports and no actors unless Q4 puts actors in Builtin.
- In no-heap units, additionally:
  - `Int` promotion is forbidden (1.2);
  - `List`/`Map`/`String` construction is forbidden unless inside a region with a static bound;
  - `Option`/`Result` returns must be scalar-replaced (the existing `PairReturns`/`VariantReturns` passes), otherwise the unit is rejected.

**Where the cross-cutting features sit:**
- **Regions:** Core semantics are unaffected (memory is unobservable). The region runtime and copy-out are Builtin.
- **`parMap`/`parFold`:** Core *meaning* (equal to `map`/`fold` on pure functions, so it needs the purity effect, Q3). Parallel execution is Base (needs harts/actors). On Builtin it runs sequentially.
- **Actors** (`spawn*`, `send*`, `receive*`, `myself`, `yield`, `kill`, `harts`, `sched*`, `fuel*`): **Decision Q4b.** Recommend Base, with a minimal **Builtin** cooperative scheduler for bare-metal (`spawn`/`send`/`receive`/`yield` with static mailboxes).
- **Sol:** not a layer. It is the hosted profile: Core + Builtin + Base + ExtBase, plus Sol's transaction effects (`Sol/Txn.hs`), with identical meaning on shared operations (audit decision 6).
- **QOS live module reload** (`Mod.*`, `Sys.log*`, `Sys.spawnApp`, `Sys.growLog`, `Mod.detachLast`): moves out of `builtinEnv` into a QOS host file loaded with `--foreign`.

### 2.2 Std modules: all 107

Line counts from `wc -l`. Transitive OS/UI/actor/machine signals come from scanning imports and prim use.

| Layer | # | Lines | Modules |
|---|---|---|---|
| Core | 3 | 160 | `option`, `result`, `order` |
| Builtin (pure libs and collections) | 19 | 3,243 | `list`, `string`, `map` (→ `sortedmap`, Q17), `hashmap` (→ `map`), `json`, `decode`, `wire`, `path`, `lens`, `binary`, `encoding`, `pagination`, `math` (merge into the `Int`/`F64` structs), `bytes`, `vector`, `mutmap` (→ `Map 1`), `fixedmap`, `keyedlist`, `test` |
| Builtin unsafe / board | 3 | 421 | `gpio`, `tangnano20k/fat`, `tangnano20k/sd` |
| Base | 44 | 5,206 | `os`, `osio`, `osfs`, `osnet`, `oswatch`, `osconnection`, `file`, `dir`, `clock`, `log`, `logfile`, `stream`, `poller`, `proc`, `tcp`, `http`, `httpcore`, `httpclient`, `tls`, `crypto`, `resolver`, `transport`, `sockettransport`, `connect`, `ownedtransport`, `watchedtransport`, `readiness`, `ws`, `mqtt`, `mqttclient`, `mqttsession`, `ownedmqtt`, `digest`, `config`, `program`, `term`, `actor`, `supervisor`, `task`, `job`, `kvlog`, `store`, `journal`, `durable` |
| Base, device host | 3 | 120 | `esp`, `wifi`, `ble` |
| ExtBase | 27 | 5,571 | `mvu`, `view`, `ui`, `appearance`, `viewcache`, `live`, `livejs`, `livereload`, `livemetrics`, `livenotice`, `javascript`, `browser`, `browserautocomplete`, `browsercalc`, `browserconsole`, `browserfeedback`, `browserformfill`, `browsermedia`, `browserstorage`, `clientcalc`, `money`, `watch`, `reload`, `reloadcatalog`, `native`, `sessionauth`, `game` |
| Remove | 1 | 54 | `set` (users: qrepo 2 files, 1 test, `std/view`) |
| Move out of std (app-specific) | 6 | 293 | `printeralertcodes`, `printeralerts`, `printertelemetry`, `gitrevision`, `checkdemo`, `mjpeg` |
| Umbrella | 1 | 50 | `std` (re-export list; split per layer) |

Checks:
- None of the 22 Core/Builtin-pure modules has a transitive OS, UI, actor or machine signal. `encoding`, `bytes`, `vector`, `mutmap`, `fixedmap` and `keyedlist` use linearity only.
- `mqtt`, `mqttsession` and `game` have no OS signal. They are pure codecs, so they could drop to Builtin if a bare-metal MQTT client is wanted.

### 2.3 Builtin prims: all 355 in `builtinEnv` (`compiler/Infer.hs:445–875`)

By prefix: bare 112, `I32` 50, `Vec` 41, `I64` 38, `Sys` 35, `Word` 16, `Mem` 15, `F64` 11, `F32` 11, `Mod` 10, `CPU` 7, `Addr` 6, `Rc` 2, `String` 1.

By target layer (scan heuristic, `scan/std_layers.py`):

| Layer | # | What | Action |
|---|---|---|---|
| Core | 140 | `I32.*`, `I64.*`, `F32.*`, `F64.*`, bit ops, `str`/`strcat`/`strlen`/`charAt`/`chr`/`substr`/`str*`, hashes, `error`, `!`, `$cast`, `intMax`/`intMin` | Keep. Rename bare string prims into `String.*` (D11, one change). `intMax`/`intMin` are **removed** (meaningless for exact `Int`; use `I64.max`). `$cast` stays compiler-internal. |
| Builtin | 88 | `Vec.*`, `mutmap*`, `fixedmap*`, `sstr*`, sorts, `node*`, `heapUsed`, `drop`/`keep`, `print` | Keep. `mutmap*` → `Map 1`. `sstr*` → `Bytes 1` (Q19). |
| Builtin unsafe (machine) | 64 | `Word.*` (16), `Addr.*` (6), `Mem.*` (15), `CPU.*` (7), `Rc.*` (2), `reg8/reg32/device/read/write`, `Sys.irq*/timer*/arena/poolReset/memStats/memInfo/stkStats` | Remove `Word.*` (→ `I32`/`I64`) and `Rc.*` (no ARC). Keep the rest. |
| Base: actors | 34 | `spawn*`/`send*`/`receive*`/`myself`/`yield`/`kill`/`harts`/`sched*`/`fuel*`/`arcLive`/`Sys.actLive`/`nextId`/`actInfo`/`loop`/`loopWith` | Base (Q4b). Remove `sendArc` and `arcLive` (ARC). |
| Base: OS | 14 | `file*`, `Sys.args/name/exit/env/readLine/stderr/timeUs/sleepUs/mtime/uptimeMs` | Keep |
| Move out (QOS live) | 15 | `Mod.*` (10), `Sys.logStage/logStaged/logInstall/logger`, `Sys.spawnApp`, `Sys.growLog`, `Mod.detachLast` | `--foreign` QOS host file |

Sol's extra builtins (`compiler/Sol/Preamble.hs`, 452 lines) are Base (Sol host) and are not part of the 355.

---

## 3. Open decisions for Jack

Only open questions are listed. Each has a recommendation. Q1–Q11 are the audit's questions, updated.

| # | Question | Options | Recommend |
|---|---|---|---|
| Q1 | Land D5/D7/D8/D9/D12 **and Int promotion** before freezing numerics? | (a) implement first; (b) freeze text marked pending | (a). `%`/`/` change program output, and promotion replaces today's trap. |
| Q2 | Interface mechanism | (a) explicit `Sig`/`Struct` + type-level conformance; (b) implicit typeclasses; (c) both | (a) |
| Q3 | Effects | (a) untyped; (b) inferred pure/effectful bit; (c) algebraic | (b). `parMap` meaning, fusion and WCET need it. |
| Q4 | Actors: (a) typing: keep `Int` handles, or typed `Actor msg`; (b) layer: Base only, or a minimal Builtin scheduler | – | typed `Actor msg`; Base, plus a minimal Builtin cooperative scheduler |
| Q5 | Builtin memory | (a) manual RC + `ARC=1`; (b) static arenas + regions, with ARC deleted | (b). Matches the saved decision. Unblocks deleting `Arc*`. |
| Q6 | Sol | (a) same language + hosted effects; (b) separate dialect | (a) |
| Q7 | std scope | split per §2.2 vs one std | split |
| Q8 | Collection names | `HashMap`→`Map`, tree→`SortedMap`, remove prelude `VList`, prelude `List` data-last | yes to all (Q17 carries the rename) |
| Q9 | Fixed-width family (**updated**) | (a) `Byte` + `I8..I128`, no U-types (§1.5); (b) add `U8..U64` | (a), plus `Array n a` before freezing the unsafe tier |
| Q10 | Distribution | source-only by hash vs binary ABI | source-only |
| Q11 | `len` / `Vec.len` as precondition atoms | yes/no | yes |
| Q12 | Second immediate class (`010` tag) for `Bool`/`Unit`/`Byte`/`[]`/nullary constructors | (a) yes; (b) keep static objects; (c) tag `Bool` like `Int` and rely on monomorphisation | (a) |
| Q13 | `Byte` arithmetic | (a) none, convert through `Int`/`I32`; (b) wrapping `+ - *` | (a) |
| Q14 | Float and wide-int set | `F16` arith / storage-only / omit; `BF16` storage; `F8`, `F128`, `I128` | `F16` storage + convert, `BF16` storage, omit `F8`/`F128`, include `I128` |
| Q15 | Shift amount out of range | (a) precondition; (b) mask | (a) |
| Q16 | Named truncations `truncN` | (a) provide; (b) `Option`-only narrowing | (a) |
| Q17 | Tree map name | `SortedMap` / `OrdMap` / keep `Map` as tree | `SortedMap` |
| Q18 | One name for the contiguous array | `Vector` (type) + `Vector.*` (ops), or `Vec` for both | `Vector` everywhere. `Vec.` has 773 test-line uses vs 151 for `Vector`, but the rename is mechanical (D11, one change), and a type name and module name that match is the rule elsewhere. If churn matters more, `Vec` for both. |
| Q19 | `SString` | (a) merge into `Bytes 1` with fixed capacity; (b) keep | (a). 8 lines use it. |
| Q20 | JIT tier (`Sol/JitCore` 421, `Sol/HandJIT` 390, `Sol/AsmA64` 146, `Sol/AsmX64` 176 = 1,133 lines) | (a) keep as the Sol hot-path; (b) drop and keep the bytecode VM + AOT | Decide by measurement. The architecture review (`docs/2026-11-18-COMPILER-ARCHITECTURE-REVIEW.md` finding 1) shows it duplicates the AOT emitters. Recommend (b) unless a Sol benchmark depends on it. |
| Q21 | `math` module | merge into `Int`/`F64` structs vs keep | merge |

---

## 4. Pipeline cleanup and deletion map

### 4.1 Current pipeline (`compiler/`, lines)

1. **Front end (surface AST):**
   - `Modules` 518, `Frontend/Paths` 310, `Lexer` 145, `Parser` 758, `Normalize` 189;
   - `Struct` 334, `Precond` 643, `Infer` 2,477, `Safety` 650, `Linearity` 668;
   - `Desugar/Typed` 576, `Desugar` 628;
   - surface rewrites: `KeyedListFold` 763, `OwnedMapFold` 257, `ListRewrites` 164;
   - `MemoryLayout` 90.
2. **Typed Core passes:** `Close` 305, `ListFusion` 1,067, `Specialize` 182, `Inline` 223, `CaseKnown` 110, `VectorRead` 28, `Normalize` 158, `Fusion` 239, `Trmc` 343, `Monomorphize` 180, `Layout` 75, `Erase` 423.
3. **Erasure boundary:** `Compiler/Native/Core` 255, `Regions` 195, `Linked` 224.
4. **Erased Core pipeline:** `Core/Opt/Pipeline` 299 driving:
   - `Core/Opt/Fusion` 122, `Core/Opt/Vector` 780, `Core/Opt/Normalize` 183;
   - `Workers` 717, `Reuse` 1,584, `PairReturns` 262, `Mono` 302, `Inline` 309;
   - `Arc` 334, `Arc/Uniform` 123, `Arc/Products` 318;
   - `Representation` 1,057, `KernelKinds` 122.
5. **Lowering:**
   - **two lowerings run side by side**: erased `Codegen/Lower` 1,106 and `Codegen/LowerTyped` 721 (with `Compiler/Native/TypedLowering`);
   - `Simplify` 600, `Interval` 553, `LoopOptimize` 242, `Pressure` 111, `Liveness` 251, `Allocate` 692, `Frame` 61, `Bounds` 252, `Stack` 122, `Heap` 154.
6. **Targets:** `Target/X64` 1,820, `Target/A64` 1,718, `Target/RV` 809.
7. **Drivers:** `Compile` 1,742, `Codegen` 788, `Cost` 1,272, `StdBridge` 401, `StdCheck` 1,001.
8. **Sol:** 31 modules, 12,148 lines (VM 2,362, Txn 2,112, Main 1,173).

The typed lowering is checked against the erased one per function (`Compile.hs:895–925`). A difference prints `typed lowering disagreement` and stops the compile. `FPR_NO_TYPED_LOWER=1` skips the check and emits the erased functions.

Known open failures under `no_reuse` on `loopcalls`/`vecinline`:
- `docs/perf/2026-11-17-REGALLOC-DESIGN.md:128`
- `docs/perf/2026-11-17-OVERHEAD-ROUND2.md:117`

### 4.2 Target pipeline

```
Parse ─► Check (names, Struct/Sig, Infer, Precond, Linearity, Safety; one pass manager)
     ─► Typed Core  (desugar once; all rewrites here: KeyedListFold, OwnedMapFold,
                     ListRewrites, ListFusion, Fusion, Specialize, Inline, CaseKnown, Trmc, Monomorphize)
     ─► Plan        (one representation + ownership planner: raw/tagged per §1.2,
                     regions, reuse, workers, pair/variant returns; no ARC)
     ─► Lower (typed only) ─► Simplify/Interval/LoopOptimize ─► RegAlloc ─► Select {X64, A64, RV}
```

**What changes:**
- One lowering instead of two.
- Rewrites move off the surface AST.
- The erased optimiser's duplicates go.
- Representation decisions live in one planner instead of three places (`Representation` 1,057, `Compiler/Native/Representation`, `Core/Opt/Representation`).

### 4.3 Switches

`compiler/Compiler/Options.hs:111` builds **34** feature kill-switches as `enabled n = not (FPR_NO_<n>=1)`:

`BUMP_ALLOC CALL_REGIONS CASE_KNOWN F64_INLINE FIELD_WORKERS INDEXED_MEMORY INLINE INTERVAL KEYED_LIST_FOLD LIST_FUSE LOOP_REGIONS OWNED_MAP_FOLD PAIR_RETURNS PERSISTENT_COPY_OUT PIPELINE_INLINE RECEIVE_TURNS REUSE SCALAR_WORKERS SHALLOW_STACK SNOC_FOLD SPEC STR_FAST TICK_BATCH TICK_WEIGHT TRMC TUPLE_SCALARS TYPED_CASE TYPE_SPEC VEC_FAST VEC_FUSE VEC_PEEK VEC_SIMD X64_RA X64_SPLIT`

(The audit's figure of 31 counted literal `FPR_NO_` strings.)

There are further reads outside `Options`:
- `FPR_NO_TYPED_LOWER` (2 reads in `Compile.hs`);
- `FPR_NO_SPEC` (read again directly, duplicating `SPEC`);
- `FPR_NO_RUN_CACHE`.

There are also 14 `FPR_TYPED_IR_*` tuning flags:
- default on: `SELF_LOOPS`, `FP_POOL`, `LINK_PAIRS`, `STRING_SCAN`, `EARLY_LOOPS`;
- opt-in: `FORWARD_PARAMS`, `SHALLOW_STACK`, `ENTRY_ARGS`, `SPLIT_ENTRY`, `SHRINK_WRAP`, `LOOP_MOTION`, `FRAMELESS_ENTRY`;
- plus `BACKEND`, `STRICT`.

The config differential (`tests/sol-checks/config-differential.sol:9–18`) exercises 15 configurations:

`default`, `no_interval`, `no_inline`, `no_spec`, `no_reuse`, `no_workers`, `no_vec`, `no_str`, `no_regions`, `no_x64_ra`, `no_x64_split`, `no_shallow`, `harts4`, `no_list_rewrites`, `shared_map`

The differential switches off 17 of the 34 kill-switches. `VEC_FUSE`/`VEC_FAST`/`VEC_SIMD`, the two worker switches, the two region switches and the two list-rewrite switches are only switched off together.

The other 17 are never switched off by it: `BUMP_ALLOC CASE_KNOWN F64_INLINE INDEXED_MEMORY LIST_FUSE OWNED_MAP_FOLD PAIR_RETURNS PERSISTENT_COPY_OUT PIPELINE_INLINE RECEIVE_TURNS TICK_BATCH TICK_WEIGHT TRMC TUPLE_SCALARS TYPED_CASE TYPE_SPEC VEC_PEEK`

**Proposal:**
- **After the freeze**, collapse to:
  - `-O0` (no optimisation, the reference semantics);
  - `-O` (everything);
  - a small set of *diagnostic* bisect switches (`FPR_DISABLE=pass1,pass2`, one generic mechanism);
  - `FPR_HARTS`.
- The cfgdiff becomes `-O0` vs `-O` vs `harts4` vs a rotating `FPR_DISABLE=<one pass>`.
- Opt-in `FPR_TYPED_IR_*` flags either become default (with a benchmark note) or are deleted with their code paths.

### 4.4 Deletion map

| Item | Size | Evidence | Tier |
|---|---|---|---|
| `compiler/Target.hs` (`Profile`, `profileOf`, `profileNote`) | 38 lines + `fp-risc.cabal:247` | imported by no module; `Build.hs` has its own `profileOf` | **delete now (safe)** |
| Unreachable, unreferenced declarations | **121 declarations in 60 files, ~558 lines** (appendix A1) | weeder rooted at `app/Main.hs` `main`; no word match in `tests/*.hs` or `app/`; no TemplateHaskell in `compiler/` | **delete now (safe)**, each confirmed by `cabal build all` after deletion. Largest block: the `StdCheck.hs` demo (`mainProg`, `runFn`, `stdcheckDemo`, `runCase`, fixtures; ~240 lines) |
| `-Wunused-top-binds` | 6 sites in `compiler/` (`Arc.hs:132,219`, `Codegen/LowerTyped.hs:152`, `Codegen/Target/A64.hs:146`, `Compile.hs:1531`, `Core/Opt/Pipeline.hs:185`), 1 in tests | GHC | **delete now (safe)** |
| `-Wunused-imports` | 54 sites in `compiler/`, 27 in `tests/`, 1 in `app/` | GHC | **delete now (safe)** |
| Root relics `dispatch.sol` (558 B), `SPLIT-SOURCE.json` (149 B) | 2 files | architecture review finding 9. `README.md` mentions `dispatch.sol`, and a copy lives at `sol/examples/dispatch.sol` | **delete now**, with the README line updated |
| Sol Preamble duplicate `Vector 1`/`MutMap 1`/`FixedMap 1` | – | duplicates `core/prelude.fpr` | delete now if Sol builds against the prelude; else after freeze |
| Test-only hooks | 99 declarations, ~329 lines (appendix A2) | unreachable from `fpr`, used only by `tests/*.hs` | **after freeze**, as their tests move to the conformance suite |
| `Word.*` (16 prims), `Atom`, `Set`, `VList`, `SString`, `intMax`/`intMin`, `Rc.*`, `sendArc`/`arcLive`, `Mod.*`/`Sys.log*` in `builtinEnv` | see §1.10 / §2.3 | spec decisions | **after freeze** (one D11 change per family) |
| 34 `FPR_NO_*` switches → `-O0`/`-O` + `FPR_DISABLE` | `Options.hs` and every `cg*` guard | §4.3 | **after freeze** |
| Opt-in `FPR_TYPED_IR_*` paths | 7 flags | §4.3 | **after freeze** (make default or delete) |
| ARC: `Arc` 334, `Arc/Uniform` 123, `Arc/Products` 318 (775) + runtime RC | – | Q5; typed-lowering census still counts `arc=` users | **needs replacement first** (regions/reuse cover every `arc` user, shown by census `arc=0`) |
| Erased lowering `Codegen/Lower` 1,106 + the agreement check | – | typed lowering is checked against it | **needs replacement first**: fix the `no_reuse` `loopcalls`/`vecinline` disagreement, reach census `refused=0 absent=0` on the full corpus, then delete `Lower` and `FPR_NO_TYPED_LOWER` |
| Erased optimiser duplicates: `Core/Opt/Fusion` 122, `Core/Opt/Vector` 780, `Core/Opt/Normalize` 183, `Mono` 302, `Inline` 309, `KernelKinds` 122 | 1,818 lines | typed passes `Fusion`, `ListFusion`, `Normalize`, `Monomorphize`, `Inline` cover the same ground before erasure | **needs replacement first** (typed lowering covers everything; then remove each erased pass, with cfgdiff green after each) |
| Surface rewrites `KeyedListFold` 763, `OwnedMapFold` 257, `ListRewrites` 164 | 1,184 lines | run on the surface AST before typing | **needs replacement first**: port to typed Core rules, then delete |
| Three representation modules | 1,057 + 2 others | §4.2 | **needs replacement first** (one planner) |
| JIT tier | 1,133 lines | Q20 | **after decision Q20** |
| Duplicate cache-key derivations (5), Sol txn loops (3), `checkedInterface` re-entering via argv (`Compile.hs:204`) | – | architecture review findings 2, 4, 5 | after freeze (refactor, not deletion) |
| `deploy/`, printer tools; `printer*`, `gitrevision`, `checkdemo`, `mjpeg` std modules | 6 std modules / 293 lines | review finding 8, §2.2 | after freeze (move to their projects) |

**Delete-now set:**
- `Target.hs` (38 lines);
- 121 unreachable declarations (~558 lines, overlapping `Target.hs`'s two);
- 6 unused top binds;
- 54 compiler unused imports;
- 2 root relics.

That is roughly 600 lines of Haskell plus 82 import lines, with no behaviour change. The weeder method can miss names used only through GHCi or external scripts, so each deletion is gated by a full build and test run.

### 4.5 Staged order

0. **Conformance suite first.** One `.fpr` case per spec clause (§1.8–1.9 tables, layer restrictions, Option-returning conversions, `min / -1`, Int promotion boundaries) with `.expected` output. It runs under native (x64/A64/RV) and Sol (audit FAILURE-MODES item 1). This is the regression net for everything below.
1. **Delete now** (§4.4 safe rows): one PR, no behaviour change.
2. **Land the numeric fixes:** D5/D7/D8/D9/D12, Int promotion with the bignum runtime, the `010` immediates. Freeze §1.
3. **Spec renames/removals** (D11, one change each): `Word`→`In`, `Atom`, `Set`, `VList`, `SString`, `MutMap`→`Map 1`, `HashMap`→`Map`, `Map`→`SortedMap`, `Vec`/`Vector`, `Rc`/ARC prims, QOS prims to `--foreign`. Freeze §2 layers and split std.
4. **Typed lowering only:** fix the `no_reuse` disagreement → census clean → delete `Codegen/Lower` and the agreement check.
5. **Delete the erased duplicates** pass by pass, then ARC once census `arc=0`.
6. **Move the surface rewrites to typed Core**; merge the representation planners.
7. **Collapse the switches** to `-O0`/`-O`/`FPR_DISABLE`; shrink cfgdiff to match.
8. **JIT decision (Q20)**, then the driver split of `Compile.hs` (review finding 10).

---

## Appendix: dead-code evidence

Method:
- GHC 9.8.2 with `-fwrite-ide-info`, building the library and test suites.
- `app/Main.hs` was compiled separately so `Main.hie` is the `fpr` executable, not a test main.
- weeder 2.11.0 rooted at `Main.main` (type-class instances are roots by default).
- Each unreachable name was then matched as a word against `tests/*.hs` and `app/`.
- Spans are estimated from each definition line (plus signature) to the next top-level line.

### A1. Unreachable from `fpr` and unreferenced by tests/app: 121 declarations in 60 files (~558 lines)

| File | Declarations (line) |
|---|---|
| `compiler/StdCheck.hs` | `.+.` (190), `.-.` (191), `.*.` (192), `./.` (193), `runFn` (686), `factNaiveBad` (831), `safeCallsUnsafe` (841), `mainProg` (851), `runCase` (940), `stdcheckDemo` (952) |
| `compiler/Infer.hs` | `tyToType` (368), `inferPat` (940), `typecheck` (1776), `inferTops` (1816), `inferTopsWith` (1819) |
| `compiler/Ownership/Shape.hs` | `demandL` (122), `constraintMark` (125), `isConstraintMark` (128), `projectLShape` (176), `updateLShape` (179) |
| `compiler/Arc.hs` | `lowerRaw` (186), `lowerRawWith` (189), `lowerRawWithOptions` (193), `exposeScalarConstructors` (219) |
| `compiler/Codegen.hs` | `emitProgramWithSymbols` (455), `emitProgramWithImports` (460), `emitCheckedProgramWithImports` (472), `emitProductProgramWithImports` (475) |
| `compiler/Core/Opt/PairReturns.hs` | `pairWorker` (33), `pairWorkerName` (36), `pairReturnProgram` (216), `productReturnProgram` (219) |
| `compiler/Core/Typed/Close.hs` | `closedGlobals` (34), `libraryContracts` (48), `importClosedCode` (61), `importClosedLibrary` (64) |
| `compiler/Frontend/Desugar/Checked.hs` | `desugarCheckedUnitWith` (40), `lowerCheckedUnitWith` (44), `desugarSpecializedWith` (49), `lowerSpecializedWith` (53) |
| `compiler/Interrupt.hs` | `checkInterrupt` (21), `checkInterruptWithStorage` (24), `checkRawUnit` (52), `checkRawUnitWithStorage` (55) |
| `compiler/Codegen/Target/Common.hs` | `shallowReserve` (97), `stringObject` (209), `bumpCell` (418) |
| `compiler/Compiler/Native/Core.hs` | `nativeFresh` (38), `specializeNativePrograms` (126), `fuseListNativePrograms` (156) |
| `compiler/Core/Typed/Callback.hs` | `specializeCallbacksWith` (47), `specializeFromCatalog` (57), `specializeClosedFromCatalog` (64) |
| `compiler/Core/Typed/Pipeline.hs` | `specializePrograms` (85), `inlinePrograms` (135), `fuseListPrograms` (238) |
| `compiler/Frontend/Linearity.hs` | `primNames` (77), `shapeOfTy` (119), `lcheckOnce` (249) |
| `compiler/Representation.hs` | `represent` (357), `representWithOwnership` (380), `representWithEvidence` (394) |
| `compiler/Sol/VM.hs` | `toInts` (980), `fromInts` (985), `newBStrTable` (1022) |
| `compiler/Sol/Val.hs` | `isUnit` (97), `bsByteLen` (191), `isStrVal` (244) |
| `compiler/Struct.hs` | `sigFieldNames` (56), `substStruct` (121), `structPass` (329) |
| `compiler/Codegen/Calling.hs` | `secondResultRegister` (34), `selectPairTransfer` (117) |
| `compiler/Codegen/Liveness.hs` | `containsPos` (86), `crossesPos` (90) |
| `compiler/Codegen/Target/A64.hs` | `callerSaved` (146), `scratchPool` (151) |
| `compiler/Core/Opt/Pipeline.hs` | `optimizeCoreWithImports` (60), `localProducts` (185) |
| `compiler/Core/Pretty.hs` | `pretty` (13), `prettyProg` (31) |
| `compiler/Frontend/Desugar.hs` | `boolT` (65), `tupWideBase` (288) |
| `compiler/Manifest.hs` | `_unused` (122), `_unused2` (125) |
| `compiler/Target.hs` | `profileOf` (24), `profileNote` (33) |
| `compiler/Codegen/Dump.hs` | `dumpProgram` (13) |
| `compiler/Codegen/Eval.hs` | `rvInt` (29) |
| `compiler/Codegen/IR.hs` | `wrap63` (574) |
| `compiler/Codegen/Opcode.hs` | `textOpcode` (24) |
| `compiler/Codegen/Protocol.hs` | `keepingEntry` (64) |
| `compiler/Codegen/Simplify.hs` | `defaultOptions` (48) |
| `compiler/Codegen/Target/X64.hs` | `scratchPool` (137) |
| `compiler/Compile.hs` | `splitOn` (1531) |
| `compiler/Compiler/Native/Imports.hs` | `declarationCode` (26) |
| `compiler/Compiler/Native/Linked.hs` | `fuseListLinked` (202) |
| `compiler/Compiler/Native/Regions/Typed.hs` | `programFallback` (31) |
| `compiler/Compiler/Native/Representation.hs` | `signaturesFor` (27) |
| `compiler/Compiler/Native/TypedLowering.hs` | `reportNote` (149) |
| `compiler/Compiler/VectorLayout.hs` | `layoutEvidenceType` (21) |
| `compiler/Core/Opt/Fusion.hs` | `fuseVecFix` (31) |
| `compiler/Core/Opt/Vector.hs` | `nestPipelines` (86) |
| `compiler/Core/Typed/Fusion.hs` | `renderDecline` (28) |
| `compiler/Core/Typed/Inline.hs` | `inlineClosed` (96) |
| `compiler/Core/Typed/ListFusion.hs` | `fuseListClosed` (62) |
| `compiler/Core/Typed/Monomorphize.hs` | `monomorphizeKeepingEntriesWithOrigins` (93) |
| `compiler/Cost.hs` | `_unusedRatio` (1228) |
| `compiler/Diagnostic/Render.hs` | `locatedDiagnostic` (16) |
| `compiler/Frontend/Normalize.hs` | `adHeadName` (170) |
| `compiler/Frontend/Syntax.hs` | `guardBools` (66) |
| `compiler/Infer/Result.hs` | `inferenceLayoutRequirements` (68) |
| `compiler/Ownership/Finding.hs` | `renderLegacyFinding` (12) |
| `compiler/Precond.hs` | `isMeasureP` (116) |
| `compiler/Sol/Bytecode.hs` | `arithNames` (85) |
| `compiler/Sol/Infer.hs` | `inferTops` (46) |
| `compiler/Sol/Lang.hs` | `mapGuardP` (41) |
| `compiler/Sol/Main.hs` | `parseOrDie` (991) |
| `compiler/Sol/Slice.hs` | `slicePrelude` (87) |
| `compiler/Sol/Txn.hs` | `resetTx` (180) |
| `compiler/Sol/Web.hs` | `jsonV` (381) |

### A2. Unreachable from `fpr` but used by tests/*.hs: 99 declarations in 47 files (~329 lines)

These are test hooks. They stay until the Haskell test that uses them is replaced by a conformance case.

| File | Count |
|---|---|
| `compiler/Frontend/Desugar/Checked.hs` | 11 |
| `compiler/Arc.hs` | 7 |
| `compiler/Workers.hs` | 5 |
| `compiler/Representation.hs` | 4 |
| `compiler/Codegen/Simplify.hs` | 3 |
| `compiler/Compiler/Native/Core.hs` | 3 |
| `compiler/Compiler/Native/Regions.hs` | 3 |
| `compiler/Core/CacheIdentity.hs` | 3 |
| `compiler/Core/Typed/Stage.hs` | 3 |
| `compiler/Frontend/Desugar/Typed.hs` | 3 |
| `compiler/Reuse.hs` | 3 |
| `compiler/StdCheck.hs` | 3 |
| `compiler/Codegen.hs` | 2 |
| `compiler/Codegen/Eval.hs` | 2 |
| `compiler/Codegen/NativeData.hs` | 2 |
| `compiler/Codegen/Target/A64.hs` | 2 |
| `compiler/Codegen/Target/X64.hs` | 2 |
| `compiler/Compiler/Native/Imports.hs` | 2 |
| `compiler/Compiler/Native/Linked.hs` | 2 |
| `compiler/Compiler/Native/Regions/Typed.hs` | 2 |
| `compiler/Core/Opt/Pipeline.hs` | 2 |
| `compiler/Core/Region/Interface.hs` | 2 |
| `compiler/Core/Typed/Callback.hs` | 2 |
| `compiler/Core/Typed/Monomorphize.hs` | 2 |
| `compiler/Infer/Result.hs` | 2 |
| `compiler/Arc/Uniform.hs` | 1 |
| `compiler/Codegen/Place.hs` | 1 |
| `compiler/Codegen/Selected.hs` | 1 |
| `compiler/Codegen/Target/Common.hs` | 1 |
| `compiler/Codegen/Target/RV.hs` | 1 |
| `compiler/Compiler/Native/Exports.hs` | 1 |
| `compiler/Compiler/Native/Representation.hs` | 1 |
| `compiler/Core/Opt/ProductParameters.hs` | 1 |
| `compiler/Core/Region/CallSites.hs` | 1 |
| `compiler/Core/Typed/Callback/Catalog.hs` | 1 |
| `compiler/Core/Typed/Close.hs` | 1 |
| `compiler/Core/Typed/Contract.hs` | 1 |
| `compiler/Core/Typed/Erase.hs` | 1 |
| `compiler/Core/Typed/Fusion.hs` | 1 |
| `compiler/Core/Typed/Program.hs` | 1 |
| `compiler/Core/Typed/Specialize.hs` | 1 |
| `compiler/Diagnostic/Render.hs` | 1 |
| `compiler/Frontend/Desugar.hs` | 1 |
| `compiler/Frontend/Linearity.hs` | 1 |
| `compiler/Infer.hs` | 1 |
| `compiler/Representation/Types.hs` | 1 |
| `compiler/Safety.hs` | 1 |

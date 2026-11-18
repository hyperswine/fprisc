# Std and builtin usage census (2026-11-18)

A read-only census of what the compiler, the prelude and `std/` actually
provide, what the examples and the four FP-RISC apps use, and where those
programs reimplement something that already exists. No app or compiler code
was changed.

Scripts and intermediate tables live outside the repo, in `/workspace/census/`
and `/workspace/out/census-CHECKPOINT.md`. Counts come from a scan of the
trees named below, not from memory.

## Scope

| tree | `origin/main` SHA | what was scanned |
|---|---|---|
| [hyperswine/fprisc](https://github.com/hyperswine/fprisc) | `89a09f86` (merge of #103) | `compiler/Infer.hs` `builtinEnv` / `builtinCons'`, `compiler/Core/Primitives.hs`, `core/prelude.fpr`, `std/*.fpr` (107 modules), `examples/**/*.fpr` (50 files) |
| [hyperswine/inventory](https://github.com/hyperswine/inventory) | `af2efed` (merge of #3; includes typed `Op` `ad339c23`) | `src/inventory.fpr`, `tests/check.fpr` |
| [hyperswine/terra-ii](https://github.com/hyperswine/terra-ii) | `00cc105` (merge of #1) | 21 `.fpr` files under `src/`, `models/`, `tests/` |
| [hyperswine/qrepo](https://github.com/hyperswine/qrepo) | `2d78c8b` (merge of #3) | `qr.fpr`, `text.fpr`, `merge.fpr`, `tests/*.fpr` |
| [hyperswine/grapher](https://github.com/hyperswine/grapher) | `018057d` | `cli/`, `desktop/`, `lib/points.fpr`, plus 13 tiny compiler-negative / runtime tests |

`examples/inventory.fpr` (1070 lines) is a related snapshot of the inventory
app, not the same file as the repo (`src/inventory.fpr`, 1155 lines). Helpers
that appear in both are one invention, counted once under the app and noted
again under examples.

Other FP-RISC repos exist under the same owner (dungeon, logbook, printer)
and were not part of this census.

## Method

- Builtins: every `("name", …)` entry in `builtinEnv` (Infer.hs:444–874) and
  `builtinCons'`, plus the opcode names reconstructed from
  `Core.Primitives`.
- Prelude and std: every top-level type, sig, struct (with fields), function
  and constant in `core/prelude.fpr` and `std/**/*.fpr`.
- Usage: comment-stripped tokens in each `.fpr` file. `Alias = use "std/list"`
  attributes `Alias.filter` to `std/list.fpr::filter`. A lowercase head
  (`m.items`) is record access, not a module. Function-arrow `->` and pipe
  `|>` are syntax, not library hits. Arithmetic and comparison operators are
  counted separately as `builtin/op`.
- Local helpers were compared to std/prelude/builtins by name and then by
  reading the body at the cited line. Name collisions that do not reimplement
  a library operation (domain `count`, `get`, `head`, `unique` meaning "all
  distinct", qrepo `none = -1`) are called out as non-matches, not as swaps.

## Headline counts

| corpus | `.fpr` files | lines | std hits | std modules used | prelude hits (named) | local top-level bindings |
|---|---:|---:|---:|---:|---:|---:|
| examples | 50 | 9087 | 4814 | 72 (see appendix) | 1845 including ops, of which `and`/`or`/`not` are 225+182+108 | 1790 |
| inventory (app + test) | 2 | 1207 | 831 | 27 | 105 | 207 + 7 in the test |
| terra-ii | 21 | 2943 | 113 (102 of them `std/game`) | 4 | 376, including 16 `List.len`, 10 `List.map`, 26 `Int.min`, 24 `Int.max` | 528 |
| qrepo | 5 | 1617 | 838 | 12 | 258 | 270 |
| grapher | 17 | 316 | 34 | 6 | 95 | 62 |

Library inventory, on fprisc `89a09f86`:

- **354** compiler HAL/runtime primitives in `builtinEnv`, plus **14**
  builtin constructors (`Unit`, `True`, `False`, `Nil`, `Cons`, `Ok`, `Err`,
  `Tup2`–`Tup8`).
- **16** core opcode prims (`+ - * / == != < > <= >= strcat str error print
  String.len !`), plus generated `F32.*` / `F64.*`, `$mem.*` and `$scalar.*`.
- **Prelude** (`core/prelude.fpr`, prepended to every program): 135
  functions, 7 types, 8 structs, 6 sigs.
- **Std:** 107 `.fpr` modules, 2609 top-level functions/constants, 194 types.
  **75** of those modules have at least one qualified use in this corpus;
  **32** have none.

The single most used std modules, hits across the whole corpus:

| module | hits | where |
|---|---:|---|
| `std/list` | 1174 | examples 752, inventory 146, qrepo 256, grapher 20; **terra-ii: 0** |
| `std/ui` | 882 | examples 630, inventory 248, terra-ii 4 |
| `std/view` | 732 | examples 660, inventory 72 |
| `std/json` | 638 | examples 302, inventory 93, qrepo 240, grapher 3 |
| `std/option` | 588 | examples 456, inventory 58, terra-ii 3, qrepo 71 |
| `std/javascript` | 573 | examples only |
| `std/string` | 411 | examples 258, inventory 69, qrepo 83, grapher 1; **terra-ii: 0** |

terra-ii is the outlier: it never `use`s `std/list` or `std/string`. List
operations go through the **prelude** `List` structure (`List.map`,
`List.fold`, `List.take`, `List.drop`, `List.len`), whose argument order is
not the std one. See [Semantic mismatches](#semantic-mismatches).

## 1. What exists

### Compiler builtins (`builtinEnv`, 354 names)

Grouped by prefix (counts are the number of entries, not uses):

| prefix | count | role |
|---|---:|---|
| unqualified | 112 | `str`, `strcat`, `strlen`, `charAt`, `chr`, `substr`, `strJoin`, `strCompare`, `strFindByte`, `strFindSpace`, `strDigits`, `print`, `error`, `intMin`, `intMax`, file and actor prims, `Vec` engines used via `sortVecWith` / `sortListWith`, MutMap/FixedMap C engines, bit ops, `heapUsed`, … |
| `I32.*` | 50 | unboxed 32-bit int |
| `Vec.*` | 41 | linear vectors (`new`, `push`, `get`, `set`, `at`, `put`, `len`, `map`, `fold`, `filter`, `fromList`, `toList`, `free`, `split`, plus numeric kernels) |
| `I64.*` | 38 | 64-bit two's-complement (always-raw fast type) |
| `Sys.*` | 34 | args, env, time, exit, stderr, … |
| `Word.*` | 16 | machine words |
| `Mem.*` | 15 | alloc / read / write / atomics |
| `F64.*` / `F32.*` | 11 + 11 | float arith, `str`, `sqrt`, `ofInt`, `toInt`, `log`, `exp`, `sin`, `cos`, `pow` |
| `Mod.*` | 10 | module registry |
| `CPU.*` | 7 | irq / csr / wait |
| `Addr.*` | 6 | addresses |
| `Rc.*` | 2 | retain / release |
| `String.len` | 1 | alias of `strlen` |

Language types in `Type.Syntax`: `Int`, `String`, `Bool`, `Unit`, `F64`,
`F32`, `I64`, `I32`, `List`, `Vector`, `MutMap`, `FixedMap`, `SString`,
`Word`, `Addr`, plus `Result` as a wired-in constructor type (`Ok` / `Err`).
`Option` is **not** a compiler builtin; it is declared in `std/option.fpr`.

`Core.Primitives` is the small opcode set the backends know: integer and
comparison ops, `strcat`, `str`, `error`, `print`, `String.len`, list
index `!`, float ops, `$strcatT`, `$mem.read/write*at`, `$scalar.*`.

### Prelude (`core/prelude.fpr`)

Types: `Handle 1`, `Vector 1 a`, `MutMap 1 k v`, `FixedMap 1 k v`,
`SString 1`, `Wire` (`WInt|WStr|WBool|WList|WRec|WCon`), `LogSt`.

Sigs: `Arith`, `Add`, `Eq`, `Ord`, `Functor`, `Seq`.

Structs (the names programs write as `Int.min`, `Str.len`, `List.take`):

- `Int`: arith, `abs`, `min`, `max`, `mod`, `neg`, `pow`
- `Str`: `+`, `-`, `==`, `len`, `at`, `fromCode`, `parse`
- `List`: `fold`, `map`, `+`, `-`, `zero`, `len`, `take`, `drop`
- `SStr`, `VList`, `Actor`, `Mod`, `Sys`

Plus boolean `and` / `or` / `not`, wire codecs (`wireInt`, `wireToInt`, …),
string helpers (`strCmp`, `strIndexOf`, `strIndexFrom`, `strTake`, …), the
list loops behind the `List` structure (`listMap`, `listFold`, `listLen`,
`listTake`, `listDrop`, `listAppend`, `fromTo`, `mapV`, `zipV`, …), and
actor helpers (`serve`, `ask`, `par2`, `heapUsed`).

### Std (107 modules)

The complete used-or-not table is in the [appendix](#appendix-std-module-hit-counts).
Core collection and numeric modules and whether this corpus touches them:

| module | hits in this corpus |
|---|---:|
| `std/list` | 1174 |
| `std/string` | 411 |
| `std/option` | 588 |
| `std/json` | 638 |
| `std/map` | 170 |
| `std/result` | 66 (examples only) |
| `std/order` | 55 |
| `std/set` | 46 (qrepo only) |
| `std/mutmap` | 16 (inventory only) |
| `std/math` | **0** |
| `std/vector` | **0** (apps call `Vec.*` prims instead) |
| `std/keyedlist` | **0** (new in #103; no app import yet) |
| `std/fixedmap` | **0** |
| `std/bytes` | **0** |
| `std/hashmap` | **0** |
| `std.fpr` (`Std.fold` / `clamp` / `retry` / `backoff`) | **0** |

## 2. Usage by app

### inventory (`af2efed`)

27 std modules. Heaviest: `ui` 248, `list` 146, `json` 93, `view` 72,
`string` 69, `option` 58, `clock` 24, `browsercalc` 17, `mutmap` 16, `live`
13. Top names: `List.length` 33, `Json.Text` 32, `List.map` 29, `S.trim` 26,
`UI.stack` 26, `Option.None` 23, `Option.Some` 22, `List.filter` 19.

It already uses a lot of std well (`List.sortBy`, `List.unique`,
`List.filterMap`, `S.split`, `S.words`, `S.contains`, `Option.andThen`,
`MutMap.insert` / `get` / `member`). It still carries a pos1-shaped private
string/int kit (`strEq`, `imax`, `num`, `isDig`, `clip`, `lower`) — see
below.

### pos1 (`examples/pos1.fpr`, 958 lines) and the other examples

pos1 imports the same live/ui/view/list/string/option/result cluster as
inventory. The other 49 example files are how most of std actually gets
used: printer-dashboard, logbook, mconf, antivirus, wasm, livereload, ideal,
swarm, tangnano, etc. `std/result` (66 hits) and `std/javascript` (573) and
`std/term` (70) appear only in examples, not in the four apps.

### terra-ii (`00cc105`)

`std/game` 102, `std/option` 3, `std/actor` 4, `std/ui` 4. No `std/list`,
no `std/string`, no `std/math`. List and string work is prelude + a local
`src/prelude.fpr`. The headless test also `use`s QOS modules that are **not**
in fprisc std: `std/storage`, `std/blockio`, `std/fs` (10 references in
`tests/headless/game.fpr`).

### qrepo (`2d78c8b`)

Uses std the way the library is meant to be used: `list` 256, `json` 240,
`string` 83, `option` 71, `map` 58, `set` 46, `program` 29, `order` 27, plus
`clock`, `stream`, `proc`, `poller`, `tcp`, `binary`. `S.toInt` is used at
three sites in `qr.fpr`. Host file IO is a file-local `Qfs.*` signature
block (`qr.fpr:19–40`), not a std module.

### grapher (`018057d`)

Small. Production sources are `cli/main.fpr`, `cli/features.fpr`,
`desktop/main.fpr`, `lib/points.fpr`. Std use is almost all `List.map` /
`List.range` / `List.length`. Vectors go through `Vec.*` prims
(`fromList` 7, `free` 7, `toList` 6, `iota` 5, …), never `std/vector`.
I32 is used as the point coordinate type (`I32.ofInt` 11). The 13 files
under `tests/negative` and `tests/runtime` are compiler tests a few lines
long; they are in the file count but do not drive the library picture.

## 3. Duplicates and custom reimplementations

Ranked by how many **call sites in the four apps + pos1** a swap would
remove. `examples/inventory.fpr` repeats the inventory helpers; those extra
sites are in the last column only. Definitions are included in the "sites"
count.

| rank | local helper | sites (apps + pos1) | also in `examples/inventory.fpr` | library equivalent | drop-in? |
|---:|---|---:|---:|---|---|
| 1 | `strEq a b = a == b` | **85** (inventory `src/inventory.fpr:129`, 44 calls; pos1 `examples/pos1.fpr:79`, 39 calls; plus 2 defs) | 51 calls + 1 def | `==` on `String` (builtin / prelude `Eq`) | **yes**. There is no `std` `strEq`. The wrapper is the only thing standing in front of `==`. |
| 2 | `num` / `numGo` (prefix digit parse → `Int`) | **35** (inventory `:133`, 7 calls; pos1 `:154`, 26 calls; plus 2 defs) | 7 calls + 1 def | `String.toInt` / prelude `wireInt` | **no** — see mismatches |
| 3 | `lower s = S.toLower s` | **26** (inventory `:148`, 25 calls + def) | 28 + def | `S.toLower` | **yes**, it already is a synonym |
| 4 | terra-ii test `count` (`tests/headless/game.fpr:28`) | **19** calls + 1 def | — | `List.length` | **yes**, if the test imported `std/list`. Today it walks the list itself. |
| 5 | `clip n s` (truncate to at most `n` bytes) | **15** (inventory `:146`, 14 calls + def) | 14 + def | `S.left` (`std/string.fpr:173`, `substr s 0 n`) | **yes** for the non-negative literal widths used here (32, 60, 100, 120, 2000). `substr` clamps, so `left` on a short string is the whole string, same as `clip`. |
| 6 | `imax` | **15** (inventory `:131`, 10 calls + def; pos1 `:168`, 3 calls + def) | 9 + def | `Int.max` (prelude) or `Math.max` (`std/math.fpr:22`) | **yes**. Same `a > b` test. |
| 7 | `foldE` (pos1 `:102`) | **11** (10 calls + def) | — | `List.fold` with the lambda arguments flipped, or prelude `List.fold` | **not a missing function** — see mismatches |
| 8 | `imin` (pos1 `:170`) | **5** (4 calls + def) | — | `Int.min` / `Math.min` | **yes** |
| 9 | `isDig` | **6** (inventory `:138`, 1 call + def; pos1 `:195`, 3 calls + def) | 1 + def | `S.isDigit` (`std/string.fpr:259`, `c >= 48 and c <= 57`) | **yes**, the bodies are the same. Unused as `S.isDigit` anywhere in this corpus. |
| 10 | `words` (pos1 `:159`, `words s = S.words s`) | **3** (2 calls + def) | — | `S.words` | **yes**, synonym |
| 11 | grapher `contains` (`lib/points.fpr:30`) | **4** (3 calls + def) | — | `List.member (point x y) points` | **yes** if `==` on `(I32, I32)` is the same test the helper uses (it is: `p == point x y`) |
| 12 | terra-ii test `isErr` (`tests/headless/game.fpr:175`) | **3** (2 calls + def) | — | `not (Result.isOk r)`; `std/result` has `isOk` and no `isErr` | almost; needs a `std/result` import. Candidate to add `isErr`. |
| 13 | swarm `clamp` (`examples/swarm.fpr:91`) | 1 def + its call sites in that file | — | `Math.clamp` / prelude `Int.max`/`Int.min` / `std.fpr` `clampInt` | **yes**, same lo/hi clamp. `std/math` is never imported in this corpus. |
| 14 | `isDigit` in `examples/tangnano20k_fact.fpr:17` and `examples/wasm/wat.fpr:40` | 1 + 6 calls | — | `S.isDigit` | **yes** |
| 15 | `isSpace` in `examples/wasm/wat.fpr:39` (2 calls) | 3 | — | `S.isSpace` (`std/string.fpr:189`) | **almost** — see mismatches |

### Custom list surgery in terra-ii (no std equivalent today)

`terra-ii/src/prelude.fpr` is an `unsafe module` of list/int helpers. None of
these are drop-in replacements for something already in `std/list`, except
`rev` and `clampTo`:

| helper | site | what it does | std/prelude today |
|---|---|---|---|
| `nth l i d` | `src/prelude.fpr:6` (2 in-module uses; other files call `Pr.nth`) | index with a **default** on OOB / `Nil` | `List.get i xs` returns `Option a`. A swap is `Option.withDefault d (List.get i l)` — same answer, different failure policy at the call site (no `Option` to match on). |
| `setAt l i v` | `:11` | replace at index; OOB is a no-op (returns the list, or `Nil` if it was empty) | **not in std**. Candidate. |
| `delAt l i` | `:16` | drop the element at index; OOB is a no-op | **not in std**. Candidate (`removeAt`). `examples/ideal/todo.fpr:38` builds the same idea from `List.indexed` + `List.filter`. |
| `split l n acc` | `:28` | `splitAt`, accumulator API, returns `(taken, rest)` | **not in std**. Candidate. The recent terra-ii change already uses prelude `List.take` to trim hands (`rules.fpr:189` `trim l n = List.take l n`). |
| `rev l acc` | `:21` (`l |> List.fold (fn x xs -> x :: xs) acc`) | reverse-onto | `std/list` `revOnto` (internal-looking but identical). `List.append (List.reverse l) acc` is the public spelling. pos1 has the same helper (`examples/pos1.fpr:152`, 4 calls) over `foldE`. |
| `clampTo v hi` | `:32` (`Int.max 0 (Int.min hi v)`) | clamp to `0..hi` | already written in terms of prelude `Int.min`/`Int.max`. `Math.clamp 0 hi v` is the std spelling, unused. |
| `bi` | `:23` | `True→1`, `False→0` | no std equivalent; tiny. Also appears in pos1 (3 calls). |
| `rnd` | `:26` | LCG, `% 2147483648` | no std random. Not a duplicate. |
| `trim` | `src/rules.fpr:189` | `List.take l n` | already a one-line synonym of **prelude** `List.take` (list first, then `n`) |

`src/game.fpr:104` `lines` logs a list of strings; it is not `S.lines`.

### Things that look like duplicates and are not

- **qrepo `get` / `head` / `removeAt` / `none`** (`qr.fpr:75`, `:128`, `:879`;
  `text.fpr:101`): repo-path IO and `none = 0 - 1`, a sentinel, not
  `Option.None`.
- **printer-dashboard `care.fpr:44` `unique`:**
  `L.length (L.unique xs) == L.length xs` — "are all elements distinct", not
  `List.unique`.
- **framebuffer `append`, registry/service `get`, ideal/todo `count`:**
  domain wrappers around std or host calls.
- **Client.pane, Model.zoom, Qfs.read, FrameHost.append:** record or host
  fields, not missing std modules.

### Cross-app helpers that should move into std

These are used in more than one program and are **not** in std today:

1. **`List.setAt` / `List.removeAt` / `List.splitAt`** — terra-ii's prelude,
   with the OOB-is-a-no-op policy documented (or an `Option` variant, if std
   should stay consistent with `List.get`). `removeAt` is reinvented in a
   different shape in `examples/ideal/todo.fpr:38`. This is the strongest
   "add to std" cluster.
2. **`List.getWithDefault`** (terra `nth`) — one-liner over `List.get` +
   `Option.withDefault`, but it is the API the game actually wants.
3. **`Result.isErr`** — `std/result` already has `isOk` (`result.fpr:23`)
   and no `isErr`. The terra-ii headless test defines it.
4. **Do not add `strEq`, `imax`, `imin`, `isDig`, `clip`, `lower`, `words`.**
   They already exist under other names (`==`, `Int.max`/`Int.min`,
   `S.isDigit`, `S.left`, `S.toLower`, `S.words`). The work is to delete the
   wrappers, not to grow std.
5. **Do not add `num` as a second integer parser** until the failure policy
   is chosen (see below). `S.toInt` is the total, `Result`-returning parse
   of a whole string. qrepo already uses it.

Shared pos1-family kit (`strEq`, `imax`, `num`, `isDig`, and inventory's
`clip`/`lower`) is duplicated between pos1 and inventory because inventory
was shaped like pos1, not because std is missing those names.

## Semantic mismatches

These are the swaps that are **not** mechanical.

**Prelude `List` vs `std/list` — argument order.** The prelude structure
(`core/prelude.fpr:701`) is:

- `List.take l n` / `List.drop l n` (list first)
- `List.len l` (not `length`)
- `List.fold f z l` with `f : a -> b -> b` (element first; see `listFold`,
  which does `f x z`)
- `List.map f l` (same order as std)

`std/list` is:

- `List.take n xs` / `List.drop n xs` (count first, `list.fpr:234`)
- `List.length xs`
- `List.fold f z xs` with `f : b -> a -> b` (accumulator first, `:177`)

terra-ii talks only to the prelude structure, so `trim l n = List.take l n`
typechecks. A file that `List = use "std/list"` **cannot** keep that call.
pos1's `foldE` (`examples/pos1.fpr:102`) is exactly the flip from std fold
back to the prelude/element-first convention:

```
foldE f z l = List.fold (fn acc x -> f x acc) z l.
```

That is why pos1 still has a local fold. Switching those 10 call sites to
`List.fold` means flipping every lambda, not renaming the function.

**`num` vs `String.toInt` / `wireInt`.** `num` (`inventory.fpr:133`,
`pos1.fpr:154`) reads a **prefix of digits**, stops at the first non-digit,
returns `0` when there are none, has **no leading `-`**, and returns a bare
`Int`. Overflow uses tagged `Int` arithmetic, which **traps**.
`String.toInt` (`std/string.fpr:272`) requires the **whole** string
(optional leading `-`), returns `Result Int String`, and reports overflow
as `Err` (digits accumulate negatively so `intMin` is representable).
`wireInt` in the prelude is the same policy as `toInt`. Swapping `num` for
`S.toInt` would change behaviour on any partially numeric token and would
turn overflow from a trap into an `Err`.

**`nth` vs `List.get`.** Default vs `Option`. Failure policy, not just
spelling.

**`isSpace` in `wat.fpr:39` vs `S.isSpace`.** The local helper is
`c == 32 or c == 9 or c == 10 or c == 13 or c == 12` (space, tab, LF, CR,
FF). `S.isSpace` is `c == 32 or (c >= 9 and c <= 13)`, which also treats
vertical tab (11) as space. Not identical.

**`Math.powInt` vs prelude `intPow` / `Int.pow`.** `std/math.fpr:64`: a
negative exponent **returns 0**. Prelude `intPow` (`core/prelude.fpr:71`)
**errors** on a negative exponent. Same name idea, different failure
policy. Unused in this corpus either way, because nothing imports
`std/math`.

**`Math.mod` vs `rem` vs `%`.** `%` resolves to prelude `Int.mod`.
`std/math` also exports `mod` (floored, `b != 0`) and `rem` (truncating
`a - (a / b) * b`). Apps that need a stated remainder should pick one and
import it; this census did not find a local reimplementation of `mod`.

**Overlapping surfaces already in the language**, which is why apps invent
a third name (`imax`, `strEq`, `lower`):

| need | prim / prelude | std | what apps actually write |
|---|---|---|---|
| string equality | `==` | — | `strEq` in inventory and pos1 |
| string length | `strlen` / `String.len` / `Str.len` | `S.length` | mostly the prim `strlen` (inventory 37, qrepo 29, examples 164, terra-ii 14). `S.length` is used, but the prim is still the default habit. |
| concatenate | `strcat` / `Str.+` | `S.append` | mostly `strcat` (examples 79) and interpolation |
| int min/max/abs | `Int.min` / `Int.max` / `Int.abs` | `Math.min` / `max` / `abs` | terra-ii and grapher use the prelude struct (terra-ii: 26 + 24 + 8). inventory/pos1 define `imax`/`imin`. **Nobody imports `std/math`.** |
| int clamp | `Int.max lo (Int.min hi v)` | `Math.clamp`, also `std.fpr` `clampInt` | terra `clampTo`, swarm `clamp` |
| parse decimal | prelude `wireInt`, `Str.parse` | `S.toInt` | qrepo uses `S.toInt`; inventory/pos1 use `num` |
| list length | prelude `List.len`, `listLen` | `List.length` | terra-ii: prelude `List.len` 16 times; everyone else: `List.length` |
| list range | prelude `fromTo` (unsafe, recursive) | `List.range` (measured, tail-recursive) | grapher uses `List.range` (6) |

## 4. Unused std worth noting

**32 std modules have zero qualified uses** in examples + the four apps,
including some that look like core library rather than device or QOS
plumbing:

- `std/math` — the whole numeric module. Apps use prelude `Int.min`/`max`/`abs`
  and `F64.*` prims instead.
- `std/vector` — only `sortWith` / `sortBy` over a `Vector`. The programs
  that have vectors (grapher, qrepo, terra-ii, wasm examples) call `Vec.*`
  prims directly.
- `std/keyedlist` — landed in #103, not yet adopted. inventory's typed `Op`
  fold is the obvious candidate, and is still a `List` + `MutMap` walk.
- `std/fixedmap`, `std/bytes`, `std/hashmap`, `std.fpr`.
- Platform / product modules with no client in this corpus: `ble`,
  `browser`, `browserformfill`, `crypto`, `esp`, `gpio`, `job`, `logfile`,
  `mqttclient`, `native`, `osconnection`, `osfs`, `oswatch`,
  `printeralertcodes`, `printeralerts`, `reload`, `reloadcatalog`,
  `supervisor`, `tangnano20k/fat`, `tangnano20k/sd`, `test`, `wifi`,
  `wire`, `ws`.

`std/storage`, `std/blockio`, `std/fs` are imported by the terra-ii headless
test but are **QOS** modules, not files in fprisc `std/`.

**Unused public-looking names in modules the corpus does use**, ignoring
`*Go` loops and obvious internals (`Tree`, `rotLeft`, `glue`, …):

- `std/list`: `singleton`, `partition`, `unzip`, `intersperse`, `tail`,
  `last`, `minimum`, `maximum`, `product`, the range-fusion family
  (`foldRange`, `mapRange`, `buildRange`, …), `mapWhere`, `mapFilter`,
  `filterMapped`. Used heavily: `length`, `map`, `filter`, `fold`, `take`,
  `find`, `sortBy`, `unique`, `append`, `concatMap`, `any`, `member`,
  `reverse`, `isEmpty`, `range`, `indexed`, `zip` / `zipWith`.
- `std/string`: `isDigit`, `isAlpha`, `isSpace`, `isEmpty`, `toUpper`,
  `right`, `dropRight`, `trimLeft`, `reverse`, `foldWords`, `foldLines`,
  `indexFrom`, `slice`, `count`. Used: `trim`, `join`, `split`, `words`,
  `toLower`, `toInt`, `fromInt`, `contains`, `padLeft`/`padRight`,
  `dropLeft`, `left`, `indexOf`, `startsWith`/`endsWith`, `lines`, `replace`.
  The unused `isDigit` / `isSpace` / `left` are exactly the ones the apps
  reimplemented.
- `std/option`: `orElse`, `isNone`, `filter`, `fromResult`, `toList`. The
  corpus matches on `Some`/`None` and uses `andThen` / `withDefault` /
  `map`.
- `std/result`: `isOk`, `oks` (and the local `rev` helper). Examples use
  `map`, `andThen`, `mapError`, `withDefault`, `collect`. The four apps
  almost do not import `result` at all (inventory talks in `Option`).
- `std/map` / `std/mutmap`: several write-side combinators (`alter`,
  `insertWith`, `update`, `freeze`/`thaw`, `fold`) are unused or barely
  used. inventory uses a small MutMap surface (`insert`, `get`, `remove`,
  `member`, `strings`, `ints`, `free`).
- `std/set` (qrepo only): `empty`, `remove`, `isEmpty`, `union`,
  `intersect`, `diff` unused.

## Appendix: std module hit counts

Hits are qualified uses (`List.map`, `S.trim`, …) in the scanned `.fpr`
files. An empty cell is zero. Modules with a zero total are unused in this
corpus.

| module | total | examples | inventory | terra-ii | qrepo | grapher |
|---|---:|---:|---:|---:|---:|---:|
| actor.fpr | 47 | 36 |  | 4 |  | 7 |
| appearance.fpr | 10 | 6 | 4 |  |  |  |
| binary.fpr | 7 | 5 |  |  | 2 |  |
| ble.fpr | 0 |  |  |  |  |  |
| browser.fpr | 0 |  |  |  |  |  |
| browserautocomplete.fpr | 12 | 6 | 6 |  |  |  |
| browsercalc.fpr | 72 | 55 | 17 |  |  |  |
| browserconsole.fpr | 4 | 2 | 2 |  |  |  |
| browserfeedback.fpr | 6 | 3 | 3 |  |  |  |
| browserformfill.fpr | 0 |  |  |  |  |  |
| browsermedia.fpr | 1 | 1 |  |  |  |  |
| browserstorage.fpr | 2 | 1 | 1 |  |  |  |
| bytes.fpr | 0 |  |  |  |  |  |
| checkdemo.fpr | 0 |  |  |  |  |  |
| clientcalc.fpr | 33 | 33 |  |  |  |  |
| clock.fpr | 100 | 69 | 24 |  | 7 |  |
| config.fpr | 9 | 8 | 1 |  |  |  |
| connect.fpr | 1 | 1 |  |  |  |  |
| crypto.fpr | 0 |  |  |  |  |  |
| decode.fpr | 79 | 69 | 10 |  |  |  |
| digest.fpr | 20 | 12 | 8 |  |  |  |
| dir.fpr | 2 | 2 |  |  |  |  |
| durable.fpr | 4 | 4 |  |  |  |  |
| encoding.fpr | 2 | 2 |  |  |  |  |
| esp.fpr | 0 |  |  |  |  |  |
| file.fpr | 48 | 44 | 4 |  |  |  |
| fixedmap.fpr | 0 |  |  |  |  |  |
| game.fpr | 102 |  |  | 102 |  |  |
| gitrevision.fpr | 2 | 2 |  |  |  |  |
| gpio.fpr | 0 |  |  |  |  |  |
| hashmap.fpr | 0 |  |  |  |  |  |
| http.fpr | 25 | 25 |  |  |  |  |
| httpclient.fpr | 11 | 11 |  |  |  |  |
| httpcore.fpr | 14 | 14 |  |  |  |  |
| javascript.fpr | 573 | 573 |  |  |  |  |
| job.fpr | 0 |  |  |  |  |  |
| journal.fpr | 11 | 7 | 4 |  |  |  |
| json.fpr | 638 | 302 | 93 |  | 240 | 3 |
| keyedlist.fpr | 0 |  |  |  |  |  |
| kvlog.fpr | 9 | 9 |  |  |  |  |
| lens.fpr | 2 |  |  |  |  | 2 |
| list.fpr | 1174 | 752 | 146 |  | 256 | 20 |
| live.fpr | 79 | 66 | 13 |  |  |  |
| livejs.fpr | 7 | 6 | 1 |  |  |  |
| livemetrics.fpr | 3 | 2 | 1 |  |  |  |
| livenotice.fpr | 8 | 8 |  |  |  |  |
| livereload.fpr | 8 | 8 |  |  |  |  |
| log.fpr | 14 | 14 |  |  |  |  |
| logfile.fpr | 0 |  |  |  |  |  |
| map.fpr | 170 | 112 |  |  | 58 |  |
| math.fpr | 0 |  |  |  |  |  |
| mjpeg.fpr | 4 | 4 |  |  |  |  |
| money.fpr | 4 | 4 |  |  |  |  |
| mqtt.fpr | 4 | 4 |  |  |  |  |
| mqttclient.fpr | 0 |  |  |  |  |  |
| mqttsession.fpr | 8 | 8 |  |  |  |  |
| mutmap.fpr | 16 |  | 16 |  |  |  |
| mvu.fpr | 12 | 12 |  |  |  |  |
| native.fpr | 0 |  |  |  |  |  |
| option.fpr | 588 | 456 | 58 | 3 | 71 |  |
| order.fpr | 55 | 19 | 9 |  | 27 |  |
| os.fpr | 3 | 3 |  |  |  |  |
| osconnection.fpr | 0 |  |  |  |  |  |
| osfs.fpr | 0 |  |  |  |  |  |
| osio.fpr | 5 | 5 |  |  |  |  |
| osnet.fpr | 7 | 6 |  |  | 1 |  |
| oswatch.fpr | 0 |  |  |  |  |  |
| ownedmqtt.fpr | 39 | 39 |  |  |  |  |
| ownedtransport.fpr | 28 | 28 |  |  |  |  |
| pagination.fpr | 2 | 1 | 1 |  |  |  |
| path.fpr | 2 | 2 |  |  |  |  |
| poller.fpr | 2 |  |  |  | 2 |  |
| printeralertcodes.fpr | 0 |  |  |  |  |  |
| printeralerts.fpr | 0 |  |  |  |  |  |
| printertelemetry.fpr | 9 | 9 |  |  |  |  |
| proc.fpr | 5 |  |  |  | 5 |  |
| program.fpr | 148 | 108 | 11 |  | 29 |  |
| readiness.fpr | 4 | 4 |  |  |  |  |
| reload.fpr | 0 |  |  |  |  |  |
| reloadcatalog.fpr | 0 |  |  |  |  |  |
| resolver.fpr | 6 | 6 |  |  |  |  |
| result.fpr | 66 | 66 |  |  |  |  |
| sessionauth.fpr | 37 | 37 |  |  |  |  |
| set.fpr | 46 |  |  |  | 46 |  |
| sockettransport.fpr | 4 | 4 |  |  |  |  |
| std.fpr | 0 |  |  |  |  |  |
| store.fpr | 12 | 12 |  |  |  |  |
| stream.fpr | 17 | 5 | 3 |  | 9 |  |
| string.fpr | 411 | 258 | 69 |  | 83 | 1 |
| supervisor.fpr | 0 |  |  |  |  |  |
| tangnano20k/fat.fpr | 0 |  |  |  |  |  |
| tangnano20k/sd.fpr | 0 |  |  |  |  |  |
| task.fpr | 3 | 2 |  |  |  | 1 |
| tcp.fpr | 12 | 10 |  |  | 2 |  |
| term.fpr | 70 | 70 |  |  |  |  |
| test.fpr | 0 |  |  |  |  |  |
| tls.fpr | 4 | 4 |  |  |  |  |
| transport.fpr | 39 | 39 |  |  |  |  |
| ui.fpr | 882 | 630 | 248 | 4 |  |  |
| vector.fpr | 0 |  |  |  |  |  |
| view.fpr | 732 | 660 | 72 |  |  |  |
| viewcache.fpr | 30 | 24 | 6 |  |  |  |
| watch.fpr | 2 | 2 |  |  |  |  |
| watchedtransport.fpr | 3 | 3 |  |  |  |  |
| wifi.fpr | 0 |  |  |  |  |  |
| wire.fpr | 0 |  |  |  |  |  |
| ws.fpr | 0 |  |  |  |  |  |

## What a cleanup would actually remove

Mechanical, low-risk, and already in the library under another name:

- 85 `strEq` sites in inventory + pos1 (`==`)
- 26 `lower` sites in inventory (`S.toLower`)
- 15 `clip` sites in inventory (`S.left`)
- 15 `imax` + 5 `imin` sites (`Int.max` / `Int.min`)
- 6 `isDig` sites (`S.isDigit`)
- 19 `count` sites in the terra-ii headless test (`List.length`)
- a handful of synonyms (`words`, grapher `contains` → `List.member`, swarm
  `clamp`)

Not mechanical: `num` (35 sites, different parse and overflow policy),
`foldE` (11 sites, fold argument order), terra-ii's prelude list surgery
(needs new std functions or a careful `Option` rewrite), and any attempt to
move terra-ii from prelude `List.take l n` onto `std/list` without flipping
arguments.

The library overlap itself (`Int.min` vs `Math.min`, `strlen` vs `S.length`,
prelude `List` vs `std/list`) is the reason a third, local name keeps
appearing. Deleting the wrappers is the small cleanup; picking one spelling
in prelude vs std is the larger one.

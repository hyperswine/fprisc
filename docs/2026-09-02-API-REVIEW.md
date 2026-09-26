# 2026-09-02-API-REVIEW.md — FP-RISC and Sol builtins, APIs, examples (2026-09)

A consistency review against 2026-09-02-DESIGN_PATTERNS.md.  Every finding carries a
count from the corpus (Sol: `sol/examples`, `sol/lib`, `sol/scripts`,
`tests/*.sol`; FP-RISC: `tests/*.fpr`, `std/*.fpr`, `core/prelude.fpr`) so a
decision can be made on what the code actually does, not on impressions.
"Fixed now" marks what this review changed; everything else is a decision
point, added to 2026-09-02-DESIGN_PATTERNS.md §6.

## 1. The same operation has several spellings (rule §1.3)

| operation | spellings in scope | corpus use | status |
| --- | --- | --- | --- |
| string length | `Str.len`, `String.len`, `strlen` | Sol examples 8 / 2 / 0; FP-RISC tests 2 / 0 / 50 | decision point D1 |
| char code at i | `Str.at s i`, `charAt s i` | Sol libs used both | fixed now: libs use `Str.at` |
| code -> string | `Str.fromCode`, `chr` | 8 / 8 across libs | fixed now: libs use `Str.fromCode` |
| substring | `Str.sub s i n`, `Str.slice s i j`, `substr s i n`, `base.substr` (= slice) | mixed | fixed now: `base.substr` retired |
| fold | `List.fold`, `foldl` | 16 / 2 | de facto decided: `List.fold` |
| map / filter | `List.map`, bare `map` | 51 / 13 | de facto decided: `List.map` |
| booleans | prelude `and or not`, `base.and2 or2 not2` | 2 / 19 (!) | fixed now: aliases retired, 8 files migrated |
| list length | `List.len`, `base.listLen` | 17 / 3 | fixed now |
| take / split / find | `List.take` vs `base.takeN`, `Str.split` vs `base.splitCh`, `Str.findFrom` vs `base.findCh` | | fixed now |
| parse int | `Str.parse`, `parseInt`, `Try.parseInt`, `parseNum`, `Try.parseNum`, `base.pI` | | D2 (the Try/unwrap pair is deliberate; `Str.parse` is a third spelling of `parseInt`) |
| concat | `strcat`, `Str.cat`, interpolation `"{a}{b}"` | FP-RISC 11 strcat; Sol 0 | D1 |

`base.sol` now holds only what has no builtin (`pI`, `max0`, `boolInt`,
`nl`, `removeAt`, `splitFirst`, `baseName`).

## 2. Bare HAL names versus `Module.func` (rule §1.1)

The rule says `Module.func` is the only call form for builtins.  The Sol
prelude has 40+ bare names: `print error unwrap okOr mapOk andThen mapErr
orElse context isOk collect parseInt parseNum readPath readPathOr writePath
mkdirp rm rmdir mv ls stat exists isDir sh shq input sleepMs readNow writeNow
appendNow shNow readLineNow not and or xor str strcat strlen charAt substr chr
myself spawn send receive receiveFrom kill yield drop keep device args`.
FP-RISC's core prelude is the opposite: structs (`Str.at`, `List.fold`,
`Actor.send`, `Mmio.read`) plus a few bare HAL names.

Sub-cases with different weights:

- **Railway combinators** (`unwrap okOr mapOk andThen mapErr orElse context
  isOk collect`, `|>?`): these read as syntax; `Result.mapOk` would hurt the
  pipelines the doc asks for.  Proposed: keep bare, list them as the ONE
  exception class ("operators and combinators are bare").
- **Filesystem verbs** (`readPath writePath mkdirp rm rmdir mv ls stat exists
  isDir`): Unix spellings, not a module.  Proposed: `File.read File.write
  File.mkdir File.rm File.rmdir File.mv File.ls File.stat File.exists
  File.isDir`, with the `Now` escapes as `File.readNow` etc. (D3)
- **Process** (`sh shq` next to `Proc.query/afterCommit/runNow`): two vocabularies
  for one thing.  Proposed: `Proc.sh` (immediate, string) and `Proc.shq`
  (queued), or retire the string doors in favour of `Proc.*` (D4).
- **Actors**: Sol `myself spawn send receive receiveFrom kill yield`; FP-RISC
  `Actor.self spawn spawnOn send recv recvRes yield`.  Same model, two
  spellings AND two verbs (`receive` / `recv`, `myself` / `self`).  (D5)
- **Strings**: `strlen charAt substr chr strcat str` are the FP-RISC HAL
  contract (`fpr_g_*`); Sol wraps them as `Str.*`.  The FP-RISC corpus uses
  the bare forms 50:2.  (D1)

## 3. Argument order (rule §2)

Data-last holds almost everywhere in Sol: `List.take n xs`, `Str.replace old
new s`, `Str.split c s`, `Vec.get i v`, `Vec.set i x v`, `J.set k v j`,
`C.col k rec`, `P.inDir dir spec`, `Git.commit msg r`, `okOr d r`.

Exceptions, all "string with an index":

| function | order | note |
| --- | --- | --- |
| `Str.at s i`, `charAt s i` | data first | FP-RISC `Str.at s i` too |
| `Str.sub s i n`, `Str.slice s i j`, `substr s i n` | data first | |
| `Str.findFrom c s i`, `Str.indexFrom p s i` | data in the middle | |
| `xs ! i` | infix, data first | operators are exempt |
| FP-RISC `List.take l n`, `List.drop l n` | data first | Sol has `List.take n xs` -- the SAME NAME with the opposite order across the two profiles |
| FP-RISC `SStr.put s i c`, `SStr.push s c` | data first | |

Proposed pin (D6): indices and counts are secondary data and go BEFORE the
main data (`Str.at i s`, `Str.sub i n s`, `Str.findFrom c i s`), exactly like
`Vec.get i v` already does; FP-RISC `List.take/drop` flip to `n l` to match
Sol.  Cost: every `Str.at s i` call site (FP-RISC: 17 `charAt`, Sol libs: ~40).
Cheap now, expensive later.

## 4. Failure channels (rule §6.2)

Present in the corpus, all at once:

- `Result` (`Ok | Err String`): `Try.*`, `J.*`, `C.col`, `Proc.query`, lens.
- panic: `parseInt`, `readPath`, `unwrap`, `xs ! i` out of range, `Vec.get`.
- a LIST as an option: `List.find p xs` returns `[x]` or `[]` (prelude).
- a local union as an option: `Opt = Type (Nope | Got x)` declared in
  bboard.sol, logic.sol, and again as `Opt2 (Nope2 | Got2 x)` in plparse.sol;
  `Some`/`None` appear 32/64 times in todo/pos/dash/terra as their own types.
- sentinel: `Str.find` returns 0 for "not found" (1-based indices make 0
  free); `base.pI ""` is 0.

Proposed pin (D7): one `Option` type in the prelude (`Some x | None`) -- the
examples have already voted for those constructors 96:0 over `Got/Nope` --
and the rule "`Result` when there is something to SAY about the failure,
`Option` when absence is ordinary, panic only behind an `unwrap`-shaped
name".  `List.find` returns `Option`, `Str.find` keeps its 0 (documented as
the 1-based idiom) or becomes `Option` too.

## 5. Verb vocabulary (rule §6.1)

Counted over every API name in the surfaces above:

| family | in use |
| --- | --- |
| lookup | `get` (J.get, Vec.get, L.get, VList.get), `find` (List.find, Str.find, L.find), `lookup` (logic.sol only), `at` (J.at, Str.at, BStr.at), `col` (C.col) |
| construct | `new` (Vec.new, BStr.new, SStr.new), `fromList/fromStr/fromRows/fromCode/fromInt`, `of` (J.ofRecord), `spec` (P.spec), `repo` (Git.repo), `mk` (mkPt in examples), `make` (none) |
| convert | `toList/toStr/toInt/toMilli`, `render` (J.render, C.render, plot), `show` (M.show), `pretty` (J.pretty), `str` |
| read/parse | `parse` (J, C, Str), `read` (File, Mmio), `load` (LD.load, loadProgram) |
| size | `len` everywhere (never `length`, `size`, `count`) -- already consistent |

Proposed pins (D8): `get` = by key/index, total or `Option`; `find` = by
predicate, `Option`; retire `lookup`.  `new` = empty container; `from<X>` =
conversion in; `to<X>` = conversion out; `render` = to wire text, `pretty`
= to human text, `show` = debug text.  `parse` = text -> value (Result).

## 6. Configs and `Module.defaults` (rule §3)

Zero occurrences of `defaults` in the corpus.  The config records that exist:
`MV.run me cfg app` with `cfg = {env, mt, tick, input, render}` (positional
plus record), `ProcessSpec argv cwd env stdin timeoutMs` (positional, with
`P.spec`/`P.inDir`/`P.withEnv` builders), `View.serve port init update view
subs` (positional).  So the doc's rule is aspirational: no API follows it yet.
Decision point D9: adopt it for new APIs and convert `ProcessSpec` (already
half-record via `P.with*`) as the reference example; or drop §3's
`Module.defaults` sentence until one exists.

## 7. MVU: the doc and the code (rule §4)

The doc says `MVU.serve { init, update, view }` with `view` returning a
scene.  The code has TWO shapes:

- FP-RISC `std/mvu.fpr`: `MV.run me cfg app` where `app = MApp init update
  skey view vals done subs` -- seven positional fields, `view` returns a
  `List String`, `vals` a second render channel, `done` a summary.
- Sol `View.serve port init update view subs` -- four positional callbacks
  and a subscription list.

Neither is the documented one, and they differ from each other in arity,
argument order and the subscription spelling.  Decision point D10: pick the
record form the doc describes (`{init, update, view, subs}` plus a config
record), give it ONE name in both profiles, and treat `skey/vals/done` as
config or as scene content.

## 8. Object-method spellings (rule §1.1)

Typed path literals are the one API in the code base with method syntax:
`(@Model.hp).get m`, `.set v m`, `.segs` (10 uses).  Everything else is
`Module.func`.  Decision point D11: keep it as the ONE sanctioned
object-method (the literal IS a record of closures, and `L.get p m` exists
for the string tier), or add `Path.get p m` / `Path.set p v m` and make the
record fields an implementation detail.

## 9. Helper duplication in the FP-RISC tests (rule §5)

Same helpers re-declared per file: `revL` x2, `joinSegs/joinOne/joinBar`
x2 each, `escLf` x2, `strEq/strEqAt` x2, `splitNl/splitNl2` x2, `lenL` x2,
`catL` x2, `renderRt` x3.  These are `List.rev`, `Str.join`, `Str.replace`,
`==` on strings, `Str.lines`, `List.len`, `Str.cat` -- all of which the Sol
prelude has and the FP-RISC core prelude does not.  Decision point D12:
grow FP-RISC's `Str`/`List` structs to the Sol surface (the ONE grammar
already shares the parser; the preludes diverged), or accept per-file
helpers in the AOT profile as the price of a std tier with bounded WCET.

## 10. Recursion schemes over explicit recursion (rule §5)

Sol: `|>` 64, `|>?` 40, lambdas 104, `Vec.*` 110 -- pipelines dominate.
Guards-vs-case for a two-way condition: Sol 137 guard clauses versus 90
`case ... of True -> | False ->`, FP-RISC 76 versus 65 -- both spellings are
used for the same thing in both profiles.  `unsafe` versus `measure`: Sol
176 / 37, FP-RISC 262 / 43 -- most recursion is still exempted rather than
proved.
Decision points D13 (guards or booleans-by-case for two-way conditions) and
D14 (when is `unsafe` acceptable in an example).

## 11. Operators as the default (fixed now)

`%` and `^` are operators in the one grammar; `+ - * / % ^` resolve by
operand type on numbers, strings, lists, Vectors (`+ -` elementwise, `*`
dot, `k * v` scale), Matrices (`+ -`, `*` matmul, `m * v`), and user
structs; mixed operand types resolve to a two-typed struct operator.  The
corpus migration replaced 43 saturated calls (`Numeric.mod`, `Int.mod`,
`imod`, `List.append`, `strcat`, `F64.pow`) with operators across 21
files and retired the `imod` helpers; `sol/examples/algebra.sol` is the
executable spec and a check-all leg runs it on both profiles.

## Fixed now

- retired every `base.sol` alias that duplicated a prelude builtin
  (`and2 or2 not2 listLen takeN substr splitCh findCh imod2`), migrated
  8 files; examples suite 44/44 green.
- `lib/json.sol` and `lib/csv.sol` use `Str.len/at/sub/fromCode`, not the
  bare HAL names.
- 2026-09-02-DESIGN_PATTERNS.md §6 carries D1–D14 with the proposed answers.

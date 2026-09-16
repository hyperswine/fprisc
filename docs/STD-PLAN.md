# STD-PLAN -- the core and std libraries for 2.0

V2.md workstream 3 in one page each for: what exists, what the tiers
are, what the surface must contain, which module goes where, and the
gate that keeps it honest.  Counts are from the tree at `03bf0d9`.

## 1. Where the library actually is today

| tier | files | lines | what it is |
| --- | --- | --- | --- |
| `core/prelude.fpr` | 1 | 267 | the bare tier: `Int`/`Str`/`List`/`SStr`/`VList`/`Actor`/`Mmio` Structs, `Sys.*` decls, hand-rolled list/string helpers |
| `std/*.fpr` | 11 | 1385 | the "safe tier" -- in practice `mvu` (452) + `loader` (235) + `uart` (152) and eight small ones |
| `std/std.fpr` | 1 | 50 | the WCET proof-of-concept: `foldRange`, `clampInt`, `retryN`, `backoffMs` |
| `programs/mods/*.fpr` | 37 | 8307 | **the real standard library**: `qlog` 851, `scene2d` 709, `fprlive` 652, `qsys` 434, `svc` 388, `liveview` 320, ... |
| `sol/lib/*.sol` | 14 | 1708 | the sol-side library: `logic` 397, `matrix` 282, `plparse` 280, `plot` 198, `json` 151, ... |

So `std/` is 14% of the library by line count and the tier a user
actually programs against is a directory called `programs/mods`.  That
is the headline problem: **the standard library is not in std.**

The second problem is that there are three vocabularies for the same
operations, and they are not subsets of each other:

| operation | `core/prelude.fpr` (AOT) | Sol builtins | `sol/lib/base.sol` |
| --- | --- | --- | --- |
| length | `strlen`, `Str.len` | `strlen`, `String.len` | -- |
| split | **absent** | `strSplit` | `splitFirst` |
| join | **absent** | `strJoin` | -- |
| trim | **absent** | `strTrim` | -- |
| replace | **absent** | `strReplace` | -- |
| find | `strSufEqAt` (hand-rolled) | `strIndexOf` | -- |
| case | **absent** | `strLower`, `strUpper` | -- |
| compare | hand-rolled `strEq` in 5+ files | `strCmp` | -- |
| parse int | `parseInt` | `Try.parseInt`, `parseInt` | `pI` |
| fold | `listFold`, `List.fold` | `foldl`, `List.fold` | -- |

Nine string operations exist on the hosted profile and **not at all**
on the three AOT profiles.  A program that compiles to a `.qa` has no
`split`, no `join`, no `trim`, no `replace`, no case folding, and no
string comparison that is not hand-rolled.  This is why `strEq` is
re-implemented per file and why `and2`/`or2` appear in 13+ files.

What is missing from BOTH sides: `Dict`, `sort`, `Option`, `argv`,
`env`, exit codes, `stderr`, JSON on the AOT side (`sol/lib/json.sol`
exists only for sol), dates/time formatting beyond `mods/timefmt.fpr`
(7 lines), and an HTTP client.

## 2. The tiers 2.0 commits to

Four named tiers, each with a rule that decides membership.  A module
belongs to exactly one.

**`core/`** -- the bare tier.  What the compiler and the HAL jointly
define: the builtin Structs, the `Sys.*` declarations, the operators.
Unsafe by licence (`unsafe module.` is allowed here and nowhere else).
Must compile with no dependency but the frontend.  Target: stays ~300
lines; everything hand-rolled in it that has a builtin moves out.

**`std/`** -- the safe tier.  The defining rule is unchanged and it is
the whole point: **no operation with unbounded worst-case behaviour.**
Recursion is by certified measure or the once-proven `foldRange`/`Fold`
scheme; waits are bounded retries with a stated equation.  A `std`
module carries per-function `unsafe`, never `unsafe module.`, and
every `unsafe` has a comment naming the unbounded thing.  This is the
tier the WCET story is about, so its growth is deliberate and slow.

**`lib/`** -- NEW.  The tier that does not exist today and that every
"where is split/sort/dict" complaint is about.  Useful, documented,
tested, profile-portable -- but NOT claiming a WCET bound.  A `lib`
module may be `unsafe` wholesale where the operation genuinely is
(a server's receive loop, a parser over arbitrary input).  This is
where most of `programs/mods` lands, and where new work goes by
default.  Splitting it out is what lets `std` stay small and provable
instead of being pressured into accepting unbounded operations.

**`apps/` + `examples/`** -- programs, not library.  `programs/mods`
retains only what is genuinely one app's own code.

Both `std/` and `lib/` resolve from the toolchain home, so
`use "std/mvu"` and `use "lib/json"` work from any project (the
resolution rule already exists -- `Home.hs`, SEMANTICS §7).

## 3. The surface 2.0 must contain

The gap list, as modules.  Everything here must exist on **all four
profiles** -- that is the acceptance criterion, and the reason the
table in §1 is the bug.  Items marked (sol) exist on the hosted
profile today and need an AOT implementation; items marked (new) exist
nowhere.

### `std/str` -- bounded string operations
`eq`, `cmp` (sol), `find`/`findFrom` (sol: `strIndexOf`), `split`
(sol), `join` (sol), `trim` (sol), `replace` (sol), `lower`/`upper`
(sol), `startsWith`/`endsWith` (new), `pad`/`repeat` (new).
All are `measure`-certifiable over the input length -- they belong in
`std`, not `lib`.  **Decide first (SEMANTICS §3): bytes or code
points.**  Every function here has a different signature depending on
the answer, so this is the blocking decision for the whole workstream.

### `std/list` -- bounded list operations
`sort` (new; a certified merge sort, `n log n` stated), `sortBy`,
`dedup`, `zip`/`unzip` (prelude has `zipV`/`fstV`/`sndV` as unsafe
hand-rolls -- promote and certify), `find`, `any`/`all`, `reverse`,
`concat`, `flatten`.  Retires the unsafe gensym-leaking helpers in
`core/prelude.fpr` (see §5).

### `std/dict` -- an associative map (new)
No dictionary exists anywhere in the tree.  A bounded-capacity
open-addressed map with a declared capacity is the `std`-shaped
answer (the bound is the contract); an unbounded growing one is
`lib/dict`.  Ship both, name the difference.

### `std/opt` -- `Option` (new)
`sol/lib/` invents `Opt2` locally.  One `Option a = Type (None | Some
a)` with `map`/`orElse`/`unwrapOr`, plus the `Result` combinators the
sol prelude already has bare (`okOr`, `mapOk`, `andThen`, `mapErr`,
`context`, `collect`) given one home.

### `std/bool` -- retire `and2`/`or2`
`&&` and `||` exist as operators (SEMANTICS §2) but 13+ files still
define strict `and2`/`or2` and `tuinotes.fpr:51-53` documents being
bitten by the strictness.  The fix is to delete the helpers, not
document them.

### `lib/json` -- JSON (sol has it, AOT does not)
`sol/lib/json.sol` is 151 lines and works.  Port to `.fpr` so a `.qa`
can speak the format its own LiveView wire uses.

### `lib/proc` -- argv, env, exit codes, stderr (new)
None of these exist on the AOT side.  `qos.py` being written in Python
is the honest verdict on this gap, and it is four small builtins plus
a module.

### `lib/time` -- formatting beyond `mods/timefmt.fpr`'s 7 lines.

### `lib/http` -- a client over the existing socket tier.
The net tier exists (`netRead`/`netWrite`/`netPoll`); nothing wraps it
as a client.  Last, and explicitly `lib`, not `std`.

## 4. The promotion table

Usage counts are `use`-site counts across the tree; test counts are
`use`-sites inside `tests/`.

| module | lines | uses | tests | 2.0 home | why |
| --- | --- | --- | --- | --- | --- |
| `mods/svc` | 388 | 6 | 3 | **`std/svc`** | the OS API funnel; the service-idiom decision (V2 workstream 1) lands here |
| `mods/qlog` | 851 | 5 | 3 | **`lib/qlog`** | the append-only log; replay is unbounded by nature, and it carries 117 `unsafe` |
| `mods/qsys` | 434 | 1 | 1 | **`lib/qsys`** | system services; 50 `unsafe` |
| `mods/qar` | 87 | 2 | 1 | **`lib/qar`** | archive format reader |
| `mods/coreutil` | 105 | 5 | 2 | **split** | the bounded half into `std/str`/`std/list`; the rest to `lib` |
| `mods/persist` | 50 | 0 | 0 | **`lib/persist`** | the kv-per-app API; zero uses is a docs problem, not a delete signal |
| `mods/tui` | 271 | 2 | 0 | **`lib/tui`** | needs a test before it ships (gate §6) |
| `mods/scene2d` | 709 | 3 | 1 | **`lib/scene2d`** | the 2D scene graph |
| `mods/glsvc` | 101 | 5 | 3 | **`lib/gl`** | GPU service client |
| `mods/genview` | 291 | 4 | 2 | **`lib/genview`** | generic view rendering |
| `mods/fprlive` | 652 | 2 | 1 | **`lib/fprlive`** | the LiveView server; 61 `unsafe`, receive-loop by design |
| `mods/liveview` | 320 | 1 | 1 | **`lib/liveview`** | the wire protocol |
| `mods/appkit` | 136 | 1 | 1 | **`lib/appkit`** | |
| `mods/timer` | 118 | 4 | 2 | **merge into `std/timer`** | duplicate: `std/timer.fpr` (52) and `mods/timer.fpr` (118) both exist |
| `mods/uart` | 286 | 4 | 2 | **merge into `std/uart`** | duplicate: `std/uart.fpr` (152) is the phase-typed handle, `mods/uart.fpr` is the driver actor.  They are the two halves of one thing -- `std/uart` the protocol, `lib/drivers/uart` the driver |
| `mods/arcsvc` | 53 | 1 | 1 | **`lib/`** | |
| `mods/fontm`, `mods/sfx`, `mods/timefmt` | 110/62/7 | 1/1/0 | 0 | **`lib/`**, with tests | |
| `mods/bbspi`, `matrixkpd`, `oled`, `ttp229` | 42/45/45/34 | 0-1 | 0 | **`lib/drivers/`** | device drivers; the driver contract (`docs/HAL.md`) is where they get their shape |
| `mods/*app` (helloapp, cliapp, clockapp, diskapp, logsapp, monitorapp, procapp, browserapp, pnotes, ma, maapp) | 55-197 | 0-2 | 0-1 | **`examples/`** | these are programs, not library |
| `mods/dungeonrules` | 555 | 2 | 1 | **`examples/dungeon/`** | one app's rules |
| `mods/docsdata` | 1331 | 0 | 0 | **delete or `examples/`** | the single largest file in `mods/`, zero uses, zero tests |
| `mods/livejs`, `mods/fprlivejs` | 129/152 | 0 | 0 | **`lib/fprlive/`** | the JS side of fprlive; fold in as assets |

Net effect: `std/` goes from 11 modules to ~14 (svc, str, list, dict,
opt, bool, mvu, uart, timer, actor, fs, lens, loader, compile), `lib/`
starts at ~20, `examples/` absorbs ~13, and one 1331-line file with no
users leaves the library.

## 5. `unsafe`, honestly

Today: **102** `unsafe` markers across `std/` (unchanged since the
August review), concentrated in `mvu` (42) and `loader` (30).
`programs/mods` carries far more: `qlog` 117, `svc` 81, `fprlive` 61.

The 2.0 rule: an `unsafe` in `std/` names a genuinely unbounded loop
and carries a comment saying which one.  Everything else is one of
three things, and each has a mechanical fix:

1. **A measure that was never written down.**  Most of `mvu`'s 42 are
   this.  Fix: add `measure`; the compiler already verifies it
   (`tests/measure.fpr`).
2. **A `foldRange`/`Fold` scheme spelled as raw recursion.**  Fix:
   rewrite to the scheme -- the bound is then once-proven, not
   re-analysed.
3. **A genuine receive loop or unbounded input parse.**  Fix: the
   module moves to `lib/`, where `unsafe` is allowed and honest.

Target for 2.0: `std/` under 20 `unsafe` markers, every one commented.
Ratchet it the way the fork is ratcheted -- a check-all leg with a
ceiling that a conscious edit may raise with a reason.

**The gensym leak ships in the library.**  93 inference gensyms
(`c29`, `p36`, `l31`, `d29`, ...) appear in `core/prelude.fpr`,
`std/*.fpr` and `programs/mods/*.fpr`, generated by
`FPR_UNSAFE_SUGGEST`'s paste-ready output.  `std/std.fpr`'s very first
signature reads:

    foldRange : unsafe Int -> Int -> (Int -> p36 -> p36) -> p36 -> p36 .

Fix in two parts: (a) `FPR_UNSAFE_SUGGEST` emits `a`, `b`, `c`... not
inference gensyms; (b) a one-time rename pass over the 93 sites, with
a check-all leg refusing `[a-z]{1,2}[0-9]{2}` as a type variable in
`core/`, `std/` and `lib/`.  This is cosmetic and it is also the first
thing every reader of the library sees.

## 6. The gate

A `std/` or `lib/` module ships only if it has **all three**:

1. a section in `docs/STD.md` (does not exist yet -- 2.0-alpha.1
   creates it),
2. a `tests/std_<name>.fpr` or `tests/lib_<name>.fpr` exercising its
   documented surface,
3. for `std/` only: `fpr stdcheck` clean, or each `unsafe` commented.

Enforced by a check-all leg that walks `std/` and `lib/` and fails on
any file missing either.  Today's coverage against that gate:

| module | docs | test | verdict |
| --- | --- | --- | --- |
| `std/mvu` | 5 | 9 | passes |
| `std/fs` | 1 | 7 | passes |
| `std/actor` | 1 | 3 | passes |
| `std/std` | 1 | 3 | passes |
| `std/timer` | 1 | 1 | passes |
| `std/uart` | 1 | 1 | passes |
| `std/compile` | **0** | 2 | needs docs |
| `std/lens` | **0** | 2 | needs docs |
| `std/loader` | **0** | 5 | needs docs |
| `std/livereload` | **0** | 1 | needs docs |
| `std/checkdemo` | 1 | **0** | move to `examples/` -- it is a demo |

Four of eleven `std` modules would fail the gate on docs alone, and
`checkdemo` is a demo living in the library.  Every `lib/` candidate
in §4 with `tests=0` (tui, persist, fontm, sfx, timefmt, the four
drivers) needs a test before it ships.

## 7. Order

Inside V2.md's four-phase plan:

**2.0-alpha.1 (paper).**  Decide strings: bytes or code points
(SEMANTICS §3) -- blocks every signature in `std/str`.  Write
`docs/STD.md` with a section per module as it will be, including the
modules that do not exist yet.  Write the promotion table above into
the tree as the move plan.

**2.0-alpha.2 (the tree conforms).**
1. Create `lib/`; move `programs/mods` per §4; `examples/` absorbs the
   apps.  Mechanical, large, and it unblocks everything else.
2. `std/str` and `std/list` -- the nine missing string operations on
   the AOT profiles, and `sort`.  Biggest single usability delta in
   the plan.
3. `std/dict`, `std/opt`, `std/bool`; delete `and2`/`or2` and the
   five hand-rolled `strEq`s.
4. Merge the `timer` and `uart` duplicates.
5. `unsafe` reduction to the ratchet; the gensym rename.
6. The gate leg, and the docs the gate demands.

**2.0-alpha.3.**  `lib/json` and `lib/proc` (argv/env/exit/stderr) --
the two that turn "not close to Python" into "usable".  `lib/http`
if the board work leaves room.

**2.0.**  Every `std/` and `lib/` module past the gate; `std/` under
20 commented `unsafe`s; `docs/STD.md` complete; check-all green on
qosp, virt, the board, macOS.

## 8. What this plan deliberately does not do

- It does not add a package manager.  `use "name#hash"` + `fpr.lock`
  is the versioning story and it works; a registry is 2.1 at the
  earliest.
- It does not unify the FP-RISC and Sol *spellings* beyond the shared
  surface in §3.  `docs/API-REVIEW.md`'s D1-D5 are real decisions but
  they are renames, and renames are a deprecation cycle -- 2.1.
- It does not make `std` bigger than it can prove.  Everything that
  cannot carry a bound goes to `lib/`, and `lib/` is allowed to be
  large.  Keeping those two facts apart is what the tier split is for.

# One copy of each constructor: what the units really duplicate

Date: 2026-10-19. Kind: design page with its implementation and
measurements. Base: FP-RISC `041dc20` (code generation revision 50),
Apple M4, macOS, the -O0 `./fpr`.

## The question

2026-10-18-COMPILER-BUILD-OPT.md found that half of a warm `fpr build` is
the one `cc` call that assembles the program and its cached units, and
that the linked logbook binary holds 28,595 `fpr_fn_` symbols of which
2,799 are distinct, `_fpr_fn_Add` 45 times among them. The working
hypothesis handed to this page was that every std unit re-emits a private
copy of the prelude's functions, because a unit "typechecks standalone
WITH the prelude" (compiler/Compile.hs, `resolveUnit`). This page
establishes what the copies actually are, which of them genuinely differ
per unit, and makes each of the rest exist once.

## What a unit carries

`resolveUnit uts` (Compile.hs) runs `inferTops` over
`preludeE' ++ sharedContext ++ uts` so that the unit's operator sites are
resolved with the prelude's signatures in scope, and then keeps only
`uts`'s own binds plus the non-bind tops. The prelude's binds do NOT
reach the unit's Core. `compileUnit` is `compileRaw`, whose state is
`DEnv 0 consAll shapes [] []`; and `compileTop` (compiler/FPRISC.hs)
begins with

    conGlobals = [(c, (params, CMk tid var params)) | (c, (tid, var, ar)) <- M.toList cons]

one supercombinator per constructor in `cons`, which is `consAll`: the
union of the prelude's, the root's and every unit's constructors (the
builtin ones included), the whole program's. Every unit, the prelude unit
and the root therefore emit a stub `fpr_fn_<Con>` and a static descriptor
`fpr_obj_<Con>` for EVERY constructor of the program they are compiled
in, local symbols (not `.globl`, since `exps` is the unit's own
`bindNames`), identical from unit to unit except for the numbers in the
fuel-check labels.

That is the whole of the sharing. Measured on examples/logbook.fpr
(44 std units + the prelude unit + the root, a cold `fpr compile` into a
fresh `units/`):

| | count |
|---|---|
| `# fn` entries across the 46 assembly files | 29,174 |
| distinct function names | 2,822 |
| constructors in `consAll` (names present in all 46 files) | 585 |
| of those, hash-qualified (a unit's own types, `Absolute@0045dd57b08cf1a0`) | 540 |
| unqualified (builtin, prelude and root types: `Cons`, `Add`, `Page`) | 45 |
| constructor stub copies (585 x 46) | 26,910 |
| other duplicated names (fresh `lifted_N` / `case_join_N` that coincide in two units; local, harmless) | 27 names, 54 entries |
| `$spec.<unit>.<fn>.mono.N` clones (per-unit monomorphization of that unit's OWN functions) | 172 (102 in the root, 13 in the prelude unit, 57 across units) |
| `$receive.turn/local.*` (receive-turn splits of a unit's own loops) | 17 |
| `$specaux.p<hash>.*` / `$specaux.u<hash>.*` in the root (copies of OTHER units' private helpers pulled in by the root's clones, Mono.includeAux) | 23, of which 22 are constructor stubs again (`$specaux.pb2084da22e6a.Cons`, `$specaux.u9b56ef516f87.Frame@...`) and 1 a lifted helper |
| plain functions (own binds of the root, the prelude and the units) | 2,024 |

The prelude unit exports its 211 binds `.globl`; a std unit calls them as
externs (`call fpr_fn_map`, `la fpr_obj_map`) through `ext`, exactly as
designed. Its remaining 617 entries are the 585 stubs, its 13 `$spec`
clones and 7 `$receive` splits. No std unit carries a copy, specialized
or not, of a prelude function: `mono` runs a unit with `external =
M.empty`, so a unit clones only its own functions. The only
cross-unit copies are the root's `$specaux` helpers: 22 of the 23 are
constructor stubs once more (the prelude's and the units' Core, handed to
the root's specializer as `importedCore`, carries the stubs under a
`$specaux` prefix because `qualifyAux` renames every name that is not one
of the unit's binds), and the one genuine copy is a unit's private join
point cloned for the root's callbacks, which has no other home.

So, of the 26,352 non-distinct entries, 26,325 are the constructor
stubs, and they are byte-identical duplicates up to label numbering.
What they cost:

| | lines | bytes |
|---|---|---|
| all 46 assembly files | 1,646,738 | 36,510,309 |
| constructor stubs in them | 902,382 (19,617 per file) | 20,388,394 (443 KB per file) |
| share | 55% | 56% |

Per unit the share runs from 17% (std/ui's big unit, 2.5 MB) to 84% (a
small unit of 24 KB of own code under 443 KB of stubs). The 20 MB of
stubs is what the `cc` step assembles and the linker discards into 5 MB
of text that holds 45 copies of every constructor's code.

The copies are harmless at link (local symbols) and harmless at run (a
unit's code calls its own local stub, which allocates the same `tid`/`var`
cell). They cost: the cold compile (every unit regenerates and lowers
19,617 lines of stubs through A64.hs), the assembly step on every warm
build, the binary's text, and `--lib`/`--plugin` images that carry a
program's constructor table in every object.

## Why they are there

A unit's Core needs every constructor as a global supercombinator for
three reasons, all of which are about the CORE, not the assembly:

- `Inline.inlineWith` inlines small non-recursive functions at saturated
  sites from the unit's own `prog`. A saturated `Cons x xs` in Core is
  `CApp (CApp (CVar "Cons") x) xs`; the stub `Cons x1 x2 = CMk 2 1 [x1, x2]`
  is what makes it an inline allocation. Without the stub in `prog` it
  would compile to a call.
- `Codegen.known` / `base` resolve `CVar "Cons"` to `fpr_fn_Cons` /
  `fpr_obj_Cons` by looking the name up in `prog` first, then `ext`.
  Nullary constructors are called (`call fpr_fn_Nil`, 1,517 sites in
  logbook); unsaturated ones are function values (`la fpr_obj_Cons`).
- `nullaryBool` folds `True`/`False` through their `prog` entries.

Nothing requires the stub's CODE to be emitted by every unit; only its
presence in the unit's `prog` for the passes above, and one definition of
each symbol somewhere in the link.

## The change

Each constructor's stub and descriptor are emitted exactly once, by the
unit that declares its type, as a `.globl` (`.weak` for unqualified names
in a `--lib` compile, as every other unqualified global already is);
every other unit keeps the stub in its Core and references the symbol.

- `Codegen.emitProgram` takes a set of names whose entries are
  `elided`: they stay in `cgProg` (so `known`, `base`, `nullaryBool`,
  `indexedMemory` and the inliner see them unchanged), but `compileFn`,
  `objFor`, the `declines` scan and the `nullaries` scan run over the
  emitted entries only. A reference to an elided name produces the same
  `call fpr_fn_X` / `la fpr_obj_X` it produced before; the symbol is now
  external.
- Compile.hs computes the owner of each constructor: `builtinCons` and
  the prelude's types belong to the prelude unit when one is emitted
  (`not oArc && not (null preludeTops)`), otherwise to the root; a unit's
  types belong to that unit (when units are emitted, i.e. not `--arc`);
  the root's types to the root. A unit's `exps` gains the constructors it
  owns, so they are `.globl`; its elided set is every other constructor.
  The root's elided set is the prelude's and the units' constructors.
  Under `--arc` nothing is elided and nothing changes: the root is the
  whole program there and already exports every entry.
- `qualifyAux` (Mono.hs) keeps constructor names as they are instead of
  renaming them `$specaux.<unit>.<Con>`: a constructor is global
  everywhere, so a root clone that references one links against the
  owner's symbol like any other site. This removes the 22 `$specaux`
  constructor copies and the 43 `call _x24specaux_..._Nil` sites in the
  root; the one `$specaux` lifted helper stays.
- `codegenRev` 50 -> 51: a unit cached at revision 50 carries local
  stubs and a revision-50 prelude unit exports none, so the two
  generations must not meet in one link; the tag keeps them apart.

What is NOT changed: `consAll`, `tidFor`, the content-addressed tids and
the `fpr_contab` render table (still one table in the root for the whole
image); the per-unit cache key (`u-<hash>-p<prelude>-s<shapes>-<tag>`);
the modtab, the checked-interface stamps (they carry `g<codegenRev>`, so
they change as they do for any codegen revision); the Core and the inliner.

### Unit hashes and the QOS contract

A unit's identity is its SOURCE hash (the `u-<hash>` name, the pin QOS
holds); its compilation is the tag. The source hash does not move. The
tag moves with every codegen revision, which is the existing contract:
QOS's pinned units are re-emitted under the new tag at the next compile
and its process images are rebuilt from the new `.units` list, as after
every revision bump since the cache was introduced. The link list of an
image is unchanged in membership: a unit only references constructors of
the prelude and of the modules it `use`s, all of which are in any link
that contains it (`Modules.loadProgram` resolves `use` transitively and
`dedupeUnits` keeps one copy of each). The root's own constructors are
referenced by the root alone.

Relocatable native images: the new external references are the same
kind the units already make to the prelude's functions (`fpr_fn_map`)
and to each other's exports; an image format that relocates those
relocates these. Portable plugins bound by name: binding is through
`fpr_modtab`/`fpr_obj_` of exports and is unchanged; a plugin's own
prelude unit now exports its constructor stubs `.globl`, beside the
prelude functions it already exported, and the host's two-level
namespace (macOS) or `-Bsymbolic` (Linux) binds the plugin's internal
references to its own definitions as before.

### What it enables

With the prelude's and every unit's symbols owned once, the next step is
the one the build-opt page wanted: cross-unit inlining of std functions.
A unit's `prog` can then be extended with the Core of the prelude
functions it calls, marked elided exactly like the stubs: the inliner
sees them (small saturated sites become inline code), the generator
emits nothing for them, and the prelude unit stays the one home of the
symbol. The elision set is the mechanism; this page uses it for
constructors only.

## Risks

- Duplicate-symbol links. Two units defining the same `.globl`
  constructor can only happen if two owners are computed for one name.
  `consAll` is left-biased (prelude, then root, then units) and ownership
  is computed from the same per-owner maps, so a name declared twice (a
  root type shadowing a prelude type) has the prelude as its owner and
  the root elides its copy, matching the tid `consAll` gave it. A link
  that mixes a revision-50 unit (local stubs) with a revision-51 prelude
  (global stubs) links fine; the reverse (a revision-51 unit with a
  revision-50 prelude) has undefined `fpr_fn_Cons`, which the tag
  prevents.
- Foreign process images. A `.s` taken out of the unit cache and linked
  without its owners (a QOS image that lists a unit but not the prelude
  unit, or not a module it `use`s) fails at link with undefined
  constructor symbols where it used to link and run. Every `.units` list
  the compiler writes contains the owners; a hand-built link list must.
- The revision tag. Bumping it recompiles every cached unit once
  (the cold column of the build-opt page) for every user and every QOS
  checkout, and changes every `fpr-interface-1/g51/...` stamp; host
  modules built at 50 refuse to attach to a host at 51
  (`FPR_POSIX_CODEGEN_REV`). This is the normal cost of a codegen change.
- `--lib`: a library's prelude unit now exports the unqualified
  constructor stubs `.weak`, like its other unqualified globals; a
  program's prelude unit exports the same names `.globl` and wins. Where
  both are `.weak` (two libraries) the linker keeps one, which is the
  same code.
- Label renumbering: the emitted assembly of every unit changes
  textually (fewer functions, so the `.Lfuel`/`.Lstr` counters shift).
  Byte-identity of the `.s` cannot be the proof; program output and the
  suites are.

## Results

Both compilers are -O0 builds of the same tree (`041dc20` with and without
this change), run one after the other on the same machine, twice. "cold"
is `fpr compile --system=posix --prelude=core/prelude.fpr examples/X.fpr
X.s` into an empty `units/`; "warm" the same again; "build" is `fpr build
examples/X.fpr -o X` with its shared cache already warm (a private
`XDG_CACHE_HOME` per compiler, so other sessions' caches were not
touched); "cc" is the one `cc` call inside that build, timed by a wrapper
in `FPR_CC`. The machine was not idle (load average 3 to 6, other
sessions building), so the wall times are indicative; the two rounds
agree within a second except the baseline pos1 cold compile.

logbook (examples/logbook.fpr: 44 std units + the prelude unit + the root):

| | before | after |
|---|---|---|
| `# fn` entries across the assembly files | 29,174 | 2,827 |
| distinct function names | 2,822 | 2,800 |
| `.globl` function symbols in the binary (`nm`, T) | 1,636 | 2,221 |
| assembly, all files | 1,646,738 lines, 36.5 MB | 567,161 lines, 12.9 MB |
| binary | 9,011,704 B | 3,084,824 B |
| text segment | 5,128,192 B | 2,015,232 B |
| compile cold (rounds 1, 2) | 33.9 s, 33.0 s | 23.5 s, 23.3 s |
| compile warm | 13.1 s, 12.5 s | 12.3 s, 11.9 s |
| build warm | 26.1 s, 25.5 s | 18.0 s, 17.9 s |
| of which cc | 13.2 s, 12.9 s | 5.9 s, 5.8 s |

pos1 (examples/pos1.fpr):

| | before | after |
|---|---|---|
| `# fn` entries | 42,574 | 3,495 |
| distinct function names | 3,507 | 3,486 |
| `.globl` function symbols (T) | 2,063 | 2,725 |
| assembly, all files | 2,353,937 lines, 52.1 MB | 732,341 lines, 16.6 MB |
| binary | 12,803,768 B | 3,842,360 B |
| text segment | 7,258,112 B | 2,572,288 B |
| compile cold | 54.6 s, 48.1 s | 33.9 s, 33.0 s |
| compile warm | 24.7 s, 19.6 s | 18.7 s, 18.7 s |
| build warm | 40.3 s, 37.9 s | 26.2 s, 25.8 s |
| of which cc | 19.0 s, 18.1 s | 7.8 s, 7.3 s |

What the numbers say:

- The 27 names still counted twice are the `lifted_N` / `case_join_N`
  coincidences between two units (local symbols); the 22 fewer distinct
  names are the root's `$specaux` constructor copies. Every constructor
  is now one `.globl` definition, which is why the T count rose.
- The `cc` step, half of a warm build before, is a fifth of it now:
  2.2 to 2.4 times faster, because it assembles a third of the lines.
  The warm build is 1.45 (logbook) to 1.5 (pos1) times faster.
- The cold compile is 1.4 to 1.5 times faster: the generator and the A64
  lowering no longer produce 19,617 lines per unit that the linker
  discards. The warm compile moves little (the units are cached; the
  root alone lost its 585 stubs), as expected.
- The binary is a third of its size and the text segment 40%; the 45
  copies of each constructor's code are gone, the one copy per
  constructor remains.

### Verified

- In the worktree with the new compiler: `python3 tests/check_base.py`
  exit 0 (every check PASS, including the runghc compiler checks, since
  the worktree has its own cabal build); `python3 tests/check_std.py`
  exit 0 (todo, logbook, the poller, all PASS); `python3
  tests/check_rv64_linux.py` exit 0 (lowering, flag order and warm-cache
  isolation). `tools/bench.py` reports exactly the set the build-opt page
  recorded as pre-existing at `2ce2f5a` and unchanged here: `workers`
  does not link (`_fpr_g_Bench_x2eelapsed_call1` from the pairLoop
  worker, a private-worker pass matter), pingpong/xpingpong 4 to 5 times
  their old baseline, strbuild 1.15 and fib 1.28 times (1.1 in that
  note; this run shared the machine with other sessions' builds);
  helpers, nbody, sha, vecread, specialization run.
- logbook and pos1 compile, link and start with the new compiler, and
  the page each serves on its first request (`curl` of `/`, 55,780 and
  76,230 bytes) is byte-identical to the one the baseline binary serves;
  every constructor stub (`_fpr_fn_Cons`, `_fpr_fn_Add`,
  `_fpr_fn_Absolute_x400045dd57b08cf1a0`) is defined in exactly one
  file, the prelude unit's, the root's or the declaring unit's, as a
  `.globl`; no `$specaux` constructor copy remains in the root.

### Not verified

- QOS: no native process image or Portable plugin was built or loaded
  (the sibling repo was not touched); the argument above is from the
  link lists the compiler writes. The first QOS check-all after this
  lands recompiles every pinned unit under the `g51` tag.
- RV64 Linux cross builds and execution (`check_rv64_linux.py --cc ...
  --runner ...`): only the default lowering and cache checks ran.
- ESP32 (`--host=esp-idf`): the units go through machine/esp-idf/build.sh
  unchanged in mechanism, not exercised here.
- `--lib` images with two libraries (two `.weak` definitions of the
  unqualified stubs) were not built.
- Run-time behaviour of a program is unchanged by construction (the same
  `call fpr_fn_X` / `la fpr_obj_X` reach the same code through the
  linker instead of a local label); it was not benchmarked beyond
  tools/bench.py.

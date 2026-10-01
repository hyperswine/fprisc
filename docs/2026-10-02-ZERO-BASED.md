# Every position is 0-based

Date: 2026-10-02. Kind: implementation record. It carries out the migration
proposed in [INDEXING](2026-10-01-INDEXING.md), with one decision changed:
names were flipped in place, as a major version, rather than replaced by new
names. That page's register of the split now describes the past.

## The decision

The proposal was to give every 0-based operation a new name and retire the
old ones. That avoids a silent flip, but costs a parallel vocabulary for
months. The choice made was to keep the names and change their meaning. The
risk is that a call site still written for 1-based positions stays in range
and is quietly wrong. Three things contain that risk:

- **One change.** The primitives, the code generator's inline fast path, the
  Sol VM, every call site in both repos and every pinned module that uses
  positions moved in a single change. No mixed state was ever committed.
- **Reviewed, not substituted.** Every site was read in context, loop bounds
  included. `tools/index-sites.py` lists the candidates; four reviewers took
  std, tests and examples, Sol, and QOS.
- **Tests.** The full suites, plus new boundary tests.

## The contract

| Operation | Now |
|---|---|
| `charAt s i` | byte `i`, `0 <= i < strlen s`; otherwise "charAt: index out of range" |
| `substr s off len` | the bytes `[off, off + len)`, cut to the string at both ends (a negative `off` used to keep the whole `len`) |
| `strIndexOf p s`, `strIndexFrom p s i` | 0-based position; **-1 = not found** (0 is a position now); `i` is 0-based |
| `xs ! i` | 0-based |
| `Vec.get` / `Vec.set` | 0-based: the same operations as `Vec.at` / `Vec.put` |
| `sstrAt` / `sstrPut` | 0-based |
| Sol `Str` | `at` and `sub` are 0-based; `slice s i j` is half-open `[i, j)`; `find`/`findFrom`/`indexOf`/`indexFrom` return -1 for none |
| Sol `BStr` | `at` is 0-based; `sub b i j` is half-open |
| `std/string` (major version) | `slice from to` is half-open `[from, to)`; `indexOf`/`indexFrom` return `Some` 0-based position |
| `std/binary`, `std/path`, `std/encoding` error positions, `std/lens`, `Term.moveTo` | 0-based (`moveTo` adds 1 itself: the terminal counts from 1) |

**Unchanged:** lengths and counts (`strlen`, `String.left`/`dropLeft`, take
and drop), `Vec.range lo hi` (inclusive values), `Vec.iota`, byte offsets in
`Mem`/register reads, and `Mod.findAt` attachment numbers.

**Left 1-based on purpose:** numbers meant for people. That covers JSON
error "line L, column C", awk-style field numbers (`$1`), line numbers in the
grep/sed scripts, and labels in Sol examples ("lane 1", "row 1").

**Implementation.**
- **Runtime:** `runtime.c` (`charAt`, `substr`, `strIndexOf`/`From`, `!`),
  `vec.c`, `sstr.c`.
- **Code generator:** the inline `charAt` fast path in `Codegen.hs` no longer
  subtracts 1; `codegenRev` is 26.
- **Sol:** `compiler/Sol/VM.hs` (string natives, `BStr`, list and vector
  indexing) and the `Str` struct in `compiler/Sol/Preamble.hs`.
- **Prelude:** its own uses (`wireInt`, `strTake`, `strSufEq`).

## What moved

**fprisc**
- **std:** 19 modules, among them string, binary, json, encoding, http,
  httpcore, ws, term, view, lens, path, stream, tcp and digest.
- **tests and examples:** dtree, vecedge, linpap, frames, sendlin, fvec,
  fvec2, the byteloop benchmark, base/vecpeek, inlineprims, slotprims,
  std/term, logbook, todo and pos1.
- **Sol:** the libraries (base, csv, json, plparse, logic, matrix, plot),
  the text scripts and the examples. Also the Sol check tools'
  expectations, plus a fix to a class-at-end panic in `rx.sol` that
  predates the flip.

**QOS**
- **Programs and mods:** about 30 files. The local helpers moved too: QAR
  `extent` is 0-based, so the `ipos - 1` that callers used to apply is gone.
  Others are coreutil `wordAt`/`parseDigitsAt`, the `slice` helpers, svc
  `segAfter`, the qlog entry offsets, and the scene2d/voxel vector slots.
- **Pins:** five re-committed modules: uart, coreutil, svc, qlog and tui.

**Expectations that encoded a 1-based position were changed, and only those:**
- string's `indexOf` (4→3);
- extbase's error positions (1/5/1 → 0/4/0) and its `Binary` calls;
- check_base's `charAt` probe (0 is valid now, so it probes -1 and the
  length);
- the Sol check tools' `Str.at`/`substr` arguments and the `removeAt` index;
- QOS coreutil's `wordAt` result.

## Verified

- **The full gates:** every fprisc suite, the Sol checks, QOS smoke and
  `check-all.sh`.
- **`tests/base/zerobased.fpr`** (`check_base`) checks every primitive at
  its first and last index and at "not found". It prints the same line
  natively and under `fpr sol`. Index -1 and index len panic by name for
  `charAt`, `!` and `Vec.get`.

## Not done

- **Error messages written for people** keep their own numbering, as listed
  above.
- **Examples that already failed to type-check** (several Sol examples, and
  QOS's fprlive, voxel and app sources) were migrated by reading only: they
  could not be run before this change either. The migrators compared their
  error lists against the previous commit.
- **`docs/SPLIT-MANIFEST.json` and older dated pages** still name the old
  pin hashes. They are records of their own date.

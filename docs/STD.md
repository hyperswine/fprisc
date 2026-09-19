# The standard library: what ships

Kind: reference for what exists today. The proposal it implements a first slice
of is [PRELIM_BASE_LIBRARY_DESIGN.md](PRELIM_BASE_LIBRARY_DESIGN.md); the older
inventory and tier plan is [STD-PLAN.md](STD-PLAN.md).
Evidence: `python3 tests/check_std.py` (macOS arm64 and Linux arm64, identical output).

```
profile base.
List = use "std/list".
String = use "std/string".
File = use "std/file".

main = case File.lines "words.txt" of
    Ok ls -> ls |> List.map String.trim |> List.sortWith String.compare |> String.join "\n" |> print
  | Err why -> print "cannot read: {why}".
```

`fpr run prog.fpr` builds and runs it, and keeps the executable: the second run
starts in ~20 ms. With `#!/usr/bin/env -S fpr run` as its first line a program
is an executable script ([BASE.md](BASE.md)). A module is a file; `use "std/x"` finds it
under the toolchain's home from anywhere; the name on the left is yours to choose.

## The conventions, everywhere

- **Data comes last**, so calls chain with `|>`.
- **Absence is an `Option`, failure is a `Result`** whose error says why in words
  (the system's own, for OS errors). Nothing in std panics on bad input.
- **Every loop is a tail call** with an accumulator: a list of any length costs no
  stack. (Stacks grow anyway: [BOUNDS.md](BOUNDS.md).)
- **Deterministic**: directory listings are sorted, maps iterate in ascending key
  order, `Json.render` writes keys in order. The same input is the same output.
- **No type classes.** What sorts, and what keys a map, is a function
  `a -> a -> Ordering` you pass (`Order.int`, `Order.string`, `Order.by key cmp`).
- **A String is bytes**, positions are 1-based (as `charAt` and `substr` are);
  UTF-8 passes through split, join, replace and search untouched. Only
  `toUpper`/`toLower` are ASCII-only.
- **Values print as they are written**: `Some 42`, `Err not found`,
  `Node (Node Leaf (-3) Leaf) 7 Leaf`, `{kind = file, size = 6}`.

## Base: the shared foundation (pure; every system)

| module | what is in it |
|---|---|
| `std/option` | `Option a = None \| Some a`; `map andThen withDefault orElse filter isSome isNone toResult fromResult toList` |
| `std/result` | over the builtin `Result`: `map mapError andThen withDefault isOk collect oks` |
| `std/order` | `Ordering = Less \| Equal \| Greater`; `int string fromInt reverse by thenBy min max` |
| `std/list` | `singleton range repeat length isEmpty reverse append concat map indexedMap indexed filter filterMap concatMap fold foldr sum product any all count minimum maximum find member head tail last get take drop takeWhile dropWhile partition zip zipWith unzip intersperse unique sortWith sortBy groupBy each` -- sorting is a STABLE merge sort |
| `std/string` | `length isEmpty join concat append split lines words indexOf indexFrom contains startsWith endsWith count slice left right dropLeft dropRight trim trimLeft trimRight replace repeat padLeft padRight reverse toUpper toLower codes fromCodes mapCodes isSpace isDigit isAlpha fromInt toInt compare` |
| `std/map` | a persistent AVL tree keyed by a comparator given once: `empty strings ints fromList insertAll size isEmpty get getOr member insert remove update fold entries keys values map filter union first equal equalBy` |
| `std/set` | over Map: `empty strings ints fromList insertAll insert remove member size isEmpty toList union intersect diff` |
| `std/path` | pure text: `isAbsolute join joinAll fileName parent extension stem withExtension parts normalize` |

`==` on two maps compares their TREES, whose shape depends on insertion order:
use `Map.equal` / `Map.equalBy` (and `Json.equal`).

## Base: the environment (the posix system)

These stand on nine primitives declared in `std/os.fpr` and implemented by
`machine/posix/os.c`. On a system without them a program that imports these
modules fails at LINK time on the `fpr_g_Os_` name: imports are the manifest.

| module | what is in it |
|---|---|
| `std/program` | `args env envOr exit fail readLine readLines writeLine writeError` |
| `std/file` | whole files: `readText readBytes lines writeText appendText writeLines exists info isFile isDir size remove rename copy`; `info` answers `{kind, size, modified}` |
| `std/dir` | `list entries walk glob matches create` (with parents) `remove removeAll current` |
| `std/proc` | `run runIn pipeTo spawn output shell` -- an ARGUMENT LIST, never parsed; stdout, stderr and status distinct; `Err` only when it could not start; `shell` is the explicit `/bin/sh -c` |
| `std/clock` | `monotonic elapsedMs now sleepMs date iso civil` -- the calendar is computed here, not by libc |

## ExtBase

| module | what is in it |
|---|---|
| `std/json` | `Value = Null \| Boolean \| Integer \| Real \| Text \| Sequence \| Object`; `parse` (errors as `line 3, column 14: expected ':'`), `render`, `equal`, `field at asString asInt asBool asReal asList asObject isNull object strings`. A `Real` keeps its TEXT: no float parsing to get wrong |

## The acceptance programs

The design names three. One exists: `examples/report.fpr`, the automation script
(walk, filter, group, sort, ask `git`, write a JSON report; failures in words,
exit codes). It compiled and ran on the first attempt against these modules,
which is the point of them.

## Not here yet (from the design's inventory)

- **Base:** `Math`; `Vector` (the prelude's linear `Vec.*` is the substrate);
  streaming `File` handles (`open read write seek close`), `Buffer`/`Binary`;
  typed `Actor`/`Mailbox` wrappers and `receiveWithin`; `Atomic`.
  `Proc`: a timeout, an environment for the child, streaming.
- **ExtBase:** `Decode`/`Encode` into records, `HTTP`/`TCP` (the posix system has
  no socket primitive yet), `Digest`, `Encoding` (hex, Base64, URL), `Log`,
  `Config`, `Task`.
- **Sol:** these modules are FP-RISC source and Sol shares the language, but
  Sol's `Str`/`List` structures (compiler/Sol/Preamble.hs) still have their own
  names and argument orders. The four new runtime string primitives deliberately
  took Sol's names and contracts (`strJoin strCmp strIndexOf strIndexFrom`); the
  modules above are the vocabulary to converge on.
- The other two acceptance programs: the concurrent service and the numerical
  analysis (`Array`, `Stats`, `CSV`).

## Friction found while writing it (evidence for the next additions)

- A lambda cannot take `_` as a parameter (`fn k _ -> ...`).
- A literal `{` in a string must be written `\{`, because `{` starts interpolation;
  JSON text in source is noisy.
- There is no `if`/`else`: every two-way choice is a `case ... of True -> |
  False ->`, which dominates the look of parsing code (std/json.fpr). Infix
  `and` / `or` exist and short-circuit; chains of character tests read well.
- Every recursive function needs its own `name : unsafe ...` signature; a module
  of small loops is half signatures.
- `fileWrite` answers `Ok ""` typed as `Result Unit String`.
- `machine/posix/base.c` still copies paths into `char[1024]` and panics "path
  too long"; `os.c` does not.

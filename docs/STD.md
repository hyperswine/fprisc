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

These stand on the primitives declared in `std/os.fpr` and implemented by
the facility files in `machine/posix` (`os_fs.c`, `os_clock.c`, `os_io.c`,
`os_net.c`, `os_proc.c`, `os_watch.c`, `os_term.c`). On a system without them a program that imports these
modules fails at LINK time on the `fpr_g_Os_` name: imports are the manifest.

| module | what is in it |
|---|---|
| `std/program` | `args env envOr exit fail readLine readLines writeLine writeError` |
| `std/file` | whole files: `readText readBytes lines writeText appendText writeLines exists info isFile isDir size remove rename copy`; streaming: `open seek withOpen` (closes on every path) |
| `std/dir` | `list entries walk glob matches create` (with parents) `remove removeAll current` |
| `std/proc` | `run runIn pipeTo runWithin runWith describe spawn output shell` -- an ARGUMENT LIST, never parsed; stdout, stderr and status distinct; `Err` only when it could not start; a time limit kills the child and says so; extra environment; `shell` is the explicit `/bin/sh -c` |
| `std/clock` | `monotonic elapsedMs now sleepMs date iso civil local stamp receiveWithin` -- the calendar is computed here, not by libc; only the zone offset (`Os.tzOffset`) comes from it |
| `std/stream` | bytes in order from a file or a socket: `read readWithin readAll readOn write close`, and a `Reader` (`reader`, or `readerOn poller`) that keeps what was read past what you asked for: `reader readUntil readLine readExactly readRest` |
| `std/poller` | ONE actor that waits on every descriptor: `start await`. Waiters sleep in their mailboxes; one `poll(2)` covers them all; one-shot, level-triggered; a quiet turn allocates nothing |
| `std/tcp` | `connect listen port accept stop serve serveOn` -- `serve` gives each connection its own actor and closes it when the handler returns |
| `std/term` | a terminal application, the same shape as a web one: `run { init, update, view, subs }`, `Ev msg = Key k \| Resized c r \| Msg m`, `Cmd msg = After \| Run \| Quit`, `Sub msg = Every`; keys decoded in FP-RISC (`decode`: a UTF-8 character at a time, arrows, Home/End, F-keys, Ctrl, Alt); `clear moveTo bold dim inverse color altScreen`; lines repainted only when they change; the terminal is put back however the program ends |
| `std/math` | Int: `abs min max clamp sign mod rem isEven gcd powInt`; F64: `pi e toFloat truncate floor ceiling round sqrt pow exp log log2 sin cos tan absF minF maxF clampF isFinite format` |
| `std/binary` | fixed-width integers in a byte string: `u8 u16le u16be u32le u32be i8 i16le i32le i32be` (past the end is `None`), `putU8 putU16le putU16be putU32le putU32be` |

**Waiting never blocks a hart.** A hart is a thread many actors share, so the
socket primitives are non-blocking and answer `"again"`; `std/stream` puts the
ACTOR to sleep (0.1 ms backing off to 4 ms) and retries. A server and its
clients run in one process, which is how the tests run them.

## ExtBase

| module | what is in it |
|---|---|
| `std/json` | `Value = Null \| Boolean \| Integer \| Real \| Text \| Sequence \| Object`; `parse` (errors as `line 3, column 14: expected ':'`), `render`, `equal`, `field at asString asInt asBool asReal asList asObject isNull object strings quote`, and `fromWire toWire encode decode` for any type with a compiler-minted codec (`@Msg`, `@Model.field`: docs/PATHS.md). A `Real` keeps its TEXT: no float parsing to get wrong |
| `std/decode` | flexible data into YOUR types: `string int bool number value succeed fail nullable field optional at list dict map andThen check oneOf map2..map5 andMap run fromString infer fields`. Errors name the path: `servers.1.tags.1: expected a string, found an integer` |
| `std/config` | `load` combines defaults < a JSON file < `PREFIX_NAME` in the environment < `--name=value`, into a Value you decode; `positional` |
| `std/http` | client: `get post request parseUrl parseResponse`; server: `serve serveOn text html json response header`. HTTP/1.1, lower-case header names, chunked decoding, one request per connection. **`https://` is fetched by running `curl`** (std has no TLS); where curl is missing the Err says so. Everything but the curl transport is `std/httpcore`, which this wraps name for name |
| `std/httpcore` | the same API without HTTPS, so it needs sockets and no processes: a board (`--system=esp-idf`) serves HTTP with it. `serveOn poller` waits for connections and request bytes on a Poller; an `https://` URL answers Err saying there is no TLS transport |
| `std/encoding` | `hex fromHex hexInt base64 fromBase64 url fromUrl query` |
| `std/digest` | SHA-1 (for protocols that name it: `sha1 sha1Bytes`) and SHA-256 in FP-RISC: `sha256 sha256File` (streamed) and incremental `init update finish finishBytes`. About 1 MB/s: for files and configuration, not bulk data |
| `std/log` | a logger is a VALUE: `toStderr toFile json levelOf debug info warn error`. `2026-09-20T03:14:15Z INFO  listening port=8080`, or one JSON object per line |
| `std/ws` | WebSocket, the server side (RFC 6455): `accept receive receiveMax receiveOnly sendText sendBinary sendPong sendClose frame`. Whole messages: fragments reassembled, all three length forms, nothing capped unless you ask |
| `std/kvlog` | a durable key-value store that is an APPEND-ONLY log: `open put post sync get keys size compact` (`post` appends without waiting; `sync` waits for this actor's posts), and on the file itself `records history at`. Replays on open; a torn last line is skipped and counted |
| `std/store` | a keyed collection kept by SHARD actors: `open put remove get count page search`. Each shard caches its part in memory, appends to its own file and compacts only that file when it is mostly superseded; a front actor routes writes and answers reads with a plan, so readers ask shards directly and a search scans every shard at once. See [LIVE.md](LIVE.md) |
| `std/live` | a server-driven UI over a websocket, the LiveView way: `serve serveCached serveProjected replay` (`serveProjected`: each session is sent only its `project sid model` and renders nothing when it is unchanged), durable fields from paths (`field`, `custom`, and `each` for a list kept one record per element), `Ev msg`, `Cmd msg`, `Sub msg`, `Policy`. Messages are the app's own type, carried by `@Msg`. See [LIVE.md](LIVE.md) |
| `std/view` | the view tree (`El Txt Dyn Inp`, attributes), `render` to (statics, dynamics), generated CSS; and the TYPED helpers: `send sendWith enterWith` (a message VALUE through a codec), `locals showIf setTo bind text` (client state named by paths) |
| `std/ma` | the Ma design system over View: `vstack hstack zstack spacer card cardGrid button badge chip toast accordion navBar page`, text roles, `maCssFor` |
| `std/livejs` | the client script (~150 lines), served inline |
| `std/actor` (additions) | `sendSure` / `askSure`: a send that is not lost (`send` never waits, and a refused request is somebody waiting forever); `boundary` / `tidy`: how a long-lived actor stays the same size |
| `std/task` | `map mapBounded`: the same work on many inputs, an actor each, at most `n` at once, results in input order |

## Platform libraries: what a board has beyond the language

Neutral names for hardware, implemented per platform (today
`platform/esp-idf/`, for `--system=esp-idf`). A program importing one links
only where a platform provides it, and fails by name elsewhere; a program
that does not import one does not carry its code (a board image without
`std/ble` has no Bluetooth stack in it). docs/ESP-IDF.md has the design.

| module | what is in it |
|---|---|
| `std/wifi` | `info scan startAp stations stop`, typed records (`{ ssid, rssi, channel, auth }` per network). The access point's password rule is the protocol's, refused by name: `""` is an open network, otherwise 8-63 characters or 64 hex digits |
| `std/ble` | `scan ms` (address, rssi, name; strongest first), `advertise name ms` (1-26 bytes) |
| `std/gpio` | `pins level info describe` (reading changes nothing), `input output write` (answer a Result) |
| `std/esp` | the ESP32 chip itself: `core ms freeKb random` |
| `std/job` | the seam under std/wifi and std/ble: blocking host work run off the harts, `run result rows field number parseAll one`. You do not normally use it |

## The acceptance programs

The design names three. Two exist, and both are driven by `tests/check_std.py`:

- `examples/report.fpr`, the **automation script**: walk, filter, group, sort,
  ask `git`, write a JSON report; failures in words, exit codes. It compiled and
  ran on the first attempt against these modules, which is the point of them.
- `examples/service.fpr`, the **concurrent service**: settings decoded from
  defaults, a file, the environment and the command line; an HTTP key-value
  store where ONE actor owns the Map and every connection is an actor that asks
  it; a digest per line with bounded parallelism; every request logged, failures
  at WARN; `POST /shutdown` stops the listener and the program exits 0. The test
  hits it with 40 parallel writes.
- `examples/todo.fpr` is a TERMINAL app (`std/term`): the same init / update / view
  / subs, keys where the clicks were, a durable list through a minted codec. The
  suite drives it through a pseudo-terminal.
- `examples/wc.fpr` is an executable script (`#!/usr/bin/env -S fpr run`).

## Not here yet (from the design's inventory)

- **Base:** `Vector` (the prelude's linear `Vec.*` is the substrate); an owned,
  resizable `Buffer`; a LINEAR stream handle (today a Stream is a plain value you
  close, and `withOpen` / `Tcp.serve` close for you); typed `Actor msg` wrappers;
  `Atomic`. (A timed receive exists now: `Clock.receiveWithin`, over the runtime's
  `receiveNow`.)
- **ExtBase:** TLS in std (HTTPS rides on curl); HTTP keep-alive and streaming
  bodies; password hashing and other digests; `Encode` from records (there is no
  reflection: you build a `Json.Value`).
- **Sol:** the PURE modules now run in Sol unchanged (`tests/std/solstd.sol`:
  list, string, map, option, order, json), and Sol prints values as written too.
  That took two fixes in Sol's module splicing (compiler/Sol/Lang.hs: the rename
  pass skipped function types in signatures; a module reached twice was only
  re-pointed in expressions, not patterns or types) and `strIndexFrom` in the VM.
  Still open: the alias names `List` / `Str` collide with Sol's builtin
  structures (use `L`, `S`); the posix modules need the `Os.*` primitives, which
  the VM does not have -- and should get as TRANSACTIONAL operations, not as
  these immediate ones (docs/TRANSACTION.md).
- The third acceptance program: numerical analysis (`Array`, `Stats`, `CSV`, `Plot`).

## Friction found while writing it (evidence for the next additions)

- A lambda cannot take `_` as a parameter (`fn k _ -> ...`).
- A literal `{` in a string must be written `\{`, because `{` starts interpolation;
  JSON text in source is noisy.
- ~~There is no `if`/`else`.~~ ADDED while writing this: `if c then a else b` is
  sugar for `case c of True -> a | False -> b` (compiler/FPRISC.hs `ifE`; both
  profiles, since they share the parser). Branches take the block form and
  `else if` chains; `std/json.fpr`'s escape tables show the difference. Infix
  `and` / `or` already existed and short-circuit.
- Every recursive function needs its own `name : unsafe ...` signature; a module
  of small loops is half signatures.
- `fileWrite` answers `Ok ""` typed as `Result Unit String`.
- The prelude's `serve` DROPS each request after answering it, so state that keeps
  part of a request dangles unless it is `keep`-copied first. The service example
  crashed on its second request until `Put k v` stored `keep k`, `keep v`.
  Nothing warns about this.
- A panic in ANY actor ends the whole program on this system, so a library
  cannot turn one failed task into an `Err`.
- `receiveRes` waits for a message that is a `Result`; a bare tuple sent to it is
  never received, and the program ends in the deadlock detector.
- `machine/posix/base_file.c` still copies paths into `char[1024]` and panics
  "path too long"; `os_fs.c` does not.

---
name: sol
description: Write, run, debug and extend Sol, the transactional scripting language of the FP-RISC toolchain (the same language and type system as FP-RISC, run on a bytecode VM that ships inside `fpr`). Use it when the user mentions Sol, .sol files, `fpr sol`, `>`/`>!` statements, scripts under tools/, sol/ or machine/ in the fprisc repo, or the Sol VM (sol-vm/Sol/*.hs). Not for compiling FP-RISC to native or RISC-V, except where a library must behave the same on both sides.
---

# Sol

Sol is FP-RISC run as a script: the same parser, type inference, linearity and
safety checks, and the same `std` library, executed by the Sol VM inside `fpr`.
Effects are transactional. Each `>` statement is one transaction over the
filesystem (and deferred commands), committed when the statement ends. A `>!`
statement runs immediately, for work a transaction cannot hold (serial ports,
child processes, streams). This file was refreshed on 27 November 2026; the
fprisc repo's `docs/` (chronological, `docs/README.md` indexes them) is the
record.

## Running

```bash
./fpr sol script.sol [args]       # from an fprisc checkout (the branch's Sol)
sol script.sol [args]             # an installed toolchain (fprmeta); may be older
./fpr sol --repl                  # one command, one transaction
```

- `fpr` acts as Sol when called `sol` or as `fpr sol`. A symlink named `sol`
  pointing at a checkout's `fpr` gives that checkout's Sol; `/opt/homebrew/bin/sol`
  may be an older release.
- Sol trusts libraries (the safety allow-list, `compiler/Safety.hs`) only under
  the `fpr` binary's home: from a worktree, run that worktree's `./fpr`.
- The repo's Sol checks: `FPR_HOME=$PWD FPR_CHECK_SOL=<dir>/sol <dir>/sol tests/run.sol --jobs 2`,
  with `<dir>/sol` a symlink to the branch's `fpr`.

## Shape of a script

```sol
J = use "std/jsondoc".                 # std modules by name; files by relative path
B = use "../sol/lib/build".

double x = x * 2.                      # top-level definitions end with "."
count : unsafe List a -> Int .         # recursion without a measure is `unsafe`
count xs = case xs of [] -> 0 | x :: rest -> 1 + count rest.

> doc = unwrap (J.parse (readPath "config.json"));   # one transaction
  writePath "out.json" (J.pretty (J.set "n" (J.JNum 3) doc) + "\n").

>! port = unwrap (Serial.open "/dev/cu.usbserial-1" 115200);  # acts now
   (w, p1) = Serial.write (unwrap (Utf8.encode "status\n")) port;
   (seen, p2) = Serial.expect "> " 5000 p1;
   _ = Serial.close p2;
   print (Utf8.decodeReplace (unwrap seen)).
```

- A script with no statements runs a zero-argument `main`; if `main` answers
  an Int, that is the exit status (as native). With statements, only the
  statements run; end with `>! Script.exit (main Unit)` to set a status.
- A statement's value can be named for later statements: `x =\n  > ...`.
- Blocks chain with `;`. Interpolation is `"{expr}"`; a literal brace is `\{`.
- Local functions with block bodies do not parse on one line: lift them to
  top level.
- `List.range a b` includes `b`.
- Strings are UTF-8 bytes on both sides: `strlen`, `charAt`, `substr`,
  `Str.indexOf` and `Str.slice` count bytes; `chr` makes one byte.
- Floats are `F64`, as native (since 27 Nov 2026): `Int` and `F64` do not mix,
  and mixing is a type error; convert with `F64.ofInt n`, `F64.toInt x`,
  `Num.floor`/`Num.round x`. An unannotated `a + b` or `<` (also on a record
  field) defaults to `Int`: give float helpers a signature. `%` is `Int` only;
  `F64 ^ F64` is `exp(y log x)`, as native. `==` and printing do not reach a
  float inside a structure (a tuple, list or record): compare or print it with
  `F64.==`/`F64.str`, and test a float list for `[]` with a `case`.
- Defining a prelude name (`run`, `write`, `close`, `print`, ...) is an error or
  a confusing type error: pick another name.

## Transactions and effects

- `>`: reads are snapshots validated at commit; writes (`writePath`,
  `writeBytes`, deferred `Proc.later`/`afterCommit`) land at commit,
  atomically. A panic leaves nothing behind.
- `>!`: immediate operations only make sense here and are refused in `>`:
  `Serial.*`, `Child.*`, `Stream.*`, `Proc.runNow`/`streamNow`/`pipeline`,
  `writeNow`/`appendNow`, `Fs.renameNow`, `Http.request`.
- `print` is immediate in both.

## Libraries

- **`std` serves both sides** (one source, `tests/sol-checks/std-shared.sol`):
  `std/jsondoc` (ordered JSON: `parse`, `parseWith (Limits ...)`, `render`,
  `pretty`, `get`, `path`, `set`, `JNum` exact Int, `JReal` text), `std/json`
  (Map model), `std/test` (`Test.run [Test.that .., Test.equal ..]` answers the
  exit status), `std/list`, `std/string`, `std/map`, `std/option`, `std/order`,
  `std/ui` and `std/view` (render identically).
- **Web pages:** `sol/lib/live.sol` serves a `std/ui`/`std/view` page on
  `std/live`'s wire (`Live.serve port { title, init, update, view, codec = @Msg }`,
  see `sol/examples/live-counter.sol`), and `Live.serveApp port app store` takes
  `std/live`'s whole app shape (events, commands, `Every` subscriptions,
  per-session views, a durable store, patches; `sol/examples/live-room.sol`);
  `View.serve` with `sol/lib/ui.sol` is
  the older Sol-only Html driver.
- **`sol/lib`** holds what is Sol-only: `build` (process helpers), `cli`,
  `csv`, `git`, `archive`, `http`, `digest`, `proc`, `ui` (the `View.serve`
  Html), ...
- **Built in:** `Bytes` (codecs `u8`..`u64be`, `put*`, `patch`, `crc32`),
  `readBytes`/`writeBytes`, `Hex`, `Sha256`, `Utf8`, `Num` (`sin` ... `log2`,
  `pow`, bit-exact with native), `band`/`bor`/`bxor`, the `BIT*` operations,
  and the linear handles `Serial` (any baud rate) and `Child` (a process on
  pipes: `open`, `write`, `read`, `expect`, `wait`, `kill`).

## Linearity

`Serial`, `Child`, streams and `Vector` are linear: thread each one through
(`(r, h2) = Serial.read 10 100 h`) and consume it exactly once on every path,
failure paths included. Close a handle before `error` or `Script.exit`, or
wrap the failure (`fail l code msg = _ = close l; die code msg`). A record
holding a linear field must be destructured whole; a closure may not capture
one when `List.map`/`fold` may call it many times.

## Debugging

- Errors are grouped: `TYPE ERRORS`, `SAFETY`, `LINEARITY`. Fix the first
  group; the next appears after.
- `unsafe` cascades: a function calling an unsafe one needs `: unsafe ...` too.
  Prefer a fold over recursion where it removes the marker.
- `*** SOL PANIC: ... ***` is a runtime failure; `Script.exit n` ends the run.
- For the VM itself: `sol-vm/Sol/` (`Main.hs` statements and transactions,
  `Hal.hs` primitives, `Preamble.hs` types, `Lang.hs` module splicing,
  `Serial.hs` ports and children, `Txn.hs` commit). Rebuild with `make fpr`.

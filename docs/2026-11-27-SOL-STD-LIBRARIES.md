# One library for FP-RISC and Sol, and the board runner in Sol (27 November)

Kind: delivery record. Branch `sol-libs`. Item 5 of the
[Sol review](2026-11-26-SOL-SCRIPTING-REVIEW.md) order (one library with `std`,
audit item 6), and the rest of item 3: the C helpers the board runner needed.
The first step, byte-indexed strings, is
[SOL-BYTE-STRINGS](2026-11-27-SOL-BYTE-STRINGS.md).

## Result

| | Before | Now |
|---|---|---|
| JSON | `sol/lib/json.sol` (Sol) and `std/json.fpr` (native, a Map model) | `std/jsondoc.fpr`, one ordered-document library for both; `std/json.fpr` also runs in Sol |
| Tests | `sol/lib/test.sol` (Sol) and `std/test.fpr` (native) | `std/test.fpr` for both |
| View types | `std/ui` and `std/view` did not load in Sol | they load and render the same bytes as native |
| Board runner | `examples.sol` drove a C helper, `board-host.c` | `board-host.sol`, with a new `Child` process handle for QEMU |

`tests/sol-checks/std-shared.sol` (push) runs each file in `tests/shared` once
natively and once as a Sol script, and requires identical stdout bytes and
exit status: `jsondoc`, a `std/ui` page (17 KB of statics and stylesheet), and
a `std/test` run that ends with status 1.

## JSON: `std/jsondoc`

The owner chose the ordered model (27 November): Sol's JSON moved into `std`
as `std/jsondoc.fpr`, and `std/json`'s Map-based `Value` stays for its native
users. The 41 fprisc Sol scripts that used `sol/lib/json` now `use
"std/jsondoc"`, and `sol/lib/json.sol` is gone. qos and coscad scripts change
their `use` line when their Sol pin moves past this commit.

Same as `sol/lib/json`:
- the names (`Json`, `JNull` ... `JObj`, `parse`, `parseWith`, `Limits`,
  `render`, `pretty`, `get`, `path`, `set`, ...);
- objects keep input order and duplicate keys;
- the rendered text, byte for byte, including control characters as `\u00XX`,
  so files written and hashes taken over rendered JSON did not change.

What changed:
- **Numbers.** `JNum` is an exact Int. A number with a fraction or exponent, an
  integer past 62 bits, or `-0` is `JReal` with its text, and renders as
  written. Before, Sol held these as inexact numbers inside `JNum`, so `1.5e3`
  came back as `1500.0`. `J.num` refuses a `JReal`; `J.real` gives the text of
  either kind. Sol still lets a script put an inexact number in `JNum`, which
  renders but parses back as `JReal` (`sol/examples/jsoncsv.sol` shows it).
- **Admission** is checked by the parser itself, so it works natively: text
  bytes, nesting depth, items per container and decoded string bytes. Before,
  Sol ran a separate Haskell pass (`Format.json`) first.
- **`parseLineWith` is gone.** Its one caller decodes the line and calls
  `parseWith`.

## Tests: `std/test`

`std/test` gained Sol's generic `equal` (native interpolation shows any value).
For a test file to mean the same on both sides, Sol now treats an auto-run
`main`'s Int as the exit status, as native does (`sol-vm/Sol/Main.hs`, through
the `Script.exit` path). A Sol script with statements ends with
`>! Script.exit (Test.run [...])`. The two callers and the `fpr new` Sol
template moved; `sol/lib/test.sol` is gone.

## View types: `std/ui` and `std/view` in Sol

Two Sol bugs kept them from loading:
- **Record types were not module-qualified.** A record type's field types kept
  bare names when its module was imported under an alias, so `vary : List
  Variant` in `std/ui` failed against `X.Variant`. All three renamers in
  `sol-vm/Sol/Lang.hs` now treat a record type like a data type.
- **`Vec.pack`** (n bytes of an Int vector as a string, under `std/binary`'s
  `Bytes.pack`) was missing in Sol, so `std/encoding` failed to load.

Sol does not yet serve a `std/view` page: `View.serve` still takes the Sol
`Html` type in `sol/lib/ui.sol`. A Sol driver for `std/view`'s
statics/dynamics protocol with `std/live`'s client is the next step; the
types it would serve are now shared.

## The board runner: `board-host.sol` and `Child`

`machine/tangnano20k/board-host.sol` replaces `board-host.c` with the same
command line and exit statuses. `examples.sol` runs it with its own Sol.
- `board` uses `Serial` at the board's rate (clock/868, e.g. 96774 baud) and
  `Bytes.crc32` for the SRU1 upload.
- `qemu` runs QEMU as a `Child` whose stdin and stdout are the guest's UART.
- `dtree` prints the same reference as the C helper, digests and SHA-256
  included, for 512/128/16/6/5. It now uses Sol's `Num.log2` rather than libm,
  and says so in the JSON.

`Child` is a new linear handle with `Serial`'s operations (`sol-vm/Sol/Serial.hs`,
`compiler/cbits/sol_serial.c`):

| Operation | Type |
|---|---|
| `Child.open` | `List String -> Result Child String` |
| `Child.write` | `Bytes -> Child -> (Result Unit String, Child)` |
| `Child.read` | `Int -> Int -> Child -> (Result Bytes String, Child)` |
| `Child.expect` | `String -> Int -> Child -> (Result Bytes String, Child)` |
| `Child.wait` | `Int -> Child -> Result Int String` |
| `Child.kill` | `Child -> Unit` |

- The child runs in its own process group, with stderr inherited.
- `wait` closes its stdin and answers the exit status (128+signal). After the
  timeout it terminates the group, then kills it.
- A read at end of output is an `Err`.
- All six are immediate operations (`>!` only). `Proc.wait` already named a
  background job's wait, hence the namespace.

## Fixed on the way

- **`Str.indexOf` counted characters** while every other position counted bytes
  (the byte-strings change missed `strIndexOf` and `strIndexFrom`). A slice at
  that position cut through `雪` in the `args` case. The string parity test now
  covers `indexOf` and `slice`.
- **Builtin targets did not build.** The interpolation change (3404a40d) called
  `alloc_window` from code every target compiles, but defined it only for
  hosted ones. On builtin targets it is now a stub that answers 0, so callers
  take `fpr_alloc`.
- **`examples.sol` could not rewrite its own report.** `writeStreamed` used
  `Stream.openWrite`, which refuses an existing file, so the second save of
  `results.json` failed. It is now the prelude's `writeNow`.
- **The wrong programmer.** With the Tang Nano and the Arty both attached (two
  0403:6010 bridges), `openFPGALoader -b tangnano20k` took the first one and
  found no device. `examples.sol` now passes `--ftdi-serial`, taken from the
  board's UART name.
- `std/jsondoc` is on the safety allow-list with a line in
  [the review](2026-10-15-SAFETY-ALLOW-LIST-REVIEW.md);
  `tools/sol-library-capabilities.json` lists it and `std/test` as hosted.

## Runs

- QEMU suite, Sol runner: 7/7.
- Tang Nano 20K, fprisc-84 bitstream programmed into SRAM, Sol runner: 7/7; the classifier 6.83 s a run (10 runs, 6.825-6.833 s).
- Arty S7-50, arty-s7-81 (DDR3), Sol runner: 7/7; the classifier 6.47 s a run (10 runs, 6.474-6.478 s).

## The `sol` skill

`sol/SKILL.md` is a refreshed `sol` skill (item 4 of the review: the installed
one describes the retired `sol-lang` repository, pre-0.13). The installed copy
is managed outside this repository; publishing this file there is the owner's
step.

## Not done

- **Spectre helpers.** `spectre-uart.c` and the byte-packing half of
  `spectre-image.c` are in qos, whose scripts run on a pinned Sol without
  `Bytes`, `Serial` or `Child`. Porting them waits for that pin to move to a
  release that has them. The LZ4 compression stays C until Sol has a library
  for it.
- **A Sol driver for `std/view` pages** (above).
- **`std/math` in Sol.** It uses `F64`, which Sol does not separate from `Int`.

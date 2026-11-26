# Sol: binary data and serial ports (27 November)

Kind: delivery record. Branch `sol-libs`. It finishes item 4 of the
[Sol review](2026-11-26-SOL-SCRIPTING-REVIEW.md) order (§5.4); the maths part is
[float maths parity](2026-11-27-FLOAT-MATHS-PARITY.md).

What the ports needed C for: the Spectre port's `spectre-image.c` (packed
headers, CRCs, patching words inside a bitstream) and `spectre-uart.c`, and the
board runner's `board-host.c` (a serial transport with expect, at non-standard
baud rates).

## Bytes

Sol's `Bytes` had `empty`, `fromList`, `toList`, `len`, `at`, `slice`, `concat`
and `contains`. Added:

| Operation | Type | Notes |
|---|---|---|
| `Bytes.u8`, `u16le`, `u16be`, `u32le`, `u32be`, `u64le`, `u64be` | `Int -> Bytes -> Option Int` | `std/binary`'s names and rule: a read past the end is `None` |
| `Bytes.putU8` ... `putU64be` | `Int -> Bytes` | the low bits; negatives wrap as two's complement, as `std/binary`'s writers |
| `Bytes.set` | `Int -> Int -> Bytes -> Result Bytes String` | one byte; index and value checked |
| `Bytes.patch` | `Int -> Bytes -> Bytes -> Result Bytes String` | overwrite a range; bounds checked |
| `Bytes.crc32` | `Bytes -> Int` | IEEE 802.3, zlib's (check value of "123456789" is 0xCBF43926) |
| `readBytes` | `String -> Result Bytes String` | transactional: this statement's own write, else a snapshot validated at commit |
| `writeBytes` | `String -> Bytes -> Unit` | transactional: a queued whole-file write |

`readBytes` and `writeBytes` are ordinary transactional operations, allowed in
`>` statements. A binary file used to be readable only through immediate
streams, so binary work could not be transactional.

**How the transaction layer carries them:**
- A new effect, `EWriteBytes`, holds the exact bytes. It goes through the
  journal, redo and replay, written by the same atomic rename as text.
- A bytes view makes a later `readBytes` in the same statement see the write.
- A text read of a path written as bytes answers its text if it is valid UTF-8,
  and refuses it as binary otherwise.
- A text write or a remove clears the bytes view.

## Serial ports

A port is a linear `Serial` handle, threaded like `BStr`:

```sol
>! port = unwrap (Serial.open "/dev/cu.usbserial-1" 62212);
   (w, p1) = Serial.write (unwrap (Utf8.encode "status\n")) port;
   (seen, p2) = Serial.expect "> " 5000 p1;
   _ = Serial.close p2;
   print (Utf8.decodeReplace (unwrap seen)).
```

| Operation | Type |
|---|---|
| `Serial.open` | `String -> Int -> Result Serial String` (path, baud) |
| `Serial.write` | `Bytes -> Serial -> (Result Unit String, Serial)` (10 s timeout) |
| `Serial.read` | `Int -> Int -> Serial -> (Result Bytes String, Serial)` (at most n bytes, timeout ms; empty if nothing came) |
| `Serial.expect` | `String -> Int -> Serial -> (Result Bytes String, Serial)` |
| `Serial.close` | `Serial -> Unit` |

- **Baud rate and framing:** raw 8N1 with no flow control, at any baud rate.
  Rates that termios names are set the portable way. Others go through
  `IOSSIOSPEED` on macOS and `termios2` on Linux (`compiler/cbits/sol_serial.c`).
- **`expect`** answers everything up to and including the text and keeps the
  bytes after it for the next `read` or `expect`. That is `spectre-uart.c`'s
  rule, so bytes that arrive in the same read as a prompt are not lost. A timeout
  is an `Err` and keeps what arrived.
- **Where it is allowed:** every serial operation acts now, so all five are
  immediate operations, allowed in `>!` statements only; a `>` statement that
  reaches one is refused.

## Tests

- `tests/sol-checks/sol-bytes.sol` (push) covers:
  - the codecs, `set`/`patch` and CRC-32;
  - transactional binary files, checked against the bytes on disk;
  - a statement that panics after `writeBytes` leaving no file;
  - both serial refusals.
- The `SolSerial` unit suite runs `Sol.Serial` against a pseudo-terminal pair:
  - `expect` keeping what follows its match;
  - timeouts that keep what arrived;
  - writes reaching the device;
  - a missing port.

**Not tested here:** a real board, and with it a non-standard baud rate, which a
pseudo-terminal cannot show. A Tang Nano bridge is attached to this Mac, but
nothing was sent to it without the owner's word.

## What this unblocks

`spectre-uart.c` and `board-host.c` can become Sol over `Serial`, and the image
packing in `spectre-image.c` that is plain bytes and CRCs can become Sol over
`Bytes`. What stays C there is the LZ4 compression, which Sol has no library
for. Each port is its own change, with its board run as the test; none was done
here.

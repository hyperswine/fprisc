# Sol strings count bytes, as native does (27 November)

Kind: delivery record. Branch `sol-libs`. It implements, for Sol, the string
rule the owner decided on 26 November ([v1.0 semantics](2026-11-26-V1-SEMANTICS.md)
§5: `String` is UTF-8 indexed by byte). It is the first step of item 6 of the
[Sol review](2026-11-26-SOL-SCRIPTING-REVIEW.md) order (one library with `std`):
a library shared by both sides needs strings to mean the same thing on both.

## What changed

**Before:** Sol counted code points, so `strlen "é"` was 1 in Sol and 2 natively,
and `charAt` and `substr` disagreed with native on any text that is not ASCII.

**Now:** lengths and positions in Sol count UTF-8 bytes, exactly as native does
today:

| | Native | Sol before | Sol now |
|---|---|---|---|
| `strlen "aé€😀z"` | 11 | 5 | 11 |
| `charAt "aé€😀z" 1` | 195 | 233 | 195 |
| `substr "aé€😀z" 1 2` | `é` | `é€` | `é` |
| `strlen (chr 233)` | 1 (byte 0xE9) | 1 (U+00E9, two bytes when printed) | 1 (byte 0xE9) |
| `Str.codes "é"` | `[195, 169]` | `[233]` | `[195, 169]` |

`tests/fmath/strings.{fpr,sol}`, run by the `fmath-parity` check, prints these
cases on both sides and compares the output byte for byte. It matches,
including the raw bytes that `chr 233` and a slice inside a character produce.

## How

- **The index holds bytes.** A Sol string is Haskell text plus a lazily built
  index (`Sol.Val`); the index now holds the string's UTF-8 bytes rather than
  its characters.
- **Invalid bytes are escapes.** A byte that is not part of valid UTF-8 (from
  `chr` above 127, or a slice through a character) is held as the lone surrogate
  U+DC00+byte, the round-trip scheme Python also uses.
  - Every encoder writes an escape back as its raw byte: `encodeRoundTrip`,
    `Utf8.encode`, and the standard handles and locale, which Sol now sets to
    GHC's `UTF-8//ROUNDTRIP`.
- **One spelling per text.** Building a string decodes escapes that together form
  valid UTF-8, so two halves of a character joined back are that character: they
  compare, sort and hash like text written directly.
- **`chr`** makes one byte and refuses values outside 0..255, as native.
- **`Str.codes`** answers bytes, as native's does today.

`sol/lib/json.sol` built `\uXXXX` escapes with `Str.fromCode`, which now makes
one byte. It encodes the code point as UTF-8 itself (`utf8Of`). Raw UTF-8 in JSON
text needed no change: it is read byte by byte and joins back into its
characters.

`tests/sol-checks/sol-surface.sol` covers JSON `\u` escapes and surrogate pairs,
byte lengths, and rejoined halves comparing equal.

## Still open

These are open in the semantics page and the same on both sides:
- strings are not yet checked to be valid UTF-8 when built;
- what `chr` becomes;
- whether a slice inside a character is refused, trapped or answered as `Option`;
- `String.codes`/`fromCodes` answering code points.

Sol now follows native's present behaviour, so when those are decided both
change together.

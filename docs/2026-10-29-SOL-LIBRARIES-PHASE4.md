# Sol Phase 4: practical libraries

Kind: API, implementation and local delivery record. Based on the uncommitted
tree after `27a4cdc`. **Phase 4 is delivered and locally verified on macOS
arm64.** The [HTTP contract](2026-10-29-SOL-HTTP.md) completes this phase; Phase 5
installation and cross-host release gates remain open. This is not a claim of
native-module parity or completion of the daily-scripting release.

## Bytes, encodings and SHA-256

Preprovided hosted APIs:

```sol
Hex.encode : Bytes -> String.
Hex.decode : String -> Result Bytes String.
Base64.encode : Bytes -> String.
Base64.decode : String -> Result Bytes String.
Sha256.init : Unit -> Sha256.
Sha256.update : Bytes -> Sha256 -> Result Sha256 String.
Sha256.finish : Sha256 -> Bytes.
Sha256.bytes : Bytes -> Bytes.
Sha256.stream : ByteReader -> (Result Bytes String, ByteReader).
```

Hex emits lower-case ASCII and accepts upper/lower-case input, with an even
digit count. Base64 uses the standard RFC 4648 alphabet and canonical padding;
decoding rejects whitespace, URL alphabet, misplaced padding and nonzero unused
pad bits. Empty input is valid for both. The returned encodings are materialized
Strings proportional to their input; encode bounded chunks for large output.

Sha256 is linear and opaque: its public token constructor cannot forge a host
context. Init/update/finish/bytes operate on immutable bytes and have no external
effect. Each update copies a fixed-size private context rather than mutating an
old VM value. At most 63 pending bytes survive a block boundary. The host uses
the portable uint32 schedule/rounds corresponding to `std/digest.fpr`, without
an external executable or platform crypto library. The maximum input length is
2^61-1 whole bytes (the SHA-256 64-bit bit-length bound). This API is SHA-256,
without a promise of HMAC, password hashing, or the other native digest APIs.

Sha256.stream hashes the reader's remaining bytes, including any read-ahead.
It returns the same reader for explicit close on success/failure. This is an
immediate scan with the guarded retry/ordering contract. `sol/lib/digest.sol`
adds `sha256File path` and `sha256FileWith chunk path`, returning 64 hex digits
and closing the reader. `sol/scripts/checksum.sol` is the runnable file example.
The native `std/digest.fpr`/`std/encoding.fpr` modules remain catalogued separately.

`tools/sol-digest-check.py` has 132 checks against hashlib/base64: known
empty/abc/million-a fixtures, all octets, SHA padding/block boundaries, split
updates, UTF-8/binary data, malformed/noncanonical encodings, ownership and
missing-file/invalid-buffer cases. It passes with default JIT and interpreter.

## Bounded JSON and CSV

The public JSON entrypoint remains `sol/lib/json.sol`. `parse` now uses bounded
defaults, and `parseWith (Limits inputBytes depth items fieldBytes) text` configures
admission. Defaults are 16 MiB source UTF-8, depth 128, 100,000 items per container
and 1 MiB per decoded string (keys and values). Maximum configurable depth is 256,
items 1,000,000, and byte budgets 16 MiB. Input, item and field budgets may be zero;
depth must be positive. A root scalar has container depth zero; root array/object
depth is one. Duplicate object members each count toward the item budget.

The host scans admission before the existing Sol parser constructs a tree.
Escaped quotes/braces do not affect depth; `\u` escapes and surrogate pairs count
their decoded UTF-8 size. Input is already a String supplied by the caller: this
is a bound on parsing/admission, not a bounded replacement for the legacy
whole-file transactional text reader. Whole-document parsing materializes a
tree. Integers retain hosted arbitrary precision; decimal/exponent Numeric is
binary64 and can round. Nonfinite values are rejected. Duplicate keys retain
order and `get` returns the first. Unicode scalars and JSON's four whitespace
characters are supported; raw controls and isolated surrogates fail.

`parseLineWith limits bytes` strictly decodes one line and uses the same parser;
LF/CRLF framing bytes count toward the input budget. Blank lines, BOM prefixes,
multiple values per line and malformed records fail. General incremental JSON
is outside this milestone. Use Stream.foldLines with a bounded accumulator for
JSON Lines. A callback that saves every parsed record deliberately retains them.

The public CSV entrypoint remains `sol/lib/csv.sol`; one hosted parser supplies
both whole-document and streaming semantics. `parseWith (Limits inputBytes
records fields fieldBytes recordBytes) text` defaults to 16 MiB whole input,
1,000,000 records, 1024 fields/record and 1 MiB decoded field/source record.
Maximum fields are 65,536, records 1,000,000 and byte budgets 16 MiB. Record bytes
include quotes, delimiters and CR/LF; decoded field bytes count UTF-8 after
unquoting. Input/record-count/field-count/field-byte budgets may be zero; the
per-record byte budget must be positive. Whole parsing returns a materialized
list; rendering and duplicate-header/ragged-row checks remain pure Sol helpers.

```sol
Stream.readCsv : Int -> Int -> Int -> ByteReader ->
                 (Result CsvRead String, ByteReader).
Stream.foldCsv : (a -> List String -> a) -> a -> Int -> Int -> Int ->
                 ByteReader -> (Result a String, ByteReader).
CsvRead = Type (EndCsv | CsvRow (List String)).
```

The three stream budgets are fields, decoded bytes/field and source bytes/record.
Each call handles one CSV record, including quoted newlines; it retains reader
read-ahead and returns the owner even on error. Empty input is EndCsv; a blank
line is one empty field. Commas, doubled quotes, CRLF/LF framing, quoted CR/LF,
empty fields, Unicode and NUL fields are preserved. Bare CR outside quotes,
quotes in unquoted fields and text after a closing quote fail. On a read/parse
error, close the returned owner; no cursor rewind/resynchronization is promised.

The host owns fold iteration, so callbacks do not accumulate VM frames. Short
physical lines use copied slices and retain one bounded input chunk, rather than
allocating the maximum line buffer or copying all remaining read-ahead for each
record. Multi-chunk lines and multiline records use one admitted mutable buffer
each, avoiding an unbounded list of tiny fragments. Memory is bounded by selected
chunk/line/record budgets plus the callback's chosen state and decoded record.
Changing a reader's chunk size preserves earlier read-ahead until consumed.

`sol/scripts/text/csv-to-jsonlines.sol` emits JSON arrays; the JSON Lines selector
`sol/scripts/text/jsonlines-select.sol` selects objects by a string field. Both
use private attempt scratch, close the output after full validation, then use
bounded same-directory publication at the destination. Invalid syntax/schema or
a configured limit aborts before publication; an existing target remains intact.
`--replace` explicitly permits replacement with mode preservation. These are
immediate streaming workflows, with the Phase 3 retry and foreign-writer limits.

`tools/sol-format-check.py` has 94 independent checks, including 300 seeded CSV
records produced by Python's CSV writer, UTF-8/chunk boundaries, CR/LF/quotes,
exact limit boundaries, deep nesting refusal, duplicate keys/numeric behavior,
EOF/blank records and failed transform publication. The old library suite also
retains its format fixtures and supported/unsupported distinction.

## CLI and configuration

`sol/lib/cli.sol` parses raw argv using an explicit option schema:

```sol
options = [CLI.Option "verbose" "v" CLI.Switch,
           CLI.Option "output" "o" CLI.One,
           CLI.Option "include" "I" CLI.Many].
parsed = unwrap (CLI.parse options (args Unit)).
```

`--output=value`, `--output value`, `-o value`, boolean switches and repeated
Many values are supported. The next raw token is a required option's value,
including empty/negative/dash-leading values. `--` encountered as an option
terminates parsing and preserves all following operands. There is no shell
splitting, option abbreviation or short-option bundling. Duplicate One/Switch
options, unknown/missing options and invalid/duplicate schema names/aliases
return useful errors. `values`, `valueOr`, `flag` and `operands` inspect Parsed;
option entries are sorted by name, repeated values/operands preserve input order.
The implementation reuses std/map, and recursive traversals carry checked
structural termination measures rather than extending the safety allow-list.

`sol/lib/config.sol` reads JSON transactionally (`readWith` selects JSON limits),
checks allowed/duplicate keys with `schema`, and reads strict `string`, `integer`
or `integerBetween` fields. Callers explicitly name each environment override;
an empty environment name disables overrides. A present empty value differs from
absence. An invalid override fails rather than silently falling back. There is
no implicit environment-to-key mapping. Errors identify file/key and expectation.
The file is a whole transactional snapshot; parse limits apply after that read.
Environment reads are immediate observations, not validated transaction inputs.

The runnable `sol/scripts/config-update.sol` demonstrates schema errors,
**CLI > named environment > JSON** precedence, numeric bounds and a buffered
transactional update. Forced retries rebuild the update, ordinary panic discards
it, and interrupted commit recovery applies the saved post-image with mode
preservation. No external command or direct stream is needed for this workflow.
`tools/sol-cli-config-check.py` has 33 checks covering these contracts, including huge integers,
empty overrides and recovery triggered by another script touching the same path.

## Measurements and verification

The saved [stream report](evidence/2026-10-29-sol-phase4/stream-memory.json)
records source/executable hashes, build settings, command/source text, raw time
output, independent digest checks and fresh-process wall/RSS samples at 100 MiB
and 1 GiB. It uses fixed 64 KiB buffers, interpreter/GPU off, one warm-up and two
recorded runs, and separates the idle baseline. Cases measure SHA-256, CSV record
validation/counting and byte line filtering; CSV figures do not measure JSON
rendering or publication. The earlier digest-only report records the initial
digest implementation snapshot before format additions, rather than claiming
its binary hashes describe the later tree. These are local macOS arm64 checks.

The 1 GiB runs recorded SHA-256 at about 2.44 seconds / 165 MiB RSS,
CSV validation/counting at 12.76-12.79 seconds / 95 MiB RSS, and line filtering at
0.574-0.576 seconds / 165 MiB RSS. Peak-memory growth from 100 MiB to 1 GiB was
0, 5 and 1 MiB respectively; all three 32 MiB growth gates passed. Focused tests
ran concurrently with the first small-input samples; treat wall times as local
observations rather than controlled cross-version speedup claims.

[Core command results](evidence/2026-10-29-sol-phase4/validation-core.json) for
this delivery slice are saved beside that report. All 18 recorded commands
passed, including ten registered Sol Base jobs and interpreter reruns. Library
import-and-call coverage is 123 checks; digest 132, formats 94 and CLI/config 33.
HTTP now uses linked libcurl >=8.4 in an isolated owned worker, with bounded
capture and streamed file publication. Its 61 loopback checks cover TLS/hostname
validation, status/headers/trailers, redirects, deadlines, exact and chunked byte
limits, binary upload/download, cancellation, descriptor reuse, replay and JSON
transforms. No curl executable or public service is used. See the
[HTTP API and evidence](2026-10-29-SOL-HTTP.md).

The [completed macOS validation](evidence/2026-10-29-sol-phase4/validation-complete-macos.json)
records 19 passing commands, including eleven registered Sol Base jobs, default
and interpreter-mode HTTP, all earlier Sol regression suites, and 125 library
checks. A subsequent route-helper correction and its default/interpreter checks
are recorded in the [focused follow-up](evidence/2026-10-29-sol-phase4/validation-http-followup.json).
The source and executable identities distinguish these snapshots.

The [HTTP memory report](evidence/2026-10-29-sol-phase4/http-memory.json) measures
100 MiB and 1 GiB streamed downloads with independent byte digests and sampled
parent/worker memory. Its 32 MiB growth gate passes. These are local macOS
observations, not controlled cross-version speedups or Linux/hosted-CI evidence.
Linux x86-64 is building separately for Phase 5; the full installation and daily
workflow release matrix remains open.


## Later Phase 5 verification (2026-10-29)

The [installation and release record](2026-10-29-SOL-INSTALLATION.md) supersedes
this delivery snapshot's open Linux/installation gate. Its complete daily-workflow
matrix passes on macOS arm64 and an emulated Linux x86-64 Debian trixie guest,
with exact source/executable identities and explicit remaining exclusions.
The older measurements above retain their original executable identity and scope.

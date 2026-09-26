# Scripting with Sol

Sol scripts are HostedBytecode programs: ordinary FP-RISC inference and
functional composition, with the whole script evaluated as one transaction.
This makes them a good fit for replacing scripts whose job is to transform
values, update files, inspect the host, and coordinate external tools.

Run a script with trailing arguments after its path:

```console
./fpr sol sol/scripts/version-compare.sol 2.10 2.9
```

`args Unit` returns those trailing arguments as a `List String`. The shell has
already split the command line, so Sol receives each argument as one value;
scripts should pass external arguments onward as lists rather than rebuilding
a shell command string.

## Choose the narrowest effect

Keep calculation total and pure whenever possible. Parse into `Result`, use
`|>?` and `mapOk` to compose fallible work, and keep the final command boundary
small. `version-compare.sol` is the reference shape: all comparison logic is
pure, and only the entry point prints or reports an error.

Use transactional filesystem operations for file transforms. Reads form a
snapshot and writes are buffered until commit. A conflict reruns the complete
script, so replacing a destination is preferable to an untracked append.
`lowercase.sol` demonstrates this shape.

Use `Proc.query` for read-only host observations. A query may run again if the
transaction retries, so it must not mutate the host. Its structured result can
feed a later transactional write, as in `system-report.sol`.

Use `Proc.afterCommit` for a repeatable external mutation. It queues a
structured process specification and cannot run in an abandoned transaction
attempt. Deferred commands run in order after the filesystem commit and are
recoverable from the redo journal. Recovery gives at-least-once execution, so
the command must tolerate repetition. `archive.sol` uses `tar -czf`, whose
rerun replaces the named archive.

Use `Proc.runNow` only when the effect is genuinely realtime and cannot wait
for commit. It deliberately leaves the rollback model; keep it visible at the
top-level boundary rather than hiding it in a helper.

## Current utility suite

| Script | Shape | Purpose |
| --- | --- | --- |
| `version-compare.sol` | pure | Compare numeric dotted versions |
| `lowercase.sol` | transactional file transform | Lowercase UTF-8 text |
| `system-report.sol` | queries plus optional transaction | Collect a host report |
| `archive.sol` | deferred process | Create a gzip tar archive |

These are semantic replacements, not line-for-line shell translations. There
are no pipelines, word splitting, glob interpolation, or `eval`. External
programs receive explicit argument vectors through `Proc.spec`.

## JSON and CSV

`lib/json.sol` and `lib/csv.sol` treat both formats as values, so a data
job is one railway pipeline: parse into a value, reshape it with pure
functions, render it back, and let the transaction land the files.

```sol
J = use "../lib/json".   C = use "../lib/csv".
JStr = J.JStr.  JObj = J.JObj.                # constructors come in by alias

> doc = unwrap (J.parse (readPath "in.json"));
  city = J.path ["address", "city"] doc |>? J.text;         # Result String
  out = doc |> J.set "tier" (JStr "gold") |> J.without "tags";
  writePath "out.json" (J.pretty out).

> recs = C.records (unwrap (C.parse (readPath "orders.csv")));   # (column, value) rows
  good = List.filter (fn r -> isOk (C.col "amount" r |>? Try.parseNum)) recs;
  writePath "clean.csv" (C.render (C.table ["order", "amount"] good)).
```

`J.parse` / `C.parse` return `Result`; `J.get`, `J.at`, `J.path`, `J.num`,
`J.text`, `J.bool`, `J.items`, `J.fields` and `C.col` are railway steps, so a
missing key or a non-number derails the chain with a named `Err` instead of
a panic.  Numbers ride the Numeric surface via `Try.parseNum` (integers stay
exact, decimals are inexact).  Object keys keep document order, so
`parse |> render` is the identity up to whitespace; `C.parse |> C.render`
is the identity including quoted commas, newlines and doubled quotes.
Inside a Sol string literal `{` and `}` are interpolation, so inline JSON
text is written with `\{` and `\}`.  `J.ofRecord` lifts a CSV record into
a JSON object, which is the whole CSV-to-JSON bridge.

`sol/examples/jsoncsv.sol` is the executable spec for both libraries.

## Interactive input

`sol/examples/interactive_script.sol` is a line-oriented calculator built with
`readLineNow`. Run it from `fp-risc/`:

```console
./fpr sol sol/examples/interactive_script.sol
```

It repeatedly asks for an expression, evaluates `+`, `-`, `*`, `/`, unary
signs, decimals, and parentheses with standard precedence, and keeps parse
errors in the loop. Enter `quit`, `exit`, a blank line, or EOF to leave.

The implementation is a railway from tokenization through a two-stack
evaluator: fallible stages return `Result`, and `|>?` stops at the first error.
The lexer measures its remaining character span, stack reductions measure the
remaining operator list, token evaluation measures its remaining token list,
and the interactive loop has an explicit turn budget. No parser recursion is
marked `unsafe`.

This is an arithmetic parser/evaluator written in Sol, not an `eval` of
arbitrary Sol source. `readLineNow` is a realtime escape because a prompt must
observe each new line as it arrives; the runtime reports that loss of
whole-script atomicity explicitly.

## Boundaries

- Host commands are capabilities of the machine running Sol. Check and report
  failures instead of assuming every Unix tool exists.
- A `Proc.query` observation is not part of the filesystem conflict set. A
  retry takes a fresh observation, but the external world can change later.
- `Proc.afterCommit` does not roll back an external command that partially
  succeeds. Prefer replacement-style or otherwise idempotent operations.
- Do not put passwords, tokens, or encryption passphrases in script arguments
  or `ProcessSpec`: process arguments and deferred journals are not secret
  stores. Secret input needs a dedicated non-serialized runtime capability.
- Interactive loops and live terminal interfaces are realtime applications,
  not whole-script transactions. Use `readLineNow` at that explicit boundary;
  keep state transformation and parsing pure inside the loop.

Run the utility integration checks with:

```console
sh tools/sol-scripts-check.sh
```

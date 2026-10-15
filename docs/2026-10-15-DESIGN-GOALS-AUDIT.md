# Design goals: where FP-RISC stands (2026-10-15)

Kind: assessment. Checked against main at `dab03e3` by reading
`examples/pos1.fpr` (960 lines), `examples/inventory.fpr` (1,101) and
`examples/logbook.fpr` (347), counting the constructs each goal implies, and
compiling each app with its blanket `unsafe base.` replaced by `profile base.`.
These are counts and spot reading, not a line-by-line review; logbook is the
app closest to the original design and the best reference.

## The goals

1. A concise, pure FP-RISC programming framework.
2. `Persistent a` for persistent fields.
3. Append-only key-value stores for everything.
4. Client type annotations for fields kept on the client, with sync messages
   now and then as an idiom.
5. MVU and LiveView-style dataflow with nothing inelegant left to the user:
   all of it abstracted by the implementation.
6. Strong types and safety guarantees used as much as possible, refinement
   types included.

## What held

**Dataflow is abstracted (goal 5).** No app touches actors, mailboxes or
memory. A button is `G.send codec Msg`; sessions, per-session projection and
rendering are the framework's. The `keep`/`drop` that a text search finds in
inventory are list functions and variable names, not runtime plumbing.

**Client state and the sync idiom exist (goal 4).** pos1 declares its
page-local state as a type, `Client = { tab : String, open : String, ... }`,
and `Live.SyncClientState 500 (ClientState "")` mirrors it to the server every
half second when it changed and just before any other message, so a checkout
sees the cart the cashier saw while the server still decides. Weakness: every
client field is a `String`, and the mirror arrives as a JSON `String` message.

**Storage is append-only (goal 3).** `std/kvlog` and `std/store` only append;
pos1 and inventory are event-sourced (one line per change, folded at start).

**The type system has grown real guarantees (goal 6, in the compiler).**
Termination measures, contracts, bounds in signatures, clause coverage, Int
overflow traps (2026-10-13), the safe/unsafe line.

## What drifted

### The guarantees are switched off where they matter (goal 6)

All three apps open with `unsafe base.`: every check of the safe/unsafe line
is off for the whole program. Compiling them with `profile base.` instead:

| App | refused functions | of them in std | in the app's own code |
|---|---|---|---|
| logbook | 17 | 16 | 1 (`load`) |
| inventory | 51 | 44 | 7 (`numGo`, `sbGo`, `wdGo`, `stretch`, `sGet`, `sDel`, ...) |
| pos1 | 65 | 45 | 20 (`noteKind`, `numGo`, `sbGo`, `seGo`, `takeN`, `wdGo`, ...) |

Most refusals are in std, because **36 std modules are not on the safety
allow-list** in `compiler/Safety.hs` (the list of library modules whose
public functions may sit over `unsafe` helpers):

appearance, browserautocomplete, browsercalc, browserconsole,
browserfeedback, browserformfill, browsermedia, browserstorage, checkdemo,
clientcalc, connect, crypto, gitrevision, httpclient, javascript,
livemetrics, livenotice, livereload, mjpeg, money, mqtt, mqttclient,
mqttsession, native, osconnection, printertelemetry, readiness, reload,
reloadcatalog, resolver, sessionauth, sockettransport, tls, transport,
watch, watchedtransport.

std grew faster than its trust boundary; these were never reviewed as library
code. The apps' own refusals are few and mostly small recursive helpers that
could be folds or carry a measure. Refinements in the apps: 0-3 per app.

### Persistence is hand-written, three ways (goals 2 and 3)

There is no `Persistent a`. There are three mechanisms instead of one:

- **logbook**: the declarative form, `Live.field Live.Always @Model.count`, a
  list of durable field paths kept beside the model (`std/live`, over
  `std/kvlog`). The closest thing to the goal.
- **pos1 and inventory**: neither that nor `kvlog`/`store`. Each has its own
  event log on `std/logfile`: reading the file, cutting a torn tail, folding
  the lines, seeding an empty shop, and the open file handle kept **inside the
  model** (`sink = LF.sink ...`) -- the infrastructure the framework was meant
  to absorb, about a hundred lines in each.
- **`std/store`**: shard logs, used by tests and the service example.

### Views are not concise (goal 1)

pos1 has 99 lines carrying an inline style list
(`G.Utilities [G.Base [G.Cursor ..., ...]]`); one 13-property list appears 10
times. Elements also carry both the style values and an equivalent class
string (`Cls "btn pill px-3 py-2"`), which looks like a leftover of moving
off CSS text (`a136c91`). The update logic, by contrast, reads well: records,
clauses, folds.

## What would bring it back

1. **Close the safety gap.** Review the 36 std modules and put them on the
   allow-list (or fix what keeps them off it); fix the apps' own refused
   functions (1, 7, 20); then drop `unsafe base.` from all three apps, so the
   guarantees apply to the programs people run. Keep a check that a new std
   module cannot ship off the list.
2. **Make persistence declarative again.** Either a `Persistent a` field type
   or the existing `Live.field` descriptors applied to an event journal --
   append an event, fold on start, cut a torn tail, seed when empty -- backed
   by `std/kvlog`/`std/wire`. Move pos1 and inventory onto it: no file handle
   in a model, one mechanism.
3. **Type the client state.** Client fields of their own types (`Int`,
   `Bool`, records) through the generated codecs, instead of Strings and a
   JSON-string mirror message.
4. **Name shared styles** and drop the duplicate class strings; pos1's views
   would shrink by a large fraction.

Items 1 and 2 are the substantive ones: they are what the design promised
(checked programs, persistence as a declaration) and what the largest apps do
without today.

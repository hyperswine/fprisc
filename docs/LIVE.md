# Can FP-RISC host a real application? The FPRLive goal, measured

Kind: an assessment with evidence, 20 September 2026. The goal it measures against
is the application-language target: a GUI app (web first) in the FPRLive style --
an actor per connection, the static/dynamic split, per-field `Persistent a`, the
Ma primitives, client-side state, Elm's commands and subscriptions, state
replayable from an append-only store, reload at run time.

**Short answer.** For the WEB case, yes on both systems, at the scale of an
internal tool: hundreds of sessions, not tens of thousands. The shape holds and
every item on the list now runs on a plain posix process (`fpr run`) as well as on
QOS (a session is about half a megabyte and costs no CPU while idle). What is not
there yet is TLS. TUI and desktop apps exist only
on QOS Portable, because the terminal and GL tiers live in its host.

What was built to find out: `std/ws`, `std/kvlog`, `std/live`, `std/actor`'s
frame boundary, SHA-1 in `std/digest`, `Os.exec`; and the app
`qos/programs/liveboard.fpr`, driven by `qos/qos/tests-host/liveboard-check.py`
and `liveboard-reload.py` as real websocket clients.

## The list, item by item

| goal | state | evidence / where |
|---|---|---|
| **An actor per connection** | WORKS. A session is TWO actors on one socket: a reader (frames to events) and a writer (renders `view sid model` itself, holds what the tab last saw, is the only one that writes). One register owns the model | `std/live.fpr`; 1,000 sessions join in 3.3 s, one event reaches all 1,000 in 260 ms |
| **Static / dynamic split** | WORKS, unchanged from QOS. `genview` renders a tree to (statics, dynamics); a counter change is an 18-byte delta on a 7-static page; a reshape is a full render | `qos/programs/mods/genview.fpr` is pure FP-RISC and runs on posix as is |
| **Ma: stacks, spacers, everything from primitives** | WORKS, unchanged. `vstack hstack zstack spacer card` ... over `El / Txt / Dyn`; the stylesheet is a function of the tree | `qos/programs/mods/ma.fpr`; `maapp.fpr` runs under `fpr run` untouched |
| **`Persistent a`, per field, with options** | WORKS, named by a PATH: `Live.field Live.Always @Model.count`. The literal is checked against the model's declaration and gives the getter, the setter, the key AND the codec (any field built from Int, String, Bool, lists, tuples, declared records and sum types; the demo's notes are a durable list of records with no encoder written), so a field that does not exist is a compile error. Policies: `Always`, `AtMostEvery ms`. It is a list beside the model, not a wrapper type inside it | `Live.field`, `Live.custom`; restart brings back `count` and `notes` and, on purpose, not the clock |
| **Client-side state (`ClientState a`)** | WORKS, typed. `Client = {tab : String, draft : String}.` is a record; `View.locals @Client {tab = "1", draft = ""}` declares it, `View.showIf @Client.tab "2"`, `View.setTo`, `View.bind @Client.draft` use it, and a field that does not exist is a compile error. It never round-trips unless a message carries it (`View.sendWith codec (Add "") @Client.draft`) | `std/view.fpr` + the 150-line client script; checked in a real browser |
| **Typed messages** | WORKS. `Msg = Type (Bump Int \| Add String \| ...)` and `codec = @Msg`: the compiler mints the codec from the declaration (as it mints a path from a record's). The view sends VALUES (`View.send codec (Bump 10)`), `update` matches on them, the journal stores them. An unknown message, a field that is not a number, a missing field: refused by name before `update` sees it, as `Live.Refused sid why` | `compiler/FPRISC.hs codecFor`; `tests/std/codec.fpr`; the check's forged-message leg |
| **Elm's Cmd and Sub** | WORKS, typed. `update` answers `Live.After ms msg`, `Live.Run work` (runs in its own actor; the MESSAGE it returns comes back through `update`), `Live.http request toMsg`, `Live.Navigate sid url`, `Live.Emit sid name detail` (a port to the page's own JavaScript: a `live:<name>` CustomEvent), `Live.Quit`; a file picker is `View.uploadWith codec (Uploaded "")`; `subs` answers `Live.Every ms msg`, re-read after every update, so a clock exists only while the model asks for it | the check's clock and digest legs |
| **Replayable from an append-only store** | WORKS. Every durable write is an appended line; with `journal` every EVENT is too, and `Live.replay` rebuilds the model from `init`, `update` and the log alone. The check rebuilds 1,950 events and gets the saved state | `std/kvlog.fpr`: `history`, `at time`, torn-tail tolerant |
| **Reload** | WORKS, differently on each system. posix: the server sees a source change, rebuilds, and only if that succeeds saves its fields and BECOMES the new program; browsers reconnect; 4 s, nearly all of it the compile. A rebuild that fails is printed and the old program keeps serving. QOS: a module is replaced IN PLACE through the plugin loader (`tests/livereload.fpr`), and nothing restarts | `liveboard-reload.py`, 8 of 8 |

## What it costs

| sessions | join all | one event to all | resident | per session |
|---:|---:|---:|---:|---:|
| 100 | 0.08 s | 12 ms | 50 MiB | 0.5 MiB |
| 1,000 | 1.0 s | 50-110 ms | 550 MiB | 0.55 MiB |

Flat while idle (and 4% of one core: one poller, below), and it comes back when
sessions leave. On Linux arm64: 500 sessions join in 0.6 s, an event reaches
them in 54 ms. QOS's FPRLive measured 263-600 KiB a session with one actor each;
this is two actors a session, and an actor's floor is the allocator's 64 KiB unit
(a 128 KiB stack block, a pool slab, a message slab, a mailbox block).

The first measurement said 1.2 MiB a session at 100 and 3.5 MiB at 1,000, and
most of that was four separate mistakes, each fixed:

- **A leak in my own stream layer, and the big one.** Waiting for a quiet socket
  polled `Os.read`, which allocated its 64 KiB String BEFORE finding there was
  nothing to read, in a loop that never reached a tidy point: 600 idle sessions
  made gigabytes of garbage a second (heap in use went 4.5 -> 45 GiB in four idle
  seconds, then the server stopped). `Os.ready` answers a static Bool, so waiting
  allocates nothing, and `Os.read` makes a String of exactly what arrived.
- The register pushed the whole model to every session on every event, so a join
  burst queued n * n copies. It broadcasts a VERSION now and a writer pulls the
  model when it is ready (a busy session skips to the newest): 3-4x faster.
- In the runtime: every actor that allocated anything took a 256 KiB slab at
  once. A pool's slabs start at one block and double: 1,000 small actors went
  from 508 MiB of arena to 196.
- In the runtime: an actor's first stack was a 512 KiB block. It is one 128 KiB
  block now that stacks grow.

Idle sessions cost almost no CPU either. Each session's reader used to poll its
own socket (every 10 ms when idle), and 1,000 idle sessions kept about half a
core busy. Now ONE actor polls every socket with one `poll(2)` (`std/poller.fpr`,
over `Os.poll` and the runtime's new `receiveNow`), the readers and the acceptor
sleep in their mailboxes, and 1,000 idle sessions use 4% of one core; an event
after the idle period still reaches all of them in about a third of a second.

## What writing it exposed

These matter more than the missing features, because they are what an application
author would hit.

1. **Memory is manual where it looks automatic.** Three bugs in this work were
   the same one: a store kept part of a request that `serve` then dropped (a
   crash on the second request); replies to `ask` that were never dropped pinned
   the sender's slab; and a long-lived loop keeps every temporary it ever made
   until it takes a frame boundary. `std/actor.fpr` now has `boundary` and an
   amortized `tidy`, and the driver uses them everywhere, so an APP never sees
   this. A library author still must know `keep`, `drop` and the boundary. The
   compiler's autodrop covers a reply bound to a name, not one matched inline.
2. **Order between senders is not order.** A writer was welcomed by its reader
   while the register was already broadcasting to it; the broadcast could arrive
   first and the writer quietly ended. One sender's messages arrive in order;
   two senders' do not. Nothing in the types says so.
3. **`send` never waits.** A fixed mailbox that is full REFUSES, and an `ask`
   whose request was refused waits forever. Anything many actors send to must be
   spawned `Dynamic`. This is documented (`docs/MAILBOX.md`) and still bit.
4. **A mailbox has one type.** A writer hears the register's answers and its
   broadcasts, so they had to become one type. Fine, but it is a design
   constraint worth knowing before designing a protocol.
5. **TWO RUNTIME BUGS, both older than this work and both found by load.**
   (a) A sleeping actor woken early by a message stayed on its hart's sleeper
   list, and its next sleep linked it again; as the head it then pointed at
   itself and the hart walked that one-node cycle forever, running nothing. The
   poller (sleep while requests arrive) did it within a few hundred connections;
   `tests/base/sleepwake.fpr` hangs the old runtime two runs in three.
   (b) On aarch64 the context switch does not save `x28` (QOS apps keep the hart
   pointer there and compile with `-ffixed-x28`), but POSIX builds did not
   reserve it: the C compiler kept a global's address in `x28` across a spawn
   that waited on the memory actor, and got another actor's value back -- a
   SIGSEGV one burst of 500 connections in twenty, and nowhere else. `fpr build`
   and the Makefile's posix target reserve it now, and the runtime object cache
   is keyed by flags.
6. **`exec` from a hart thread** inherits that thread's signal mask and the
   ignored SIGPIPE; `Os.exec` and `Os.run` reset both.
7. **Waiting must not allocate.** The worst bug of all was mine: a wait loop that
   allocated on every poll and never reached a tidy point (see the costs above).
   Any loop that can spin for a day has to be allocation-free or take boundaries.
8. **A constructor named like a module alias** (`Digest`, with
   `Digest = use "std/digest"`) is resolved as the module, and the type error
   that follows points somewhere else entirely.

## A second app: the logbook (2026-09-22)

`examples/logbook.fpr` is the first Live app written *as an application* rather
than as a demo of the driver: a digital log -- add an observation, edit it,
delete it, tag it, search by text or tag, page through it newest first. It is
what the patterns look like when a real app needs them, and it is in
`tests/check_std.py` (`tests/std/logbook_ws.py` drives it over the websocket
exactly as a browser does, then kills it, replays it, restarts it).

Three things it needed that the driver did not give it directly:

- **Per-session state.** The model is shared, but a search, a page number and
  "the entry I am editing" belong to one tab. The pattern: a `sessions : List
  Sess` field keyed by sid, added on `Joined`, removed on `Left`, read by `view
  sid m`. It is state like any other -- journaled, replayed -- just never
  durable.
- **Filling an input from the server.** Client state only flows *up* (a
  `data-arg`), so an edit form could not be pre-filled. The app adds one port:
  `Live.Emit sid "set" json` and a dozen lines of page script that put values
  into inputs by name. The event can arrive before the render that creates the
  input, so the script keeps a value pending until its input exists.
- **Local time.** `Os.tzOffset` (new, `machine/posix/os.c`, now `os_clock.c`) and
  `Clock.local`/`Clock.stamp`: entries are stored as UTC seconds and shown on
  the local clock.

And two bugs in the view layer that every Ma app had, found because this one
looked wrong on a phone:

- `Ma.card` emitted **two `class` attributes** on one element (`vsA`'s layout
  class and the caller's), and a browser keeps the first -- so no card had its
  surface, border or shadow. `View.attrsOf` now merges every `Cls` into one
  attribute, as it already did for locals.
- Ma's CSS is emitted in the order the tree first uses each class, so
  `.btn` could land after `.btn-primary` and win; primary buttons came out
  plain. The modifiers are compound selectors now (`.btn.btn-primary`).

### What it cost, and what changed (2026-09-22, evening)

Measured with the same app on plain `Live.serve` and on the per-session view
cache, at 30 / 1,000 / 10,000 entries: the cache made no difference past 30,
because rendering was never the expensive part. What grew with the log was
`persist`: after EVERY event -- a page turn, a search, a tab joining -- it
encoded each durable field to JSON and rendered it to text only to compare it
with the last save. At 10,000 entries that was 41-52 ms per event, the floor
under every action. Two changes in `std/live`:

- **A field is looked at only when it changed.** Each field keeps a snapshot of
  its own raw value (inside two closures, so the register holds one per field
  whatever its type) and asks `==` first; the runtime answers "same object" at
  once, so an event that left a field alone costs nothing. A change inside an
  `AtMostEvery` window no longer waits for the next event, either: the register
  sends itself a `SaveDue` for the end of the window. (Before, the last change
  of a burst was written only by a later, unrelated event or a clean Quit, and
  lost on a kill.)
- **`Live.each`: a list kept one record per element.** `entries` is stored as
  `model.entries/<id>` records with the marker `"each"` under `model.entries`;
  a change writes only the elements that changed, found by walking old and new
  with identity checks (a prepended entry is one record, an edit or a delete
  one pass and one record). A store holding the field as one record is read as
  it is and rewritten per element at start.

At 10,000 entries, one tab: edit 42 -> 7.6 ms, page 43 -> 5.7, add 92 -> 17,
search 58 -> 30 (now the filter's own cost), server CPU per action 63 -> 17.5
ms; one add reaching 50 tabs 205 -> 90 ms; memory with 51 tabs 714 -> 496 MB.
The price is startup: restoring 10,000 records is 195 ms (was 82), one store
lookup per record -- a prefix read in `std/kvlog` would remove it.

## Found (2026-09-23): the "not the current actor's handle" failures

The failures recorded below as unexplained were the hart pointer going wrong
after an actor MIGRATED between hart threads. Two causes, one after the other:

1. **A thread-local cannot follow a green thread.** Hosted builds kept the hart
   in a `__thread` cell. The compiler may compute a thread-local's address once
   per function (on Darwin, a call to `_tlv_get_addr` it is entitled to reuse),
   so a scheduler function that switched away and resumed on another thread
   went on reading the OLD hart: it saved itself into that hart's `current`
   (NULL: a fault inside `fpr_ctx_switch` at address 0x8) or ran on that hart's
   scheduler stack. Hosted AArch64 now keeps the hart in x28 -- as QOS apps
   always have -- read through a volatile asm (`runtime/fpr.h`), and generated
   code reads x28 too (`Compile.hs` applies `deTlsQosAppA64` to posix).
2. **The compiler saved x28 anyway.** AArch64 saves callee-saved registers in
   pairs, and Apple clang saves the (x27, x28) pair in any function that uses
   x27, `-ffixed-x28` notwithstanding. `fpr_apply` -- around an actor's whole
   body -- saved x28 on hart 0's thread; the body migrated; the epilogue wrote
   hart 0 onto hart 1's thread. Found by checking x28 against a thread-local
   shadow at the scheduler's entry points: every switch-back was right, the
   return from the body was not. Every C file is now compiled `-ffixed-x27` as
   well (`compiler/Build.hs`, both Makefiles, `qos-app.mk`), and no function in
   a built binary saves x28 (checked with `objdump`).

Two guards stay in `runtime/actors.c`, one compare or CAS per switch: a context
may be live on one hart only (a second claimant is a named panic with the
actor's last scheduler transitions), and the hart register must still name the
loop's hart after every switch back. Measured: a fan-out burst that crashed in
3 of 3 runs within seconds ran 11,000 fan-outs clean; the 1,000-session check
passes 13 of 14 (the committed baseline, on two harts: 2 of 4, its two failures
connection resets from the test's own burst of 1,000 connects against a listen
backlog of 128). The one failure: a byte that is not UTF-8 in the store, once,
not reproduced in 8 further runs -- recorded, not explained.

The QOS app build has used x28 the same way all along, so the pingpong flake
below (a QOS app) is plausibly the second cause; qos-app.mk now reserves x27.

## (history) two rare failures under test

The full check (`liveboard-check.py`) fails about one run in twelve at 1,000
sessions and one in twenty at 100, in two ways, neither yet explained:

- the server PANICS with `receive: not the current actor's handle` (seen once in
  24 runs at 1,000 sessions): an actor's `receive` ran while its hart's
  `current` was some other actor. Nothing in std passes a foreign handle, so
  this looks like the scheduler, and the two bugs above say load finds those.
- an update never reaches a session (a 20 s timeout with the server alive), once
  with only two sessions connected. 3,000 events across two sessions in a
  dedicated stress ran clean, so it is not simply the notification logic.
- (2026-09-21, a third in the same area and NOT in std/live) `tests/pingpong.fpr`
  -- the cross-hart wake stress -- failed once inside a full `check-all.sh`
  sweep. It would not reproduce: 12 runs idle and 15 more at a load average of
  10 all passed, and the run takes 8.5 s against the leg's 60 s timeout, so
  neither contention nor the timeout accounts for it. Recorded because it is
  the same shape as the panic above: a cross-hart wake that did not arrive.

They are recorded here rather than hidden by retries in the test.

One thing that WAS hiding them has been fixed. The harness started the server
on pipes nobody drained while the check ran; a pipe is 64 KiB, so a server that
logged enough during a long run would block in `write()` and never answer
again -- indistinguishable from the hang above, and far more likely at 1,000
sessions than at 100. Server output now goes to a file. Whether that accounts
for any of the observed failures is not yet known: they were rare enough that
only a long run of clean 1,000-session checks would say.

The harness also used to leak. Its cleanup was a `finally`, which does not
survive the harness itself being killed -- by the sweep's `timeout`, or by
anyone giving up on a long run -- so every abandoned run left a server holding
a port. It now puts the server in its own process group, cleans up on
SIGTERM/SIGINT/SIGHUP and at exit, and sweeps a pidfile on startup for the one
case those cannot cover.

And it now runs in the sweep (`check-all.sh`), which it never did before.
Nothing else compiles `std/live`, `std/view`, `std/ma` or `std/livejs` at all,
which is how four wrongly-general signatures sat in `std/live` and `std/view`
until the generality check went in.

## What would make it the application language

Done since the first version of this page: durable fields and client state from
PATH literals (and nothing but the path); a typed `Msg` with a compiler-minted codec, for records, lists and
nested types too, so a durable field needs only its path; sessions at half a
megabyte; one poller for every socket; `http`, `Navigate`, `Emit`, upload and
`KvLog.compact`; a terminal driver (`std/term`); the view layer (`std/view`, `std/ma`, `std/livejs`) in std.

In the order I would do what is left:

1. **Recursive types on the wire.** Codecs are generated inline, so a recursive
   type (a tree, a comment thread) is refused; it needs generated top-level
   functions, one per type per unit.
2. **Desktop on posix**: a window and GL are QOS Portable's today. (A terminal app
   runs on posix: `std/term`.)
3. **Store maintenance**: fsync as a policy, and per-session state that does not
   live in the shared model. (`KvLog.compact` exists.)
4. **One App value for both drivers.** QOS's `fprlive.fpr` and `std/live` have the
   same shape and different surfaces (`EMsg sid name arg` there, `Msg sid msg`
   here); the QOS driver should take the typed one.

### Against Phoenix LiveView (2026-09-22)

The same logbook rewritten as a standard Phoenix LiveView app (Phoenix 1.8.14,
LiveView 1.2.12, Bandit, Ecto + SQLite, a stream for the entry list, PubSub +
Presence; 401 lines against the FP-RISC version's 193), driven by the same
workload through a Phoenix channels client. Medians in ms, one Apple M4,
FP-RISC / LiveView:

| | 30 entries | 1,000 | 10,000 |
| --- | --- | --- | --- |
| add | 5.9 / 2.2 | 6.2 / 1.8 | 16.2 / 2.1 |
| edit | 2.2 / 1.0 | 3.0 / 0.7 | 7.5 / 0.9 |
| page | 2.4 / 1.1 | 3.0 / 1.2 | 4.2 / 2.0 |
| search | 2.2 / 0.6 | 7.9 / 1.4 | 30.6 / 3.6 |
| one add reaching 50 tabs | 35 / 3.2 | 38 / 4.0 | 84 / 4.2 |
| first page load | 1.7 / 0.5 | 1.7 / 0.5 | 3.6 / 0.5 |
| memory, 51 tabs (MB) | 53 / 122 | 103 / 122 | 526 / 124 |

LiveView is flat in the log's size because the database pages and searches;
the FP-RISC app filters an in-memory list. The fan-out gap (10x even at 30
entries) is the driver, not the app: every FP-RISC tab renders its whole page
per change and asks the ONE register for the model in turn, where each
LiveView process renders only what its change tracking says moved, in
parallel. And the FP-RISC server burns 5.1% of a core IDLE with one tab (the
poller), against 0.1% -- it made FP-RISC's CPU per action look 7x LiveView's;
without it they are close at 30 entries (~1.3 vs 1.6 ms). FP-RISC wins on start
(8 ms, 195 ms at 10,000, against ~340 ms for `mix run`), memory at small
sizes, and code size.

### Closing the gap (2026-09-23)

What the LiveView comparison pointed at, and what was done:

- **Idle burn** (`machine/posix/park.c`): an idle hart napped 200 us and looked
  again -- 5,000 wake-ups a second per hart. It now parks on a condition
  variable (doorbell = `hal_ipi_send`, deadline = `hal_timer_arm`, the protocol
  `actors.c` already spoke), capped at 20 ms so no wake source can hang.
  5.0% of a core idle -> 0.4%.
- **Two threads** (`compiler/Build.hs`, `machine/posix/main.c`): `fpr build`
  compiled in 2 harts, so every FP-RISC server ran on two threads. The cap is now
  the build machine's cores, the live count the running machine's. (GHC's
  `getNumProcessors` answers 1 in fpr's non-threaded runtime; it asks `getconf`.)
- **Each tab got the whole model** (`std/live` `serveProjected`): the register
  answers a session's pull with `project sid model` -- the logbook's header, the
  session's toast and one page -- and a writer whose projection is unchanged
  renders nothing. Search runs once, when asked, and the session keeps its hits
  (kept current by adds, edits and deletes); toasts are per session, so one tab's
  "added #5" no longer re-renders every tab twice.
- **12 KB per tab per new entry** (`std/live` + `std/livejs`, protocol v3): one
  splice (common prefix + suffix) cannot say "a card on top, the last one off",
  so every card was re-sent. v3 sends a list of splices: 2.1 KB. The snapshot is
  built only when the patch might lose, and a patch that would re-send most of
  the page is not built at all.
- **The register waited on the disk** (`std/kvlog` `post`/`sync`): journal and
  field writes are posted; Quit and Reload `sync` first.

Same workload, same Mac, FP-RISC / LiveView, ms:

| | 30 entries | 1,000 | 10,000 |
| --- | --- | --- | --- |
| add | 6.7 / 2.0 | 5.9 / 2.2 | 10.7 / 2.2 |
| edit | 1.6 / 0.8 | 1.7 / 0.9 | 3.4 / 1.0 |
| page | 2.7 / 1.1 | 3.2 / 1.3 | 3.2 / 2.0 |
| search | 2.5 / 0.7 | 10.1 / 1.4 | 40.5 / 3.8 |
| one add reaching 50 tabs | 12.3 / 3.7 | 12.7 / 3.5 | 21.9 / 3.3 |
| memory, 51 tabs (MB) | 56 / 57-125 | 78 / 121 | 212 / 124 |

Fan-out went 35 / 38 / 84 -> 12 / 13 / 22 and memory at 10,000 entries 526 ->
212 MB. What is left: search is a scan in FP-RISC code (a database does it in
C, with an index for LIKE-free queries); every tab still renders its own page
in full-ish FP-RISC string building where LiveView re-renders only the changed
assigns of a compiled template; and the register -- one actor -- copies the
whole model when it tidies. (An earlier benchmark client spoke the legacy
protocol, so FP-RISC's fan-out figures before this section were measured with
full snapshots; this table uses the browser's v3.)

### The log in a store, and pages in sections (2026-09-23)

The LiveView comparison left three gaps; the first was a bug (above), these are
the other two.

**The register held -- and copied -- the whole log.** `std/store` (new) keeps a
keyed collection in SHARD actors: key k lives in shard k / span, which holds its
part in memory and appends every change to its own file, rewriting only THAT
file when superseded lines outnumber live ones -- compaction one small shard at
a time. A front actor routes writes (so a read after a write sees it) and
answers reads with a plan; readers ask the shards themselves, and a search asks
every shard at once. The logbook now keeps its entries there: the model is the
sessions, the next id and `rev` (bumped by every change); adds, edits and
deletes are commands that write the store and answer Stored / Saved / Deleted;
each tab's writer READS its page from the store when its View changes, so fifty
tabs read at once. A store opened empty takes the entries from an older kvlog
(Live.each records or one list), then blanks them there and compacts the kvlog.
`tests/std/store.fpr` covers shards, pages across them, search, removal, a
shard compacting itself, 3,000 writes that make every shard tidy many times, and
reopening. (It caught one of mine: a shard kept its file's path outside the
state it tidies, and the path dangled after the first reset -- anything built
inside an actor that must survive a tidy has to be IN the tidied value.)

**Every tab rebuilt its whole page.** The page is now five sections, each a
function of only what it shows (header, form, search bar, list, pager), and
`cachedView` remembers them in a second view cache beside the cards: the form
never renders twice, the bar only when the query changes. Verified cached ==
fresh under FPR_VIEW_VERIFY. It saves ~6% of server CPU per fan-out and no wall
time: rendering is no longer where the time goes.

Measured (ms, this build / the build before / LiveView):

| | 30 entries | 1,000 | 10,000 |
| --- | --- | --- | --- |
| add | 8.5 / 6.7 / 2.0 | 7.6 / 5.9 / 2.2 | 7.5 / 10.7 / 2.2 |
| edit | 1.9 / 1.6 / 0.8 | 1.7 / 1.7 / 0.9 | 2.5 / 3.4 / 1.0 |
| search | 2.8 / 2.5 / 0.7 | 9.2 / 10.1 / 1.4 | 17.5 / 40.5 / 3.8 |
| one add reaching 50 tabs | 15.0 / 12.3 / 3.7 | 13.8 / 12.7 / 3.5 | 15.6 / 21.9 / 3.3 |
| memory, 51 tabs (MB) | 51 / 56 | 65 / 78 | 193 / 212 |

Every operation is now nearly flat in the size of the log, and search is 2.3x
faster at 10,000 (every shard scans at once). An add costs ~1.5 ms more at small
sizes: it is two register turns (the command, then Stored) and a file append.

**What is left, measured.** A page turn is 3.2 ms with the harts awake and 9.5
ms after 1.6 s idle: the poller (`std/poller`) polls without blocking and backs
off to 5 ms between polls, so the first message after a quiet spell waits for
the next tick, then crosses parked harts. LiveView's runtime waits in the
kernel. Fixing it properly means a poller that blocks in the kernel without
blocking a hart -- a thread outside the hart pool that delivers readiness into
the actor system (the runtime's irq path is the natural place) -- and it is the
largest remaining cost of a fan-out (13-16 ms cold, ~4.4 ms warm).

### The poller waits in the kernel (2026-09-23)

`std/poller` polled without blocking and slept between polls, backing off to
5 ms, so the first message after a quiet spell waited for the next tick. It now
hands its descriptors to a HOST thread outside the hart pool
(`Os.watchOpen/watchArm/watchTake`, `machine/posix/os_watch.c`) that blocks in
poll(2). When something is ready the thread raises an interrupt: posix's
`hal_irq_claim` is no longer a stub (`machine/posix/hal.c`, one pending flag per
source, `hal_irq_raise` from any thread rings the IRQ hart's doorbell), and the
runtime's existing `irq_drain` delivers it to an actor bound with
`Sys.irqBind` -- the path a PLIC interrupt takes on bare metal. That actor
tells the poller, which notifies the owners and re-arms. A new arm interrupts a
poll in progress through a self-pipe; the same set re-armed is not.

The deadlock detector learned the same thing: an actor waiting for an interrupt
is not a deadlock, any more than a sleeper is (`g_irq_waiting`). An idle server
used to look "moving" only because its poller ticked; without the exemption the
detector killed idle servers after two seconds.

One tab, page turn: 1.2 ms warm (was 1.5), 3.2 ms after 1.6 s idle (was 7.9).
Idle CPU with 20 tabs open: 0 within ps's resolution (was 1.4% of a core). One
add reaching 50 tabs: first tab ~4.5 ms (was ~8), last ~18 ms (was ~21).

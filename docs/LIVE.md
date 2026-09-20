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

## Still open: two rare failures under test

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

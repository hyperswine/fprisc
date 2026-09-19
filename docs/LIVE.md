# Can FP-RISC host a real application? The FPRLive goal, measured

Kind: an assessment with evidence, 20 September 2026. The goal it measures against
is the application-language target: a GUI app (web first) in the FPRLive style --
an actor per connection, the static/dynamic split, per-field `Persistent a`, the
Ma primitives, client-side state, Elm's commands and subscriptions, state
replayable from an append-only store, reload at run time.

**Short answer.** For the WEB case, yes on both systems, at the scale of an
internal tool: hundreds of sessions, not tens of thousands. The shape holds and
every item on the list now runs on a plain posix process (`fpr run`) as well as on
QOS. What is not there yet is cheap sessions (a session costs about a megabyte),
and a typed surface where today there are strings. TUI and desktop apps exist only
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
| **`Persistent a`, per field, with options** | WORKS, but as a LIST beside the model, not a type inside it: `Live.intField "board/count" Live.Always get set`. Policies: `Always`, `AtMostEvery ms`. Needs a getter and a setter per field | `Live.Field`; restart brings back `count` and `notes` and, on purpose, not the clock |
| **Client-side state (`ClientState a`)** | PARTLY. It exists and never round-trips unless an event carries it (`G.Local`, `ShowIf`, `OnSet`, `Input`), and the demo declares it in one list like the durable fields. But it is NAMES IN STRINGS: a typo is a silent no-op | `genview` + the 150-line client script |
| **Elm's Cmd and Sub** | WORKS. `update` answers `Live.After ms msg arg`, `Live.Run name work` (runs in its own actor; the result returns as `Done name result`), `Live.Quit`; `subs` answers `Live.Every ms name`, re-read after every update, so a clock exists only while the model asks for it | the check's clock and digest legs |
| **Replayable from an append-only store** | WORKS. Every durable write is an appended line; with `journal` every EVENT is too, and `Live.replay` rebuilds the model from `init`, `update` and the log alone. The check rebuilds 1,950 events and gets the saved state | `std/kvlog.fpr`: `history`, `at time`, torn-tail tolerant |
| **Reload** | WORKS, differently on each system. posix: the server sees a source change, rebuilds, and only if that succeeds saves its fields and BECOMES the new program; browsers reconnect; 4 s, nearly all of it the compile. A rebuild that fails is printed and the old program keeps serving. QOS: a module is replaced IN PLACE through the plugin loader (`tests/livereload.fpr`), and nothing restarts | `liveboard-reload.py`, 8 of 8 |

## What it costs: sessions are not cheap yet

| sessions | join all | one event to all | resident | per session |
|---:|---:|---:|---:|---:|
| 100 | 0.08 s | 11 ms | 120 MiB | 1.2 MiB |
| 1,000 | 3.3 s | 260 ms | 3.5 GiB | 3.5 MiB |

QOS's FPRLive measured 263-600 KiB a session (one actor each, a 32 KiB slab).
Here it is two actors, and an actor's floor is set by the allocator's 64 KiB
unit: a 512 KiB stack block (allocated, mostly untouched), a pool slab, a message
slab, a mailbox block. Two things were fixed on the way and one lever is obvious:

- FIXED: the register pushed the whole model to every session on every event, so
  a join burst queued n * n copies. It broadcasts a VERSION now and a writer pulls
  the model when it is ready (a busy session skips to the newest): 3-4x faster.
- FIXED in the runtime: every actor that allocated anything took a 256 KiB slab at
  once. A pool's slabs now start at one block and double (`runtime.c`): 1,000
  small actors went from 508 MiB of arena to 196.
- NEXT: now that stacks GROW, an actor's first stack need not be 256 KiB. A
  per-spawn size (one block) would take about a megabyte off every session. After
  that, a smaller allocator unit for actors' fixed blocks.

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
5. **`exec` from a hart thread** inherits that thread's signal mask and the
   ignored SIGPIPE; `Os.exec` and `Os.run` reset both.

## What would make it the application language

In the order I would do them:

1. **Fields from paths.** The compiler already mints `@Model.count` as
   `{get, set, segs}` (`docs/PATHS.md`). `Live.persist @Model.count Live.Always`
   would replace the hand-written getter and setter, give the key for free, and
   is the honest form of "`Persistent a` on a field". The same literal can name a
   client-state field, which removes the strings from item 5 of the table.
2. **Typed messages.** Events arrive as `Msg sid "bump" "10"`: a name and a
   string. A `Msg` type per app with a generated decoder would let the compiler
   check the view against `update`.
3. **Cheap sessions**: per-spawn stack size, then one actor per session where the
   socket can be polled with the mailbox.
4. **The view layer in std.** `genview`, `ma` and the client script are pure and
   live in `qos/programs/mods`; they are the application library and belong
   beside `std/live` (STD-PLAN's point: the standard library is not in std).
5. **Commands worth having**: `Http` as a command (today `Live.Run` around
   `Http.get`), navigation, file upload (the websocket reader already takes
   fragmented and large messages), a port to the page's JavaScript.
6. **TUI and desktop on posix**: raw-terminal and input primitives in
   `machine/posix` (they exist in QOS's host, `hal/unix/tty_raw.c`), then
   `std/mvu`'s drivers run there too.
7. **Store maintenance**: compaction, fsync as a policy, and per-session state that
   does not live in the shared model.

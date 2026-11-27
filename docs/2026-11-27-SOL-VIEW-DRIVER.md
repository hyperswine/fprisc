# Sol serves std/view pages on std/live's wire (27 November)

Kind: delivery record. Branch `sol-view-driver`. The last part of item 5 of the
[Sol review](2026-11-26-SOL-SCRIPTING-REVIEW.md): share the typed view, event
and command types with FP-RISC, and keep separate drivers. The types became
shared in [SOL-STD-LIBRARIES](2026-11-27-SOL-STD-LIBRARIES.md); this adds the
Sol driver.

## Result

A Sol script serves a `std/ui` page with the same view types, message codec
and browser client as a native `std/live` app:

```sol
Live = use "../lib/live".
UI = use "std/ui".
G = use "std/view".
Msg = Type (Bump Int | Reset).
codec = @Msg.
update msg m = case msg of Bump n -> { m | count = m.count + n } | Reset -> { m | count = 0 }.
view m = UI.page UI.day UI.stack [
  UI.label { UI.txt | size = UI.Title } "Count {m.count}",
  UI.button UI.btn [G.send codec (Bump 1)] "+1" ].
>! Live.serve 8080 { title = "Counter", init = { count = 0 }, update = update, view = view, codec = codec }.
```

`sol/examples/live-counter.sol` is that app. In a browser, the page renders
with `std/ui`'s styles, and clicking +1 then +10 shows "Count 11".

## How

- **`sol/lib/live.sol`** is the Sol side, written against `std` (`std/view`,
  `std/json`, `std/javascript`, `std/livejs`):
  - the page: `std/live`'s HTML shell, the statics and dynamics from
    `G.renderStyled`, and the `std/livejs` client;
  - decoding a frame: `{"msg": wire, "arg": text}` through the app's codec,
    with `std/live`'s `=`, `+` and `*` forms;
  - `update`;
  - the snapshot pushed to every page.
- **`View.live port model page step frame`** (`sol-vm/Sol/Web.hs`,
  `serveLive`) is the native side. It owns the socket, runs every frame as one
  step in order under one lock, and pushes the new snapshot to every open page.
  - The snapshot is `std/live`'s protocol 0 (`{"s":[...],"d":[...]}`), which
    every client version accepts.
  - A frame the codec refuses leaves the model as it was.

`View.serve` and `sol/lib/ui.sol` are unchanged.

## Fixed on the way

- **A library adding strings failed in Sol.** Any module imported by a script
  that used `+` on strings or lists stopped with `unknown symbol: Str.+`.
  `std/javascript` hits this, so `std/livejs` could not run.
  - Cause: when imported libraries are sliced together with the prelude
    (`Sol.Slice`), slicing starts from the names the script itself mentions.
    A library's operators become struct members (`Str.+`, `List.+`) only after
    inference, so the slice dropped them.
  - Fix: that slice now also starts from the operator structs. The bug was
    present at 0.15.0; Sol 0.13 ran the same script.
- **Header names were matched case-sensitively** in Web.hs. Node's client
  sends `sec-websocket-key` in lower case, and its handshake failed. This
  affected `View.serve` too.
- **Text over the socket is byte-exact.** Web.hs's UTF-8 encoding now passes
  Sol's byte-string escapes through as raw bytes.

## Test

`tests/sol-checks/sol-live.sol` (push):
- starts the counter as a `Child`;
- checks that GET / is the `std/live` page;
- drives the websocket with `tests/sol-checks/live/client.mjs`, the frames
  the client sends. The snapshots read 0, 5, 5 (a refused frame), 15, then
  0 after Reset.

It needs Node's built-in `WebSocket` (Node 22). Where that is missing, it says
so and checks only the page.

## Not here yet

`std/live` also has the following, which `View.live` does not:
- commands (`After`, `Run`, `Navigate`, `Emit`);
- subscriptions;
- durable fields and the journal;
- per-session views;
- structural patches (protocols 2 and 3).

Each can follow the same split: the policy in `sol/lib/live.sol`, and in
Web.hs only what needs the socket or a thread.

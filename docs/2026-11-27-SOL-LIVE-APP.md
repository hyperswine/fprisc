# Sol serves whole std/live apps: commands, subscriptions, sessions, durable state, patches (27 November)

Kind: delivery record. Branch `sol-live-app`. It follows
[SOL-VIEW-DRIVER](2026-11-27-SOL-VIEW-DRIVER.md), whose `Live.serve` serves one shared page with
snapshots and no effects. The owner asked for the rest of `std/live`'s features.

## Result

`Live.serveApp port app store` (`sol/lib/live.sol`) takes `std/live`'s app shape, names and
meanings:

| | |
|---|---|
| `update : Live.Ev msg -> model -> (model, List (Live.Cmd msg))` | events `Msg sid m`, `Joined sid`, `Left sid`, `Refused sid why` |
| commands | `After ms m`, `Navigate sid url`, `Emit sid name detail` (sid 0: every page), `Quit` |
| `subs : model -> List (Live.Sub msg)` | `Every ms m`, re-read after every update: a ticker starts when a subscription appears and stops when it goes |
| `view : Int -> model -> G.Node` | each session's own page (sid 0 for GET /) |
| `store` | `None`, or `Some { path, save, load }`: the model is loaded at start and written (now) whenever `save` of it changes |
| frames | a page gets nothing when its page did not change, a structural patch (protocol 2, one splice per array) when its client asked and the patch is shorter, else a snapshot |

`sol/examples/live-room.sol` uses all of it. In a browser:
- two tabs showed "session 1" and "session 2", and the first went to "2 online" when the second
  joined;
- +1 then "+100 later" read 1, then 101 half a second later;
- the ticker counted while on;
- quit stopped the server, and a restart read the stored 101.

## How

- **The Sol side** (`sol/lib/live.sol`) holds all the policy, written against `std`:
  - the event decoding: a page's frame through the app's `@Msg` codec, `{"joined":true}`/
    `{"left":true}` from the driver;
  - commands turned into effects; a delayed message or a subscription's message is the frame a page
    would send for it, so it takes the same path in;
  - the durable writes;
  - the per-session frame with its patch against what that page shows.
- **`View.liveApp port model page step frame subs`** (`sol-vm/Sol/Web.hs`, `serveApp`) holds what
  needs the socket or a thread:
  - every step runs in order under one lock, and every session's page is brought up to date after
    it;
  - each session keeps its protocol and its last render;
  - the effects (push to a page, deliver later, quit);
  - one ticker thread per wanted subscription.

  The thread work is a few lines on top of the socket code `View.serve` and `View.live` already
  share.

Found on the way: the ticker's catch-all would have swallowed the kill that ends a dropped
subscription, so it kept ticking. Kills are re-raised now, and the check confirms ticks stop when
the subscription goes.

## Not here

- **`std/live`'s `Run`:** a command run in its own actor, its message coming back.
  - Sol has actors, but a `Run` inside a step would need the VM re-entered from another thread.
- **Per-field durable logs and the journal/replay:** `store` saves one projection of the model.
- **Reload, and protocol 3** (several splices per array).
- **Throughput:** each step re-renders every open session's page in interpreted Sol. A `std/ui`
  page is about 0.2 s to render, so a 200 ms ticker with two pages ran at about 2 ticks a second.
  Tickers wait for their step, so nothing piles up, but a busy room should tick slowly or render
  less.

## Checks

`tests/sol-checks/sol-live.sol` (push) adds the room. `tests/sol-checks/live/room.mjs`:
- opens two pages with `lv=3` and applies snapshots and patches as `std/livejs` does;
- checks joined and left (online 1, 2, then 1);
- checks that a bump reaches the other page, and `After`;
- checks that the ticker ticks and stops when toggled off;
- checks that an unknown message leaves the model alone;
- checks that patches were used, and `Quit`. The server exits 0 and the store holds 105.

It needs Node 22's `WebSocket` and skips the websocket half without it.

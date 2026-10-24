# Rendered handlers: Live events as capabilities

Date: 2026-10-24. Kind: review (descriptive, at `712f24f`) and plan
(proposed, not implemented). Subject: the event path of `std/view`,
`std/livejs` and `std/live` -- how a click in a page becomes a value that
`update` sees -- measured against a LiveView-style handler model. Part 1
is what the code does. Part 2 is the change proposed first. Part 3 is the
order of the work after it.

Nothing here changes the render split, deltas, splices, keys, the view
cache's contract or the codec. The proposal changes what a page sends and
how the server resolves it.

## Part 1: review

### How an event travels today

1. **Render.** A typed event attribute (`View.send codec (Delete e.id)`,
   `sendWith`, `sendWith2`, `enterWith`, `uploadWith`) puts the
   message's wire form into the element as text: `data-click="=[\"Delete\",17]"`,
   or for an open message `data-click="*[\"Change\",17]" data-args="etags,edit"`
   (`std/view.fpr` `attrOf`, `wire`, `openWire`). The text is part of the
   statics.
2. **Bind.** After every snapshot or structural patch the client's `build`
   calls `wire()`, which clears `onclick`/`onchange`/`oninput`/`onkeydown`
   on every element under the root and reattaches one closure per
   `[data-set]`, `[data-click]`, `[data-file]`, `[data-input]`
   (`std/livejs.fpr` `wireBody28`).
3. **Send.** A click sends `{"msg": <the attribute's text>, "arg": <the
   page's values>}` (`sendBody40`). Nothing else identifies what was
   clicked or which render it was clicked in.
4. **Decode.** The session's reader actor parses the frame and runs
   `decodeWire codec msg arg` (`std/live.fpr` `reading`, `eventOf`). If the
   app's codec decodes it, `update` receives `Live.Msg sid m`; otherwise
   `Live.Refused sid why`.

The codec is the only check between the socket and `update`, and the
codec answers "is this a value of type `Msg`", not "was this session shown
this action".

### Findings

**F1. Any message of the app's type can be sent by any page.** The
message travels from the client, so a page can send a message it was never
shown. Concretely, in `examples/logbook.fpr` at this revision:

- `Delete 17` deletes entry 17 from any tab, whether or not entry 17 is on
  that tab's page.
- The completions the app sends itself through `Live.Run`
  (`Stored by id`, `Saved who id`, `Deleted who id`, `Filled who text tags`)
  are constructors of the same `Msg`. A page can send `Filled 3 "x" "y"`
  and the app answers `Live.setClient 3 [...]`, writing text into session
  3's edit draft. `ClearToast` clears every session's toast.

`examples/inventory.fpr` already works around this by hand:
`Clear who n -> (case sid == 0 of ...)` accepts that message only from the
driver. That check is correct and is the pattern every app would have to
repeat for every internal constructor. Severity: high for any app served
beyond one trusted user; the apps here are household tools on a LAN today,
which is why it has not mattered yet.

**F2. Events carry no render generation.** A click on a button the newest
render has removed still runs: the frame does not say which render it came
from, and with the message in the frame the server has nothing to check it
against. Once the server resolves events (Part 2) this becomes a
correctness question, so it is settled there.

**F3. Every structural change rebinds every element.** `wire()` walks
`querySelectorAll("*")` and then four more selectors on each `build`. Cost
is proportional to the page, not the change, on every structural patch.
Text deltas do not rebuild, so the steady state is unaffected.

**F4. The event vocabulary is click, input, Enter and file.** No pointer
events, coordinates, modifiers, `preventDefault`/`stopPropagation` control,
or other keys. `std/browserfeedback` and `std/browserautocomplete` add
their own `pointerdown` listeners on `document` to get what the core
client does not offer.

**F5. Client state is one namespace per page.** The page's locals are one
`locals` object keyed by `localName` (`@Client.ui.tab` is `ui_tab`). Two
instances of a component that declare the same local share it. Families
(`cart[FW]`) work around this for lists of values, not for components.

**F6. Layering is integer `ZIndex` chosen per module.** `browserautocomplete`
uses 50, `browserfeedback` 60 and 61, `livenotice` 10000. The design-goals
review (2026-10-15) lists a `layer` node for `std/ui`; it does not exist yet.

**F7. The native MVU path has no pointer input.** `std/mvu`'s `Ev` has
keys, wheel and resize; `EMsg String String` carries external messages as
strings. There is no hit-testing, pointer stream or focus path, and
`std/ui` lowers straight to the HTML tree, so there is no UI IR a native
renderer could consume.

### What is already in place

These are the parts a handler model builds on, and they are sound:

- One register is the single writer of the model; each tab has a writer
  actor that renders `view sid (project sid model)` and owns what the tab
  last saw. That is the per-session state slice a component model needs.
- Typed messages with a compiler-minted codec, and `openWire`, which
  already computes the server's half of an open message (the message
  without the fields the page supplies).
- Keys, keyed reconciliation and v3 splices.
- `std/viewcache`'s `(namespace, key)` identities for memoized fragments.
- Attributes are never dynamic (dynamics are text only), so everything a
  handler needs is in the statics.

## Part 2: rendered handlers (proposed)

### The rule

A session may cause `update` to see a message only if the server rendered
that message's template to that session in one of its last two render
generations. The template is the constructor and every field the server
supplied. The fields the page supplies (`sendWith`'s trailing fields, an
upload, the client-state mirror) are the page's data, decoded by the codec
as today, and still need the app's own validation (a quantity in range, a
draft's length).

This is a capability rule: the rendered page is the session's set of
permitted actions. It removes F1 without any change to apps, and makes
internal completions (`Deleted who id`) unreachable from a page because
they are never rendered.

### Handler entries and ids

A handler entry is what a typed event attribute produces today, kept on
the server instead of in the page:

```text
Handler = { kind : String, template : String }
          -- kind "=", "+" or "*" (decodeWire's three forms);
          -- template the JSON that follows the kind in today's attribute
```

Its id is a hash of `kind ++ template`, written as hex. Properties wanted:

- **Content-addressed, not positional.** A positional id (the n-th handler
  in render order) would renumber every handler after an insertion, so
  every static after it would differ and v3 splices would lose their
  resync points. A content id is unchanged when a keyed list is reordered
  or grows, and cached fragments need no renumbering when composed.
  Two buttons with the same message share one id and one entry, which is
  correct: they are the same capability.
- **Cheap.** It is computed for every handler on every render. `std/digest`
  is SHA-256 at about a megabyte a second, which for a page of a few hundred
  buttons is milliseconds per render; that is the wrong tool. A 64-bit
  FNV-1a (two 32-bit lanes in the 63-bit Int) costs a few operations a byte.
- **Not secret.** Ids are looked up in the session's own table, never
  trusted. Knowing an id you were not shown gets you nothing.
- **Collisions are detected, not assumed away.** Inserting an id already
  bound to a different template is a render error naming both templates,
  the way a duplicate view key is. It is deterministic, so a test finds it.

The attribute becomes `data-h="<id>"`, with `data-args` unchanged for
open messages. Every attribute that today writes `data-click`,
`data-enter` or `data-file` with a typed wire value (`=`, `+`, `*`
prefix), including hand-built `G.OnClick` / `G.OnBoth` values, registers
its value instead. The string tier (`OnClick "pressed" "press"` naming a
message by text) is never accepted by `std/live` today -- `decodeWire`
requires a prefix -- so it keeps its current attributes for the QOS
driver and is not affected.

### Render

- `Ctx` gains the handler entries met so far (`Ctx cur statics dyns
  handlers`); `goN` on `El`/`Inp` adds the entries from that element's
  attributes. `render` and `renderStyled` answer `(statics, dynamics,
  handlers)`; the two-result forms stay as wrappers for callers that do
  not serve events (tests, `cssFor` users).
- `Fragment` carries its handlers: `Fragment statics dynamics classes
  handlers`. `appendFragment` adds them to the context as it adds slots.
  Since ids are content hashes, nothing is renumbered.
- `std/viewcache`'s `Output` gains `handlers`. A cache hit reuses them
  without rehashing. `FPR_VIEW_VERIFY` compares handlers as it compares
  statics and classes.

### Generations

The handler table is a function of the statics (attributes are never
dynamic), so it can only change when the statics do. A **generation** is a
counter the writer increments each time it sends a frame that changes the
statics: the first full frame, any later snapshot, any v2/v3 structural
patch. Text-delta frames do not change it and do not carry it.

- Server to client: full and structural frames gain `"g": n`.
  `{"s":[..],"d":[..],"g":7}`, `{"p":3,"s":..,"d":..,"g":8}`.
- Client to server: `{"h": "<id>", "g": 7, "a": <arg>}`. `a` is today's
  `arg` unchanged (absent for `=`, the upload text for `+`, the JSON array
  of the page's values for `*`).

Resolution accepts an id found in generation `g` if `g` is the current or
the previous generation. A click on a button removed by the newest render,
made before the page had applied it, is honoured (the user saw it). An
id not in the table of the generation it names is `Refused sid "unknown
handler"`; a generation older than the previous one is `Refused sid
"stale (generation g)"`. Two generations bound the server's memory to two
tables per session and cover the one frame that can be in flight.

### Who resolves

The writer renders, so the writer builds each generation's table. The
reader decodes. Two ways to join them:

**A. The reader forwards frames to the writer** (`Inbound text`); the
writer resolves and sends the event to the register. One more hop per
event, and a writer blocked writing to a slow socket delays its own tab's
inbound events behind that write.

**B. The writer sends each new table to the reader** (`Handlers g table`)
before it writes the frame that introduces generation `g`. The reader,
on each inbound frame, first drains its writer's messages without blocking
(`receiveFromNow reader writer`, as `std/actor`'s `awaitFromUntil` uses it)
and keeps the newest two tables, then resolves. The client cannot send an
event naming `g` before it has received the frame carrying `g`, and the
writer sent the table to the reader before writing that frame, so the
table is in the reader's mailbox by the time the event is read.

**B is proposed.** Events keep their current path and cost; table messages
happen only on structural changes. One thing must change with it: the
reader's shutdown wait (`writerFinished` -> `A.awaitFromUntil ... writer`)
takes the next message from the writer as the writer's reply, and a
`Handlers` message can now be that message. The wait must skip `Handlers`
messages until it sees the reply, or the writer must stop sending tables
once it has received `Stop`. Both are small; the first is simpler to
reason about.

### The client-state mirror

`SyncClientState ms msg` sends its template from the register to the page
at join (`syncFrame`), and the page sends the template back with its values
on every mirror. It becomes a standing handler: the register includes the
template in the reader's `Welcome`, and the reader binds it to the reserved
id `sync`, valid in every generation. The page sends `{"h":"sync","a":..}`.
Behaviour is unchanged, including that the mirror template is fixed at
join as it is today.

### Protocol version and old clients

The bundled client connects with `/ws?lv=4`. A client asking for
`lv` below 4 is a tab opened before an upgrade; the server sends it
`{"nav": <its own page>}`, which reloads it into the new client, rather
than serving the message-in-the-frame protocol. An app that must accept
old clients for a while sets `legacyWire = True` in its config, which keeps
today's path for `lv` below 4, and is visible in its source.

### What apps change

Nothing, for apps that use the typed attributes. Apps can then delete
their hand-written driver-only guards (inventory's `sid == 0` on `Clear`)
or keep them as defence in depth. Logbook's internal completions stop
being reachable from a page with no change to logbook.

### Wire size

An attribute today carries the whole message JSON, escaped into HTML; with
this it carries 16 hex digits. On a list of cards each with three or four
buttons that is most of the statics' attribute text, so first paint and
structural patches get smaller. This is a side effect, not a goal; measure
it on logbook and inventory rather than claim it.

### Validation

Extend `tests/check_live_wire.py` and the Playwright checks:

- A forged frame for a handler not on the page (`Delete` of an entry on
  another page) is refused by name, and the entry still exists.
- A frame naming an internal completion (`Deleted`, `Filled`) is refused:
  no handler was ever rendered for it.
- A click on a button removed by the generation in flight is accepted; one
  two generations old is refused as stale.
- Handlers inside cached fragments resolve, before and after the card
  order changes, with `FPR_VIEW_VERIFY=1` comparing handlers.
- Two buttons with one message share an id; two templates forced to one id
  (a test hash) fail the render with both templates in the message.
- The mirror still reaches `update` with the page's values and still
  mirrors a password field as declared.
- An `lv=3` client is sent `nav` and reconnects as `lv=4`; with
  `legacyWire = True` it is served as today.
- logbook, inventory and pos1 regressions pass unchanged, and their
  structural-frame sizes are recorded before and after.

## Part 3: after rendered handlers

In order, each depending on the ones before it.

**1. Delegated client dispatch (small; can land before Part 2).** Replace
`wire()` with one listener per event type on the root that finds its target
with `closest("[data-h]")` (and `[data-set]`, `[data-input]` for local
state). Structural patches then cost nothing to rebind (F3). In the same
change, let a handler entry carry flags (`stop`, `prevent`, `passive`) and a
field mask (pointer coordinates, button, modifiers, key) so the client
serializes exactly the fields the template's remaining arguments need, and
add pointer events (F4). The field mask lives in the handler entry, so it
is in the statics and the server knows what it will receive.

**2. Component targets (large).** A stateful component is a
`{ init, update, view, codec }` with its own `Msg`, whose state is a slice
of the session keyed by a component id. The id is `(namespace, key)`, the
identity `std/viewcache` already requires, never a tree position. A handler
entry gains a target; resolution routes the decoded message to that
component's `update`, so a child's messages never pass through its
parents' types (no `Html.map`). A child reports to a parent by holding the
parent's target as a value, typed by the parent's `Msg`. Client locals are
prefixed by the component id (F5). Per-component statics on the wire (each
component's statics cached client-side under its id, as LiveView's `c`
section does) come last, once the routing is settled.

**3. Layers in `std/ui` (medium).** A closed set of named layers instead of
integers: `Content`, `Sticky`, `Popover`, `Modal`, `Toast`, `Drag`, `Debug`,
each with a policy (does it block the layers below it from pointer input,
does it trap focus, what dismisses it, tree order or most-recent-first).
A node declares its layer where it is written, with an anchor and a
placement for popovers; rendering hoists it to the nearest layer host
(a `Modal` is itself a host, so a menu in a dialog lands above the dialog).
In the browser `Modal` lowers to `<dialog>` and `Popover` to the popover
attribute, which give focus trapping and top-layer stacking without an
index. The existing `ZIndex` uses (F6) move onto it. Giving each layer root
its own statics, so a toast appearing does not reshape the page, is a later
wire change.

**4. A UI IR and native input (large, separate track).** `std/ui`'s nodes
as data that both the HTML lowering and a native render service consume.
The native side needs, in `std/mvu`: a pointer stream (down, move, up,
cancel, with capture) as typed events in place of `EMsg String String`;
hit-testing against the resolved rectangles the render service already
computes, in reverse paint order with layer policies applied; and a focus
path for keyboard input that is separate from the hit path. The handler
table from Part 2 is what the native side dispatches into, so a page and a
native window run the same `update` on the same messages.

## Open questions

- Whether two generations are enough on a high-latency link where a user
  clicks during a burst of structural changes. The refusal is visible
  (`Refused`), so measure before widening.
- Whether `legacyWire` should exist at all, given that `nav` already
  reconnects an old tab into the new client.
- Whether the hash should cover the field mask and flags (Part 3.1) from
  the start, so adding them later does not change every id. Proposed: yes,
  hash the whole entry, with the mask and flags empty until 3.1.

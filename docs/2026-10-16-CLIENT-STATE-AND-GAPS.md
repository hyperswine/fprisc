# Client state, typed; the recorded gaps closed

Date: 2026-10-16. Kind: implementation record. Follows the re-audit of
[2026-10-15-DESIGN-GOALS-AUDIT.md](2026-10-15-DESIGN-GOALS-AUDIT.md) and the
named gaps of [2026-10-15-STD-UI.md](2026-10-15-STD-UI.md) and
[2026-10-15-HARDENING-DIRECTION.md](2026-10-15-HARDENING-DIRECTION.md).

## Client fields have their own types

Before: every client field was a `String`; the mirror arrived as a JSON
string the app parsed by hand; a click that needed two page values sent one
string, `"a|b"`, the app split; pos1's restock used `OnBoth` to put the sku in
a local first. Now, from pos1:

```
Tab = Type (Register | Receipts | Stock | Admin).
Client = { tab : Tab, open : Int, tender : String, delta : Int, cmd : String,
           name : String, pin : String, cart : List (String, Int) }.
client = { tab = Register, open = 0, tender = "", delta = 10, cmd = "", name = "", pin = "", cart = Nil }.
Msg = Type (Login String String | ClientState Client | Restock String Int | ...).

subs m = Live.SyncClientState 500 (ClientState client) :: ...
locals = G.locals @Client client.
tab t label = UI.button { pill | vary = [UI.onState @Client.tab t [UI.Inverted]] } [G.setTo @Client.tab t] label.
pane t kids = UI.vstackWith { UI.stack | fill = UI.Grow } [G.showIf @Client.tab t] kids.
UI.button action [G.sendWith2 codec Login @Client.name @Client.pin] "open register"
UI.button pill [G.sendWith codec (Restock p.sku) @Client.delta] "restock"
UI.input { UI.field | placeholder = "10" } [G.bindInt @Client.delta]
UI.button pill [G.step (G.entry @Client.cart p.sku) 1 0 (imin 999 p.stock)] "add"
| ClientState c -> mirror m sid c                 -- c.tab : Tab, c.cart : List (String, Int)
Live.setClient sid [G.assign @Client.tender "", G.assign (G.entry @Client.cart sku) 0]
```

A field of the wrong type, a value of the wrong type, a message whose
constructor wants an Int where the field holds a String: compile errors.

**How.**

- The compiler: a field path (`@Client.delta`) carries `zero`, a value of its
  type (0, "", False, Nil, a record of zeros, a sum's first constructor), so
  `sendWith codec (Restock p.sku) @Client.delta` builds the message from the
  constructor itself and drops the fields the page fills. The bare schema
  `@Client` covers every leaf with a codec, each entry `{ path, tag, wire,
  unwire }` (`tag` int, str, bool, enum, wire); std/lens's string tier goes
  through the leaf's codec, so a text the codec refuses is an Err.
- The page holds TEXT: a number, `true`/`false`, a string, a bare
  constructor's name (`Json.wireText`). The prelude's decoders read exactly
  these from text (`wireCon` now reads a bare name), so what the page sends is
  decoded to the field's declared type or refused by name.
- std/view writes typed attributes: initial values in one `x-json` object per
  element; `data-set` with `data-to` (a value), `data-add`/`data-min`/`data-max`
  (an Int step), `data-flip` (a Bool); `data-when` with `data-is` or
  `data-is-not` (a list of texts); `data-input` with `data-kind="int"` (an
  input that takes only whole numbers, marks other text `aria-invalid` and
  keeps its value); `data-args` (the names whose values a click sends). The
  string tier (`Local`, `OnSet`, `ShowIf`, `OnBoth`, `OnClick`) is unchanged:
  QOS's pos1 over mods/fprlive still uses it.
- A FAMILY is a field of type `List (String, a)`: one value per key, held by
  the page as `cart[FW]` (`G.entry`, declared where it is drawn with
  `G.hold`), handed back by the mirror as the list of pairs.
- On the wire a message whose last fields the page fills is `"*"` and the
  JSON of the rest; the event's argument is a JSON array of the page's values
  (std/live `decodeWire`). The mirror is the same form with one value, the
  record. A password field is mirrored as it was declared, never as typed.
- `Live.setClient sid [G.assign path value]` puts values in a page; an input
  bound to an assigned field shows it even while it has the focus (logbook's
  form-fill port, std/browserformfill, is no longer needed there).
- An element carrying two of one event or condition (two `data-set`, two
  `data-when`) is refused by name at render: the browser would have kept the
  first and silently dropped the second.

**The apps.** pos1: `Tab`, `open`, `delta`, the cart family; `Login` and
`Restock` take typed fields; the console message is `Command` (`Admin` is a
tab). inventory: `Pane` and `Sort` enumerations, `confirm : Int`, `Login` and
`AddMember` take two fields. logbook: `Post tags text` and `Change id tags
text` take two fields; `Add` and `Save` (one "tags|text" field) stay for the
journals that hold them, and `tests/check_viewcache.py` and the std leg still
send the old form once each.

**Limits.** A client record is flat: a nested record's leaves are held as
`a_b`, and the mirror does not nest them back. Values the page computes in
JavaScript (std/browsercalc) read a local's text.

**Tests.** `tests/std/clientstate.fpr` (zeros, the schema and its string
tier, every attribute, decoding a send and a mirror, refusals by name, the
duplicate refusal); `tests/check_client_state.cjs` with
`tests/clientlive.fpr` (a real browser on one and four harts: an
enumeration, a whole-number input refusing other text, a toggle, a password
mirrored as declared, family steps within bounds, a two-field send, the
server's assignment into a focused input). The app checks drive the typed
forms: `check_client_calculations.cjs` (pos1's carts), `check_pos_reload.py`
(a typed mirror over a socket), `check_inventory_console.cjs`,
`check_theme_autocomplete.cjs`, `check_live_dom.cjs` (logbook),
`tests/std/logbook_ws.py`, `check_viewcache.py`.

## The recorded gaps

- **A save is answered.** `Durable.save` and `close` return `Result Unit
  String`; a refused write is an Err and the program goes on
  (`tests/std/durable.fpr` replaces the log with a directory and back). The
  writes are posted and checked by `KvLog.trySync`, which answers the first
  failure of a posted write since the last trySync. Found on the way: a
  durable `each` field (a list kept per element) wrote nothing on a save
  after the open; its start now writes the elements that differ from the log.
- **A refused value ends the actor, not the machine.** `charAt` and `!` past
  the end, `chr` of a non-byte, `Vec.get`/`set`, `SStr.at`/`put`/`push`, a
  bit index or mask outside the word, I64 division by zero, a full render
  buffer, an unknown `Mod.fn`: traps (`fpr_trap_num`, `fpr_trap_range`), so
  on a worker they are its death with the reason (`tests/base/deathwhy.fpr`
  on 1 and 4 harts); on actor 0 they panic as before. A value of the wrong
  type at a primitive stays a machine panic: a typed program cannot make one.
- **The two-field send**: above.
- **QOS's maapp and liveboard** were on the retired std/ma. liveboard is on
  std/ui with a typed `Tab` and typed sends (its check, its reload leg);
  maapp is `programs/uiapp.fpr`, the same render harness over std/ui, run on
  bare metal by check-all.
- **The plane's copy (QOS).** A trap in a loaded process goes through the
  plane's `fail`, the kernel's `fpr_actor_fail`, which keeps the reason: the
  launcher hears `failed: dead actor: errorproc: deliberate`. What stood in
  the way was QOS: no kernel built since the 2026-10-15 safety tightening,
  because the frozen std/actor every QOS module pins (v3.0,
  `.fpr/store/201a0e9bf98a5154.fpr`) was not on QOS's trust list. It is
  byte-identical to fprisc's allow-listed `std/actor.fpr` at `dcf9fbc`, and
  is listed now, as its v1.0 and v2.0 were; the QOS checks that compared a
  death to the bare `"dead actor"` read the prefix.

## The leftovers

- **Pixel literals**: none left in pos1, inventory or logbook. std/ui names
  fixed sizes by what they hold -- `column Count`/`Mark`/`Act`/`Figure`,
  `tile gap`, `side`, `peek`, `console`, and `body`/`screenBody` for the
  document body -- with its numbers in one place.
- **The autocomplete prototypes** are `Autocomplete.prototypes palette` in
  std/browserautocomplete, beside the script that clones them, as the
  feedback prototypes already were in std/browserfeedback; inventory only
  places them.
- **Browser hooks as values.** A std module exports the hooks its script
  reads: `G.hideEmpty`, `G.syncNow`, `LJ.link`, `Autocomplete.scope` and
  `Autocomplete.from list`, `Feedback.theme light`. An app's own hooks are
  one std/browsercalc target each (`taxHook = B.Attribute "data-tax"`),
  placed by the view with `B.mark` and read by the script, so the name is
  written once.

## Stale checks found and repaired

- `check_view_utilities.cjs` measured inventory's pre-std/ui layout (the
  column's padding, `.console`, `data-on`); it measures the std/ui page now,
  and std/ui gives every field a 44px minimum height (the console input was
  42px).
- `check_theme_autocomplete.cjs` built `tests/themes.fpr`, which used std/ma;
  it is on std/ui's `day` and `night`.
- `check_live_patch.cjs` sliced `std/livejs.fpr` as JavaScript text; it reads
  the rendered client.
- QOS `liveboard-check.py` looked for the page's old text (`.col`,
  `window.__LV__`, `new WebSocket`).

## Not done

- `Persistent a`: a decision, not a defect; `Live.field` and std/durable
  remain the declarative persistence.
- The string tier of std/view stays for QOS's own pos1 and liveview.

# Keyed views: structural snapshots without replacing the page

`View.key "entry-42" card` gives an element a stable identity among its siblings.
Keys must be unique within a parent. Use an item's persistent ID, not its list
position. Keys work on `El` and `Inp`; applying one to a text node is an error.

Logbook gives its entry-list container a stable key and each card its entry ID.
The list container remains present even when empty. The original protocol is: `{s,d}` is a complete snapshot and `{d:{index:text}}` is a text delta.
Old clients can still display the page, but need a refresh to get reconciliation.

On a snapshot the new client builds a detached tree, fills its dynamic slots
using textContent, then reconciles it against the live tree. Keyed siblings are
matched by identity and moved/reused; unkeyed siblings are matched by position
and node kind. Missing nodes are removed. Attributes and text are updated in
place. Slot numbers are updated too, so later text deltas address the new order.
Handlers are rebound and obsolete handlers cleared. Bound form values remain
browser-owned, with the existing explicit client-state ports for server changes.
Focus and selection are restored after moves when the original element survives.
Removing the element does not transfer its focus to a replacement.

The initial DOM change was the first step. The v2 extension below now reduces
structural wire traffic; the server still renders and compares complete views.
No cache, DOM scroll/composition guarantee, or general keyed-component lifecycle
is claimed. Component-level wire patches and server render caching remain next.

## Validation

Build the example, then run the Playwright regression with its executable:

```sh
fpr build examples/logbook.fpr -o /tmp/logbook-keyed
node tests/check_live_dom.cjs /tmp/logbook-keyed
```

The test needs Playwright and its Chromium browser installed (`NODE_PATH` can
point at an existing package installation; `CHROME_BIN` can select a browser).
It starts a server on a dynamically allocated loopback port with a temporary
store, tests two browser sessions, then stops the server and removes the store.
It checks keyed card identity, insertion/deletion, draft and edit focus/selection,
rebinding handlers, slot renumbering, and plain-text treatment of markup.

For this change, the app compiled and two-session interactions were checked in
the Codex in-app browser: insertion/deletion preserved local drafts and selected
text, saves reached the other session, and markup stayed text with no client
errors. The standalone Playwright run was blocked by macOS sandbox restrictions
on browser startup; its exact identity assertions have not run in that browser.

## v2 structural wire patches

The bundled client now connects to `/ws?lv=2`. Exact opt-in keeps older clients
on the original protocol. The initial frame (also after reconnect) is always
`{s:[...],d:[...]}`. Ordinary text deltas are unchanged.

When structure changes, the server can send:

```json
{"p":2,"s":[3,1,["replacement markup"]],"d":[2,0,["inserted text"]]}
```

Each array patch is `[start, deleteCount, insertedValues]`. Equal prefixes and
suffixes are retained. The client validates both patches and the resulting
static/dynamic lengths before installing the new arrays and reconciling the
DOM. It does not use variadic splice calls, avoiding argument-count limits on
large updates. The server sends a full snapshot if that is smaller. Unchanged
structure still uses sparse text-slot deltas. This is an array-range protocol,
not a general per-component patch protocol.

WebSockets preserve frame ordering within a connection. Malformed patches or
JSON close the connection using application close code 4002; the existing
reconnect path obtains a new full snapshot. No replay of old connection patches
is attempted. This requires no application API or nginx changes.

Validation commands:

```sh
python3 tests/check_live_splice.py
node tests/check_live_patch.cjs
python3 tests/check_live_wire.py /tmp/logbook-keyed
```

Build `/tmp/logbook-keyed` from current sources first. The wire test creates its
own disposable server and compares reconstructed v2 views with legacy snapshots
through insertion, edit/save and deletion. It also checks reconnect snapshots.
The recorded run produced six structural patches of 98–1776 bytes. In-app browser
checks confirmed insert, edit, save, deletion and plain-text rendering, with no
client errors. Full server rendering and component render caching remain open.

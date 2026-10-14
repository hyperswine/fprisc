# App acceptance: POS v1 and the home inventory

Kind: acceptance record. 2026-10-14, at `a1792f1`.

## Verdict

Core usage of both live apps is accepted. `examples/pos1.fpr` (a point of
sale) and `examples/inventory.fpr` (a household inventory) do what they are
for, at the speed a person needs, on phones and laptops, over the real
deployment path. The owner uses them and reports they feel responsive, and
the automated checks below agree.

So **performance work should look elsewhere**: at FP-RISC itself, its
tooling, other apps. The numbers below say why. A tap in either app costs a
few milliseconds of server work, and the network costs more than that.
Making the apps' server paths faster would not be felt.

## What "core usage" covers

- **POS v1**: sign in as a cashier, build a cart, check out by cash or card,
  read receipts, void one, restock, the admin console and profile. Two
  registers at once, each with its own cart, and the log rebuilt after a
  restart.
- **Inventory**: sign in once per device. Search by any word, by place or tag
  chip, and by sort. Page through the list, add, edit (with autocomplete for
  room, spot and tags), move, delete. The household pane (members, passwords,
  devices) and the admin pane (console and profile).

## Evidence

### Used by its owner

On 2026-10-14 the owner reported that both apps feel quite good from the user
side. This was after the inventory's responsiveness round, which removed the
search's wait for the mirror tick and added immediate feedback (`5da916c`),
and after the storage round (`586cc1d`, `aee3e96`, `a1792f1`).

### Automated, run on 2026-10-14

| Check | Result |
|---|---|
| `tests/check_pos_reload.py` | PASS: on 1 and 4 harts, two live sockets/cashiers/carts, checkout policy changes, receipt history, invalid and incompatible reloads refused, recovery, log rebuild; ordinary run without a journal |
| `tests/check_std.py` | PASS except `poller` (112 bytes allocated where 0 are expected; failing on main before the storage change too). The checks after it were run separately and pass, including the logbook live-app end to end |
| `tests/check_persistence.py` | PASS |
| `tests/base/viewcache.fpr` | PASS, including `retain` (the inventory's bounded card cache) |
| The inventory on a copy of the production log | 49 items folded; edits, a restart and `rebuild` agree; a torn last line is cut at boot; a log replaced under the running server stops it so launchd folds the file again |
| The inventory in a browser at 375 px | sign-in, search, chips, paging, edit, autocomplete (Tab, arrows, a second tap), console, profile; `INV_VIEW_VERIFY=1` (each cached card checked against a fresh render) panicked on nothing |

### Measured

Where a tap's time goes in the inventory, at 20 items a page:

| Part | Time |
|---|---|
| Server work for a message (edit, page) | 15-28 ms locally, end to end in the browser |
| Server work for a search, chip or sort (after `5da916c`) | 15-21 ms; typing 45-80 ms, including a 60 ms debounce |
| The same before `5da916c` | 127-142 ms, nearly all of it the 300 ms mirror tick |
| A disk append (std/logfile, `a1792f1`) | 31 us average (75 us with an open per append): about 1% of a tap |
| The update itself (`step`) | tens of microseconds (the app's own profile) |
| Network, laptop to Linode | ~18 ms |
| Network, Linode to Mac mini over Tailscale | ~12 ms (direct, not relayed) |

pos1 has the same shape: one model actor, a projected view per register,
and one append per committed line.

## Not covered, and known gaps

None of these blocks acceptance. They are here so the verdict is not read
for more than it says.

- **The QOS pos1** (`qos/programs/pos1.fpr`, `qos/qos/tests-host/pos1-check.py`)
  was not run in this round. The deployments are the posix build.
- **`pos.cswine.cloud`** (the Mac mini) still serves a pos1 binary built on
  2026-09-29. The current one is on EC2 (`pos.aws.cswine.cloud`).
- **Scale** is a household's or a small shop's: a handful of sessions. The
  measured ceiling is in 2026-09-20-LIVE.md (hundreds of sessions).
- **No offline mode.** A page needs its server. The inventory shows
  "reconnecting" while the client is reconnecting.
- **Flaky or unrun checks**: the stateless leg of `tests/check_viewcache.py`
  fails about one run in three, on main without these changes too.
  `tests/check_live_dom.cjs` needs Playwright, which was not installed.
- **Websocket frames are not compressed.** A full render (opening the editor,
  a reshape) is tens of KB. This is the one app-path cost worth revisiting
  if mobile-data use shows it.

## Where to look instead

Seen while doing this work, and not yet measured as targets:

- The first page load renders the whole page and the stylesheet's sample
  tree on every `GET /`. That measured 59-97 ms Linode to Mac mini end to
  end, against a 13 ms Tailscale round trip.
- Compiling an app is slow: `fpr build` takes 22 s for the inventory and
  104 s for pos1 on an M2. Every deploy pays for it, and so does every live
  reload (2026-09-20-LIVE.md measured a reload at 4 s, nearly all of it the
  compile, on a smaller app).
- The open items in 2026-09-29-Sol-Improvements-Needed.md and
  2026-09-30-NATIVE-PERF.md.

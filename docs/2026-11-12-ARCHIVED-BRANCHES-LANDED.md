# Archived branches landed on main (2026-11-12)

The branch cleanup earlier today left work that was not on main under
`archive/2026-11-12/*` tags. This note records what was applied to main
from them, what had to change to fit main as it is now, and what was
checked. The tags are deleted after this lands.

## What landed

| Archive | Applied as | Notes |
|---|---|---|
| `qosapp-receive-loops-main` (e56633af) | five runtime/compiler commits, cherry-picked in order | conflicts below |
| `qosapp-receive-loops` (20ad4332) | nothing | the same five commits on an older base; superseded by the row above |
| `linear-record-update` (defdcbe7) | one commit, unchanged | `{s \| n = s.n + 1}` on an owned record |
| `im-canon-suite` | nothing | its content was already on main |

The five runtime commits:

1. QOS app images (qa64, qx64, qrv64) take the receive-loop form instead of
   the `$receiveLoop` trampoline.
2. The scheduler drain scans only live harts' incoming rings.
3. Direct handoff: an actor that woke a same-hart peer and then blocks
   switches straight to it (`direct_handoff`, at most 64 in a row, only when
   the peer is the hart's one piece of work).
4. Small flat messages ride in their ring slot (`send_inline`).
5. Bounded inboxes take the slot-carried path, charged what the ordinary
   path charges.

`codegenRev` is 219 (the receive-loop form changes emitted code for QOS app
targets).

## How the conflicts were resolved

Main had moved under these commits (`b139ba83`'s local wake hint, sender
credits, the inbox charge function, the block cache, register fuel).

- **`block_unless`**: main's signature (`int`, with the wait kind) is kept;
  the branch's `direct_handoff` is added in front of it and called where the
  branch called it. Main's `FPR_LOCAL_HANDOFF` wake hint is what
  `direct_handoff` reads, so the two work together: the hint names the peer,
  and the handoff takes it when the peer is the hart's only work.
- **Ring blocks**: main's `ring_block_bytes` (mailbox accounting) gains the
  cell-area term, so `Sys.mailboxCommittedBytes` counts a ring's inline cell
  area.
- **Inbox charges**: main already had `inbox_reserve_bytes` (with sender
  credits); the branch's copy is dropped. `fpr_msg_inline_charge` uses
  main's `fpr_msg_slab_charge` instead of the branch's `charge_bound`, so a
  slot-carried message is still charged exactly what the ordinary path
  charges.

## Tests

- `tests/check_inline_messages.py` (new, registered): `tests/base/inlinemsg.fpr`
  and `tests/base/inlinebounded.fpr` at 1, 2 and 4 harts, three runs each,
  exact output. These two programs came with the branch but no suite ran
  them.
- `tests/check_parked_receive.py`: the probe observed parks only in the hart
  loop. A direct handoff parks an actor without a pass of the hart loop, so
  the probe now also instruments `resumed()`. Its emission check expected
  QOS app targets to keep the trampoline; they now take the receive-loop
  form like every other target.
- `tests/check_structural_ownership.py`: 39 cases pass, including the ten
  record-update cases.

## Measured

Same-hart round trip (send a two-word tuple, wait for the Int reply), hosted
arm64, 1 hart, 2,000,000 trips, three runs, with the base suite running on
the same machine:

| Tree | ns per round trip |
|---|---|
| main before (5c24b339) | 182, 183, 196 |
| with these commits | 95, 96, 97 |

## Not checked here

RISC-V boards, the Pi and Linux A64 were not run. The x86-64 checks that
need a native x86-64 host, and the SoftFloat checks, do not run on this Mac.
`check_x64_scalar`, `check_x64_qos`, `check_trmc_arc` and `check_trust` were
failing on main before this and are unchanged by it.

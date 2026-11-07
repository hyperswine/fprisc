# The frameless entry: checks before the frame (step 1, first slice)

Date: 7 November 2026. Status: implemented on AArch64, default OFF behind
`FPR_TYPED_IR_FRAMELESS_ENTRY=1` (`-frameless` in the codegen cache
identity). This is the first slice of
[the fixed-costs proposal](2026-11-06-FIXED-COSTS-PROPOSAL.md) step 1,
landing the mechanism its addendum identified: the entry checks run before
the frame exists, so a frame and its saves can move past an early-exit
branch. The mechanism is verified; the placement policy that would capture
the win is not yet extended, so the flag stays off (see Measurements).

## What changed

- `Codegen.Target.A64.framelessChecks`: the stack check and fuel tick run
  with the link staged in the stack headroom (`sub sp,#16; str x30,[sp]`,
  inside FPR_STACK_HEADROOM's 64 KiB), the check budgeting the frame the
  first save group will build plus the staging word. Both slow paths go
  through unit-local register-preserving wrappers so x0..x7 survive without
  frame slots: the existing `fpr_fuel_save_local` and the new
  `fpr_stack_grow_local` (`A64.stackGrowWrapper`, x29-framed, keeps the old
  sp and passes the new segment through in x0). The growth branch reloads
  the link from the OLD sp before adopting the new one, then restages it
  there - `reserveFrame`'s relocation discipline.
- The frame build moves from the `Enter` pseudo into the first save group,
  so `shrinkWrap` can move frame, saves and arrival copies together.
  Functions with no saved registers keep the frame at the `Enter` as today.
- `shrinkWrap` gains a carrying mode (`Codegen.Target.Common`): when the
  frame may be placed after the entry block, any block that calls or
  touches a frame slot anchors the placement point, and a return block
  before the point returns with a bare `ret` (no frame was built, the link
  is still in x30, sp was never moved).
- Gate: the reorder fires only for register-passed arities (<= 8), frames
  that need no reservation, non-forwarded entries, and head runs
  consisting only of labels, arrival moves and the entry pseudos. Anything
  else keeps today's frame-first order.

## Verification

- `fib` differential: identical output with the flag on and off.
- A 300,000-deep recursion (about 9.6 MB of frames, many segment
  relocations through the new growth branch, including the restage)
  produces identical output with the flag on and off.
- The unit cache identity carries `-frameless`, so on/off builds cannot
  share units. The default build is unchanged (flag off), and the default
  oracle suites pass.
- `tests/check_pagination.py` currently fails on this tree with a cold
  cache **with and without this change** (verified against clean HEAD with
  the change stashed: same `UNPROVED` size lemmas for `sortBy`/`sortWith`/
  `unique`). That failure predates this work and is not affected by it.

## Measurements, honestly

`fib 35`, interleaved, this machine (arm64 macOS):

| variant | median | min |
|---|---:|---:|
| default | 0.0535 s | 0.0499 s |
| frameless | 0.0614 s | 0.0567 s |
| frameless + shrink-wrap | 0.0618 s | 0.0574 s |

The frameless entry is currently **14-15% slower on fib**: the staging
costs three instructions at every entry, and the projected saving did not
materialize because `shrinkWrap` declines fib's shape - the recursive
worker's call block is inside its own reach (the placement refusal rule),
so the frame and saves stay at the entry and the staging is pure cost.
This is why the flag is off by default. The mechanism this slice set out
to land (checks without a frame, relocation-safe staging, wrappers,
frame-in-save-group) is in place and verified; capturing the win needs the
placement work:

1. Extend the placement policy for after-fork points that dominate their
   own loop (the frame is built once per call, not per iteration - the
   refusal rule is more conservative than the shape requires).
2. Re-measure against the hand-written ladder's frameless `n < 2` row
   (0.54 of emitted) as the target.
3. Then take the same mechanism to x86-64 and RV64, and re-qualify the
   stack unwinding under the moved frames (`Stack.selectedFrame` proof).

## Follow-ups

- The x27 register-fuel proposal needs the JIT boundary added to its
  checklist (see the fixed-costs addendum); this change does not touch
  fuel conventions.
- The pagination failure noted above needs its own investigation on a
  clean tree; it is not this change's regression but it currently blocks a
  fully green base suite on this machine.

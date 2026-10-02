# The arena override belongs to the actor, not the hart

Date: 2026-10-02. Kind: implementation record (a runtime fix). Applies from
the commit carrying this page.

## The bug

`Sys.arena` and `Sys.loopWith` run a thunk under a fresh pool: every
allocation inside goes to the arena, and the arena is torn down wholesale
at the end, with only the result copied out. The pool switch was a field
of the HART (`fpr_hart_t.pool_override`), consulted by `cur_pool` for
every allocation the hart made.

An actor inside its arena that parks, as it does on every `AC.call` (the
wait for the reply is a blocked receive), hands the hart to other actors.
Those actors allocated into the parked actor's arena, because the hart
still said so, and when the step ended the arena was torn down under
them. QOS found it the day its launcher started talking to its keyboard
by message from inside `Sys.loopWith` (docs there:
`2026-10-02-ENDPOINTS.md`): the keyboard endpoint's queued bytes, and the
UART service's state, were valid for one turn and garbage the next, only
on native, only with the launcher drawing. Nothing in the runtime's own
suites parks inside an arena while other actors run on the hart.

## The fix

The override is a field of the ACB (`fpr_acb.pool_override`), set and
cleared by `arena_open` and `arena_close` on the current actor, and read
through `override_slot` by `cur_pool`. The hart's field remains for the
hart-loop context, where there is no actor. An actor parked inside its
arena shadows nothing but itself.

## What a reader of the pool rules should take from it

Per-hart state must be per-actor state unless it is dead at every
scheduling point. The hart's `copy_pid`, `rbuf` and `rpos` are of that
second kind (used and finished inside one primitive); `pool_override` was
not.

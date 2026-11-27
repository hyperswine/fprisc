# Checked recursion: per-invocation budgets

Kind: **proposal**, not an implemented rule or a 1.0 decision. Written
2026-11-26 against `7ed74a6a` (`zero-cost-named-keys`). Addresses the
recursion question in [v1.0 semantics §6](2026-11-26-V1-SEMANTICS.md#6-patterns-and-definitions).

## What the budget is for

Scheduler fuel already gives other actors a turn. The native compiler retains
fuel ticks on recursive cycles, including self tail calls lowered to loops.
When fuel runs out, the scheduler requeues the actor and gives it a fresh
slice on resume. A macOS arm64 Base probe confirmed that a tail-recursive
spinner with no explicit yield let another actor pinned to the same core run.
The spinner was still running when the probe stopped.

Add a separate recursion budget so a particular invocation can fail cleanly
instead of spinning through slice after slice. Keep the existing stack
headroom checks: a few large frames may hit the stack limit before the
recursion budget runs out. A recursion budget counts calls, not bytes,
instructions, or time between calls.

## Admission and accounting

- **Proved recursion:** no recursion budget check. Existing scheduler fuel
  and stack checks still apply.
- **Unproved recursion, checked mode on:** accept an eligible recursive group
  with an explicit finite limit. Warn once for the group that termination was
  not proved and a budget check will be inserted. This replaces the need for
  `unsafe` **for that recursion only**. It does not waive other safety checks
  or certify the function as total.
- **Unproved recursion, checked mode off:** require the existing explicit
  `unsafe` opt-out or reject it. Do not silently remove a guard from code
  that relied on checked mode.

The first entry into a guarded group starts one counter for that invocation.
The initial entry and the base case's return cost nothing. Charge one unit
before each call from within the group back into it, including self tail
calls and calls between mutually recursive members. A limit of 0 permits
entry but no such calls; a limit of N permits exactly N. At zero, fault
before making the attempted call or growing its frame.

Both recursive branches of a call such as `fib` spend from the same
remaining counter. Returning from the first branch does not refund anything
or give the second branch a copy of the old balance. The counter survives
suspension, resumption and migration, and is discarded when the invocation
ends. A later independent call gets a fresh counter.

For the first implementation, cover direct, statically identified recursive
groups, including local groups where the compiler can identify them. If an
indirect call, callback or foreign re-entry can return to an active group
and the compiler cannot preserve its accounting, do not accept that path as
budget-checked. In particular, do not let re-entry reset an active counter.
Keep charges attached to the original recursive edges through lowering:
tail-call conversion, inlining or loop formation must not silently change
which call faults.

## What the supervisor sees

When a charge is refused, the runtime records `RecursionFault` as a typed
actor exit reason, terminates the actor through its normal failure path,
and makes that reason available to its registered supervisor or monitor
through the runtime's exit reporting. The supervisor can restart, report,
or escalate. The failing actor does not have to allocate or send an
ordinary mailbox message just before dying. The reason should remain
observable even if the supervisor's ordinary mailbox is full.

Start with the failing member and call site, the configured limit, and the
actor identity from the exit event. Preserve legacy string errors where a
public API already promises them; do not implement restart policy in the
compiler. Specify the unsupervised/root exit path separately; a managed
child's exhaustion must not turn into an OS fault for the whole process.

## First implementation and acceptance

Start with native Base actors. Decide the source spelling and how guarded
groups are reported by `fpr check`, `fpr build` and `fpr stdcheck`.
A proof-only gate should still distinguish a bounded-by-fault invocation
from a verified measure. Leave a default limit, Sol, and supervisor-less
Builtin targets out of the first slice. No WCET or global work bound
follows from this proposal: an invocation can still block or spend
unbounded time before it reaches a charged edge.

1. With checked mode on, an unproved self tail loop with limit 3 faults on
   its fourth attempted recursive call. It still has a constant stack.
   With checked mode off, it is rejected unless explicitly unsafe.
2. A mutual pair cannot refresh its counter by switching functions. A
   branching case with maximum depth below the limit still faults if the
   two branches together exceed the call budget.
3. Another actor on the same core runs during a long guarded invocation;
   fuel refills do not postpone its recursion fault. The supervisor sees
   one `RecursionFault` and can launch a fresh actor.
4. A proved recursive function has no added recursion counter. Native
   stack protection remains in effect for a large-frame guarded function.

## Review and owner direction (26 November, later)

A read of the proposal above against the tree at `7ed74a6a` and the
decisions recorded the same day in
[v1.0 semantics](2026-11-26-V1-SEMANTICS.md). The idea stands: scheduler
fuel keeps other actors running but never stops a runaway invocation, and a
per-invocation count that fails the actor cleanly fills that gap. The
accounting rules above (one counter shared by branches and mutual members,
no refund, no reset on re-entry, charges kept on the original edges through
lowering) are kept as written.

### Owner direction: by layer, switched in the project file

Decided in outline by the owner on 26 November, following the same shape as
the preconditions decision (semantics §7):

- **Base checks unproved recursion automatically, by default; ExtBase and
  Sol follow Base.**
- **Builtin and bounded units have it off by default:** unproved
  recursion there needs a proof or the existing `unsafe` marker, as today.
- **Any profile can turn it on in the project's `fpr.toml`.**

This answers "what is checked mode": it is the profile's default, changed
per project. The section and key names in `fpr.toml` are not chosen.

What this direction still has to settle:

1. **A default limit now has to exist.** "Automatically" means a function
   with no stated limit gets one, and the proposal above left a default out
   of its first slice. A fixed number is an arbitrary bound
   ([BOUNDS](2026-09-19-BOUNDS.md) admits limits from fundamentals only).
   Candidates: a limit derived from something real (the stack ceiling
   divided by the frame size bounds depth, not calls); a per-project number
   in `fpr.toml` with no built-in default, so "on" always names its limit;
   or a per-function limit in the signature that the project default only
   backs up.
2. **The project file is outside the module hash.** The same source, with
   the same hash, would fault under one project and be rejected (or run
   unbounded under `unsafe`) under another. For a committed module the
   setting it was checked under has to be recorded with the commit, or a
   committed module has to carry its limits in its own source. Which, is
   open. A per-signature limit in the source (below) is covered by the hash
   and does not have this problem.
3. **Turning it on in Builtin or a bounded unit** puts a fault path and a
   counter in code whose bounds are meant to be proved. Either the switch is
   refused there, as an unproved precondition is (semantics §7 rule 3), or
   the fault and its cost are stated as part of that unit's bound.
4. **Turning it off in Base** must not silently drop guards: code that
   compiled only because the check was on then needs `unsafe` or a proof, as
   the proposal already says for "checked mode off".

### Points the proposal needs

- **The form of a limit.** A bare constant per function is an arbitrary
  bound. A limit written as an expression of the arguments, in the bound
  syntax signatures already parse (`| work f <= …`, `alloc`, `live`,
  `size`), would make the budget a run-time-checked declared bound, and
  give the compiler something to prove away later.
- **What callers owe.** Today a caller of an `unsafe` function needs the
  marker too. The proposal says a budget replaces `unsafe` "for that
  recursion only" and does not say whether callers are tainted. That decides
  what "safe" means: "terminates", or "terminates or faults". It is the open
  clause in semantics §6, together with `fpr stdcheck` using a different
  rule from an ordinary compile.
- **Callbacks.** Re-entry through a callback is refused, which excludes the
  commonest tree recursion (`size (Node kids) = sum (map size kids)`). State
  how much existing code the first slice covers, measured over `std/`,
  `examples/` and the app repositories.
- **Server loops.** A hand-written recursive receive loop is unproved
  recursion that must never be budgeted: it is meant to run forever. With
  the check on by default in Base, such a loop would be killed after its
  limit. Either it is written with `Sys.loop`, or it keeps `unsafe`, and
  the automatic check must not apply to it. How the compiler tells a server
  loop from a runaway is not stated.
- **Calls, not depth.** Counting calls makes the author estimate total work
  for branching recursion; a depth limit is the natural guard for the stack.
  Say why calls were chosen, or offer both.
- **The typed exit reason is new runtime work.** Exit reasons are C strings
  today (`fpr_actor_fail(const char *why)`), and `std/supervisor`'s monitor
  forwards them to its owner as an ordinary mailbox message
  (`Exited actor reason`, sent with `sendSure`). "A typed `RecursionFault`,
  visible even when the supervisor's mailbox is full" changes the runtime's
  exit reporting and the supervisor library. List both as work, and say
  what the reason looks like to code that reads the string form
  (`"dead actor: …"`).
- **Cleanup on fault** is inherited, not solved: a fault in the middle of
  an invocation leaves file handles open and owes nothing to the linearity
  check, like any trap today (semantics §7, the open resources clause).
- **Cost.** A decrement and a branch on every recursive edge of unproved
  code. Say where the counter lives and what slowdown is accepted; with the
  check on by default in Base, this lands on every unproved recursion in
  every application.
- **The main actor.** Exhaustion in the root actor is "specified
  separately" above, and it is the first case anyone will meet. Today a trap
  in the main actor prints the panic and exits 1.

Not rechecked here: the probe in the first section (a tail-recursive
spinner letting another actor on the same core run). It is consistent with
the fuel checks visible in generated code.

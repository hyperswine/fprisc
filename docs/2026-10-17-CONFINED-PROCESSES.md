# Confined processes: a program that cannot hurt the machine

Date: 2026-10-17. Kind: design and implementation record.

QOS's Editor runs a program a user has just typed as a process of its own
(`Sys.spawnApp`). Until now, such a process could stop the whole machine:

- Recursing without end took its stack to the 1 GiB ceiling, then panicked.
- Allocating without end never met the buddy's end on a host. The arena is
  reserved address space, so it met the host's OOM killer instead.
- `kill 5` panicked the machine, because an actor handle is typed `Int`.
- Its devices were the system's.
- A stop ended only its root actor.

The runtime now gives a launcher what it needs to start such a program
safely.

## The surface

```
Sys.confine : (pid : Int | pid > 0) -> (budget : Int | budget > 0) -> Result String String .
Sys.killPid : (pid : Int | pid > 0) -> String -> Int .
```

Both are declared where they are used, as body-less signatures; the
refinement makes a caller show that the pid is not the system's.

`Sys.confine pid budget` confines a process its caller started, before that
process runs a line:

- **A memory budget.** Every heap slab, stack and message slab its actors take is
  charged to the process. The block's buddy header carries a tag naming its
  record (`buddy.c`), and the bytes are handed back when the block goes home,
  whoever frees it.
- **The process ends whole.** A take past the budget is refused. Every actor of
  the process dies with one reason, for example "memory: this program's budget
  of 8 MiB is used up (stack overflow -- no memory to grow the actor's stack by
  8191 KiB)". The launcher reads that reason off the root. The machine runs on.
- **Capabilities are refused.** A confined process may not:
  - start processes (`Sys.spawnApp`);
  - install, bind or reach the machine's singletons (`Sys.irqInstall`,
    `irqRouter`, `irqOpen`, `irqDeliver`, `irqAck`, `timerBind`, `timerArm`,
    `logInstall`, `logStaged`);
  - change the module registry (`Mod.detachLast`);
  - kill an actor outside itself;
  - confine or end others.

  The platform refuses it its devices the same way, through
  `fpr_actor_confined()` (QOS: `qos/appside/hal.c`). Using any of these ends
  the program whole, with the capability named: "Sys.spawnApp (starting a
  program) is not granted to a confined program".
- **It holds no system actor.** An actor handle cannot be forged (it is a
  pointer, and an Int is never taken for one), so a process reaches only the
  actors it was given, and the ones a primitive hands out. `Sys.irqRouter` is
  refused. `Sys.logger` shows it a log actor that has ended (`ended_acb`, never
  scheduled), so the prelude's `log` takes C's way: the line is staged for the
  system log and echoed on the program's own console. Until now a program
  that logged before any logger existed was ended at the refused
  `Sys.logInstall`.

`Sys.killPid pid why` ends any process whole, confined or not:

- every actor of it, each with `why` (a reason of its own stands);
- nothing spawned into it afterwards (`spawn_gate`);
- the answer is how many actors it ended.

It sweeps until a sweep finds nothing left, yielding between sweeps so that
an actor killed while running reaches its safepoint.

## Failing the program, not the machine

These conditions used to be machine panics. They now end the ACTOR, or the
whole process when it is confined, and still panic on actor 0, the program
itself:

- a stack that reaches its ceiling or cannot get a segment (`actors.c`);
- a heap slab the buddy cannot give;
- a message slab;
- a scratch arena's buckets;
- a spawn's stack.

Each of these sites holds no lock and runs on the actor's own stack, inside
its headroom. A guard-page hit stays fatal: C code running past its stack may
hold any spinlock. So does a full ARC table, which is reached under
`arc_lock`.

An actor handle that is not an actor (`kill 5`, `send 5 x`, `Sys.pidOf 7`, a
receive from a non-actor) is now a trap: the program's mistake, not the
machine's.

So is a primitive given a value of the wrong type:

- a string primitive given something that is not a String (`strlen`,
  `charAt`, `substr`, `strcat`, `strJoin`, `String.len`, `Sys.logStage`), or
  `chr` something that is not an Int;
- an Int applied as a function;
- a spawn of something that is not a function, or a ring size out of range;
- `Sys.sleepUs` and the `Mod` lookups given the wrong type;
- `error` with a reason that is not a String.

Only a receive (`receive`, `receiveFrom` and the rest of the family), whose
result has any type, can make such a value, and a message of the wrong shape
is how. Each of these was a machine panic; it now
ends the actor. A wrong-typed value that reaches compiled code (a `case` on an
Int, a field of the wrong kind) is not checked and can still fault.

## Two fixes found on the way

- **A failure after a kill panicked.** A kill of an actor running on another
  hart is advisory until that actor's next safepoint. If the actor failed in
  that window (a trap, a refused take), `fpr_actor_fail` found itself already
  dead and panicked: "a failed actor resumed". A whole-process kill makes the
  window common. The failure is now that safepoint: it switches away.
- **A heap nil spun `Sys.loop`.** Another process's nil, copied with a message
  (its image's statics are foreign to the receiver), and the nil some
  primitives build, are list cells on the heap. `Sys.loop`'s escape check
  (`has_vec`) followed such a nil as a list again, onto itself, for ever. A host
  that collected an app's messages in a receive loop hung on the first one. The
  copier and the size walk already had this fix.

## Accounting, precisely

- **Records** are immortal, like acbs, because a block freed at any later time
  may name one. A record is reused once its process has no actor left
  (`PID_DONE`, at reap) and every block charged to it is home.
- **Charges** are made at the take (`fpr_charge`), against the current actor's
  record. The ARC table (site 5) and the shared spare slab (site 2) are the
  machine's, whoever grew them, and are never charged.
- **A charged block** freed through `buddy_realloc`'s alloc-and-copy path loses
  its charge, and an uncharge never goes below zero. No pool reallocates a
  charged block today.
- **Budgets need an image that owns its buddy** (`fpr_mem_own`: a machine boot,
  QOS Portable's app). A loaded process on the shared plane is refused,
  honestly: "this image does not own its memory".

## Checks

- `tests/confine.fpr` (`check_base`):
  - a heap hog and a runaway recursion each end with their budget reason;
  - a confined `Sys.spawnApp` is refused, named, and so is `Sys.irqRouter`;
  - a confined program's `log` line is echoed, and the program finishes;
  - `strlen` of an Int, received as a message, ends that actor only;
  - `Sys.killPid` ends five actors at once, the root hears the reason, and a
    second kill finds nothing.
- `tests/heapnil.fpr` (`check_base`): a loop state holding a heap-nil list
  turns and ends. Without the fix it hangs.
- QOS `tests/runprog.fpr` covers the same confinements in a real launcher, on
  1 and 4 harts.
- The fprisc suites pass with these changes: `check_machine`, `check_arc`,
  `check_raw`, `check_cases`, `check_profiles`, `check_builtin`, `check_export`
  and `check_base`. In `check_base`, `check_specialization` needs
  `cabal exec runghc`, which failed on this machine on dependency resolution,
  an environment problem; every step after it passes.

## Not done

- **A guard-page hit is still fatal.** Recovering would need the signal handler
  to know which locks the faulting C code held.
- **Native QOS.** The plane's routed processes fail through the kernel's
  `fpr_actor_fail` as before; budgets there need the kernel's accounting.
- **Handles are still `Int`.** Every primitive refuses a non-actor now, but a
  typed `Actor` would let the compiler do it.
- **Messages are untyped.** A receiver trusts the shape of what it is sent.
  Across a trust boundary (a launcher and its program), only a typed or
  text-only channel would make that safe.

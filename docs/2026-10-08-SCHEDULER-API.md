# A scheduler API in plain words: the design for the next step

Kind: proposal, 2026-10-08, after `2026-10-08-PLANE-TABLES.md`. Nothing
here is built. It answers the question that page leaves open: what does
the actors table look like when it stops speaking tagged values, so that
a program in any language can link it?

## The split, restated

| Layer | Owns | Speaks |
| --- | --- | --- |
| The Base profile (this repository, `runtime/`) | what an actor IS: `spawn`, `send`, `receive` in its forms, `kill`, mailboxes (Static/Dynamic, order, refusal), message ownership (copy, share, move), death as an answer | `V` |
| The scheduler (QOS, or this repository's reference implementation for bare-metal and posix) | the control block, per-hart queues, stealing, park and unpark, sleep, kill marking, reaping, pids | words and owned blocks |

Everything in `fpr_plane_memory_t` is a third layer (the memory plane)
and is not treated here.

## What the mailbox needs from the scheduler

Reading `actors.c` with section 2 of `2026-10-07-STATES.md` beside it, the
mailbox uses exactly these scheduler facts:

1. **A current control block** on this hart (`h->current`), and its
   identity as a word (the sender key).
2. **A parkable state word** with CAS from `READY` to `BLOCKED` and back:
   `block_unless` (the receiver) and `wake` (a sender) are a Dekker pair
   over it, with a full fence between the push and the flag read.
3. **Ship**: hand a woken control block to its owner hart's queue.
4. **A liveness read**: `var == DEAD`, so a send to a dead actor is an
   answer and a `receiveFromRes` can watch a peer.
5. **Watchers**: park on a peer's death and be woken by it.
6. **A reap hook**: run the mailbox's drain on the owner hart when the
   control block is reclaimed, never on the dying stack.
7. **A pid** per control block, for cross-process copies.
8. **Spawn** with placement (hart, pinned or not), a pid, an entry, and a
   stack; admission (`spawnHeap`) as a transaction over the pieces.
9. **Preemption and yield**: the fuel trap and a requeue.
10. **Sleep** with a deadline, cancelled by a wake.

Nothing in that list is a tagged value. The ring, the slots, the copy,
the ARC table and the parked drops are all above the line.

## The API, as a C header sketch

```c
/* fpr_sched.h -- the scheduler contract.  Words and owned blocks only. */
typedef struct fpr_cb fpr_cb_t;        /* a control block; opaque */
typedef unsigned long fpr_word;

#define FPR_SCHED_ABI 1u
typedef struct fpr_sched {
  fpr_word abi;
  /* identity and state */
  fpr_cb_t *(*current)(void);                       /* this hart's running block, or 0 */
  fpr_word  (*id)(fpr_cb_t *);                      /* never reused */
  fpr_word  (*pid)(fpr_cb_t *);
  int       (*is_dead)(fpr_cb_t *);                 /* acquire read of the state word */
  /* the park/unpark pair (Deciding -> Waiting / Woken in STATES.md) */
  int  (*park_unless)(fpr_cb_t *me, int (*ready)(void *), void *arg, fpr_word wait_kind, fpr_word wait_arg);
  int  (*wake)(fpr_cb_t *);                         /* CAS BLOCKED -> READY and ship; 0 if not parked */
  /* lifecycle */
  fpr_cb_t *(*spawn)(const fpr_spawn_t *);          /* entry, arg, stack bytes, hart or -1, pinned, pid or inherit, cleanup hook */
  int  (*admit)(fpr_admission_t *);                 /* reserve every piece or none; rollback is the scheduler's */
  void (*kill)(fpr_cb_t *);                         /* advisory for a running block; lands at its next switch */
  int  (*watch)(fpr_cb_t *me, fpr_cb_t *peer);      /* wake me when peer dies */
  void (*on_reap)(fpr_cb_t *, void (*fn)(fpr_cb_t *, void *), void *arg); /* the mailbox's drain */
  /* time and preemption */
  void (*yield)(void);
  void (*sleep_us)(fpr_word);
  void (*fail)(const char *why);                    /* fail-stop the current block */
} fpr_sched_t;
```

Two things to notice. First, `send` and `receive` are not in it: they are
the mailbox, built from `current`, `park_unless`, `wake`, `is_dead` and
`on_reap`. Second, the message payload never crosses this boundary at
all: the ring lives in memory the mailbox owns, and a message is a
pointer the receiver reads. The scheduler never sees it.

## What this costs, and the decisions it forces

- **The channel block moves above the line.** Today `a->ch` is a field of
  the acb and `reap` knows about it. With the API, the mailbox registers
  its drain through `on_reap` and keeps the block in its own table keyed
  by `id`. The epoch-deferred limbo (section 1, Reaped) is then the
  mailbox's own reuse rule; it needs one more scheduler fact, "every hart
  has passed a quiescent point twice", which belongs in the API as
  `(*epoch)(hart)` or a `quiescent_since(stamp)` test.
- **Watchers become a list, not a slot.** The acb's single `watch` field
  is already named as the obstacle to monitors (SUPERVISION S3). The API
  should promise N watchers per block from the start.
- **Two implementations.** The reference stays in `runtime/actors.c`
  for bare-metal and posix; the QOS kernel exports the same struct. The
  mailbox test suite (`tests/mailbox.fpr`, `tests/base/deadmail.fpr`,
  `Q/tools/mailbox-process-check.sh`) runs against both. No new test is
  needed to start; the existing ones become the conformance suite.
- **Linear send maps directly**; ordinary `send` copies into a block the
  mailbox owns before any scheduler call, as it does now. Nothing changes
  in cost.
- **Other languages.** A C program gets `spawn`, `park_unless`, `wake`,
  `kill`, `watch`: enough to build its own queues. It does not get FP-RISC
  mailboxes unless it links the FP-RISC runtime, and that is correct: the
  mailbox is the language.

## Order of work

1. Introduce `fpr_cb_t` as a typedef of `acb_t` and the header above as a
   second view of `actors.c`, implemented by the functions that exist.
   No behaviour change; the process table (`fpr_plane_actors_t`) is
   re-expressed as the mailbox calling this API on the kernel's copy.
2. Move the channel block out of the acb behind `on_reap` and the epoch
   test. `tests/base/deadmail.fpr` is the gate.
3. Replace the single watcher with a list. SUPERVISION S3 (monitors)
   becomes possible.
4. Only then let QOS own `fpr_sched_t`'s implementation file, and move it.

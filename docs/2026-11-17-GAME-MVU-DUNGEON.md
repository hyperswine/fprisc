# Game MVU: the pure interface, a QOS runner, and Dungeon on it

Date: 17 November 2026. Kind: implementation record for the
[game MVU proposal](2026-11-12-GAME-MVU.md) and its two consumers, Dungeon and Terra II.

## What exists now

**`std/game.fpr`** (FP-RISC). A game is four pure functions over its own Model and Msg:

```text
init   : flags -> (model, Game.Cmd msg)
update : msg -> model -> (model, Game.Cmd msg)
subs   : model -> List (Game.Sub msg)
view   : model -> Game.Element
```

- `Cmd`: `none`, `batch`, `log`, `sound name variation`, `capture`, `quit`.
- `Sub`: `tick ms msg`, `keys decode`, `wheel decode`; a decoder answers `Option msg`, so a key can
  be nobody's.
- `Element`: `layers world overlay`, the scene and the layer over it.
- The pure core a runner uses: `start`, `step` (one input, one transition, its effects flat and in
  order), `view`, `subscriptions`, `period`/`periods`, `wantsKeys`.
- `Game.play app flags inputs`: a runner with no platform. It feeds `Key`, `Scroll` and `Elapsed`
  inputs through the game's own subscriptions and answers the last model and every effect, and it
  stops at the transition that asks to quit. This is the headless interpreter of the proposal.

The module passes `fpr stdcheck` (every recursion has a measure) and has a golden test
(`tests/std/game.fpr`): two keys bound to one message, an unknown key, effects once and in order, a
capture per request, a quit that ends the run, a tick subscription that stops with the model.

**`programs/mods/gamerun.fpr`** (QOS). `Run.run config app` opens the graphics session, maps the
frame loop's events to `Game` inputs, performs each transition's effects once (a log line is
printed, a sound goes to `config.sound`, a capture bumps the counter the renderer watches, quit
ends the loop), draws `view`, closes the session. It sits on the existing `std/mvu` frame loop; the
game never sees an actor, an endpoint or the environment pair.

**Dungeon** (branch `game-mvu` of its repository).
- The rules take **actions** (`Move d`, `Interact`, `UseSlot i`, `Restart`, `Help`, `Capture`,
  `Quit`, `Other`); `decode` is the key map, where W and the up arrow are the same `Move`. `key` is
  kept as `act m (decode k)`, so the upstream rule suite still folds key codes and passes unchanged.
- `src/mods/dungeongame.fpr` holds `init`, `update` and `subs`, importing no QOS module. `update` only
  queues an action; the tick takes one action a tick, as before. What it used to do in place it now
  asks for: a `log` when the recorded message changes (and the win or death line), a `capture` when
  the capture count moved, `quit` once.
- `src/dungeon.fpr` is the view (scene and HUD, unchanged) and one line of `Run.run`.

## Acceptance (the Dungeon note's step 4)

- The upstream rule suite passes.
- `tests/game.fpr`, in a plain process with no window, actor or device: a key is only queued until
  a tick; W and D equal the arrows; two keys inside one tick are two turns, one a tick, and end in
  the same state as keys pressed a tick apart; a changed message is announced once however many
  ticks follow; one capture per request; quit is asked for once and nothing after it is taken; a
  400-key session ends with an empty queue and a transcript whose last line matches the model.
- The graphical check (title, start, movement, three captures, clean quit) passes against an SDK
  staged from QOS `87600ff` and FP-RISC `main`.
- Two minutes of scripted play (`tests/bench/e2e/game.sol`): 57.0 frames a second, 11.7 M
  instructions a frame, 98 to 99 MB: the same as before the migration on the same SDK.

## Later the same day: tasks, music, and Terra II

**Tasks.** `Game.attempt task toMsg` asks for fallible work and names the message its
`Result String String` becomes. The tasks are storage, a log of records per name: `replay`,
`readLatest`, `append`. `Game.apply app msg model` delivers a message directly: it is how a runner
hands a result over, and how a test holds a completion back, reorders it or invents one.
`Game.playWith answer` answers tasks in order after each transition; `Game.play` answers every
task `Err Game.noStorage`, which is also what the QOS runner answers when `config.storage` is off.
`Game.music name volume` joins the commands. The QOS runner performs tasks through the Files
service, synchronously, where the task stood among the transition's effects.

**Terra II** (branch `game-mvu`).
- `src/game.fpr`: `init`, `update`, `subs` over the model, no platform call. The rules and input
  handlers already queued their words and sound cues on the model; the tick that ran them now asks
  for them as `log` and `sound` commands. The six in-place music calls queue a volume the same way.
  A capture and quit are asked for at the transitions that used to perform them.
- **Loading** is two tasks from `init`; the profile and the saved game arrive as messages. No disk,
  an empty profile and a saved game are told apart, and a saved game that arrives after a game was
  started does not replace it.
- **Saves are acknowledged.** Records wait in order, each with an identity, one in flight; only its
  acknowledgement removes it, and "game saved" is announced then, not when it was asked for. A
  failed snapshot is kept and sent again after a rest. A profile event whose reply was lost is not
  sent again (it would count a game twice): the profile is read back first, and the record is
  acknowledged if its line is there. An answer for another identity is ignored.
- `src/terra2.fpr` is the view and `Run.run` with the meshes, the cue player and storage on.

Acceptance:
- A fixed 34-key session through the real window gives the **same 54-line transcript** before and
  after the migration (and twice in a row before).
- Two launches on one disk: the second reports the profile, finds the saved game and continues it.
- `tests/headless` (a small app project run by the SDK's host with no display): 23 assertions. A
  match with a disk and without plays the same game; nothing is announced as saved without a disk;
  cues are asked for once however many idle ticks follow; a record made while a write is in
  flight waits behind it; a stale answer changes nothing; an unconfirmed profile event is read
  back and never re-sent blindly; a failed snapshot is kept, rests and goes out again; a late
  saved game does not overwrite a new one.
- The game's own graphical check passes with the headless run added to it.

**A compiler defect found on the way.** A cold compile of Terra II took more than nine minutes with
the current compiler, before or after the migration (the SDK's per-project unit cache had been
hiding it). The region placement computes a cost equation per function, a caller substitutes its
callees' equations whole, and the simplifier sorts and compares those trees. Two changes in
`compiler/Cost.hs`: a max's arms are made distinct through a set instead of `nub . sort`, and a
function whose equation passes 4,096 nodes becomes opaque, as an unmeasured recursion already is
(never an understatement). The bound is applied per component and only when a component is read, so programs that never read an equation whole pay nothing (the compile budget is unchanged). Cold compile: over nine minutes to 35 seconds. The migrated Terra II plays as before: 57.9 frames a second, 16.9 M instructions a frame, 124 MB after three minutes. The compile-budget gate
did not see this: its three programs are too small. `codegenRev` 242.

## Not done

- **Replaceable computation tasks** (`Task.latest`): Dungeon's navigation field and Terra II's
  tactical hint, the second half of each game's note.
- **Asynchronous storage.** The QOS runner performs a task inside the frame that asked; a slow
  disk is a slow frame. The game's side is already written for late answers.
- **Terra II's failure paths on a real disk.** They are exercised by injected answers only.
- **A purity check.** Nothing stops a `print` inside `view`; purity is a convention, as the
  proposal says it would be until a check exists.
- **One tick period.** The QOS runner refuses a model whose tick subscriptions name different
  periods, because the frame loop has one clock for update.
- **No release.** The games on `game-mvu` need an SDK newer than 0.3.0; the QOS pin is still
  FP-RISC 0.14.0, so the runner and `std/game` ship only once the pin moves.

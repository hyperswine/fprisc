# Game MVU: the pure interface, a QOS runner, and Dungeon on it

Date: 17 November 2026. Kind: implementation record for steps 1 and 2 of the
[game MVU proposal](2026-11-12-GAME-MVU.md) and its first consumer. Terra II is not migrated.

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

## Not done

- **Terra II.** It builds against the new SDK (its boot code was updated), but it is not migrated.
  Its update path performs effects in place: about forty sound, music and print calls in the input
  and action code, save appends through the Files client it holds in `env`, and a profile and
  saved game read synchronously at init. Its note's steps 3 and 4 need what is not built yet:
- **Tasks.** `Game.Cmd` has no fallible work with a result message (`attempt`), no
  `Task.latest`, and `Game.play` cannot be handed a task completion. Storage with acknowledged
  saves and the replaceable computation tasks depend on this.
- **Dungeon's navigation field as a task** (the second half of its note).
- **A purity check.** Nothing stops a `print` inside `view`; purity is a convention, as the
  proposal says it would be until a check exists.
- **One tick period.** The QOS runner refuses a model whose tick subscriptions name different
  periods, because the frame loop has one clock for update.
- **No release.** The games on `game-mvu` need an SDK newer than 0.3.0; the QOS pin is still
  FP-RISC 0.14.0, so the runner and `std/game` ship only once the pin moves.

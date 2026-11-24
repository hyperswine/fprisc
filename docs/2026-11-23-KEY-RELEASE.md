# Key releases reach a game

Date: 23 November 2026. Kind: implementation record. Applies to `std/mvu.fpr`
and `std/game.fpr` at `476724f7`.

## What was missing

A real-time game needs held state: walk while the arrow is down, stop when it
is let go. The input tier already had the fact — the graphics poll answers
`(kind, a, b)` with kind 4 and `b` the evdev value, 1 press, 0 release, 2
autorepeat — but `std/mvu`'s drain kept only `b == 1`:

```text
drainEvRes me inp n acc 4 a b = drainRes me inp (n - 1) (if b == 1 then EKey a :: acc else acc).
```

so a game could not tell a held key from a tapped one, and the only ways to
build one were to guess from autorepeat timing or to make the game turn-based
(Dungeon, Terra II are).

## What changed

`std/mvu.fpr`

- `Ev` gains `EKeyUp Int`: a release is its own event, so every existing
  `case ev of` keeps its meaning and its `other ->` arm. `copyEv` copies it.
- `drainEvRes` (frame path), `inputEvent` (deadline path) and `drainKey` give
  `EKey` for `b == 1`, `EKeyUp` for `b == 0`, and nothing for `b == 2`. An
  autorepeat is neither a press nor a release: delivering it as a press would
  make a held key look like a new one, which is exactly the ambiguity this
  change removes.
- The header states the model: a held key is model state, and what a game has
  heard as `EKey` it has not yet heard as `EKeyUp`.

`std/game.fpr`

- `Input` gains `KeyUp code`; `Sub` gains `KeysUp decode`. `taken` routes
  presses to `Keys` decoders and releases to `KeysUp` decoders, so a decoder
  still has the shape `code -> Option msg` and a game decides for itself
  whether a release means anything.
- `wantsKeys` is true for either subscription: it answers "turn the input
  drain on", and the drain carries both.

## The runner

A runner turns `EKey` into `Game.Key` and `EKeyUp` into `Game.KeyUp`; QOS
`programs/mods/gamerun.fpr` does that in its `input` function. Nothing else in
either repository pattern-matches `Ev` exhaustively without a fallback, so the
addition is visible only where it is used.

## What it costs and what it does not do

- No new allocation: `EKeyUp` carries an `Int`, as `EKey` does.
- Autorepeat is dropped, not synthesized: a game that wants "repeat while
  held" counts its own ticks.
- A release for a key the runner never saw pressed is delivered as it arrives;
  the game's decoder decides what an unmatched release means (the golden test
  clamps a count at zero).
- Focus loss does not produce releases for keys still down. A game that cares
  (a pause on focus change) needs an `EWheel`-like event for it; this change
  does not invent one.

## Verification

- `tests/std/game.fpr` gains "press then release" (two presses, one release, an
  unbound release: `held=1`) and "a release alone" (`held=0`).
- `tests/base/mvueventports.fpr` and `tests/base/mvuscoped.fpr` still pass, and
  `make stdcheck` is OK.
- The first consumer is the 2.5D platformer port (`newstorygame`), whose headless
  test drives movement from presses and releases.

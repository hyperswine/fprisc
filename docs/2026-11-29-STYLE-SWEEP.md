# Style sweep: Sys.loop owners, Bool cases as `if` (29 November 2026)

Kind: delivery record. Branch `refactor/style-sweep` in fprisc, qos, terra-ii, dungeon,
qos-guishell and newstorygame (local only). Behaviour-preserving; nothing merged.

## fprisc

**Receive loops on `Sys.loop`.** Four owners recursed by hand, one message (or batch) per
call. Each is now a turn function returning `(continue, state)` under `Sys.loop`, which
runs every turn in one arena and keeps only the next state:

| Owner | Was | Now |
|---|---|---|
| `std/journal` | `serve` recursing | `serve` = `Sys.loop sink (ownerTurn self p)`; `Close` ends the loop |
| `std/kvlog` | `serveLog` recursing, typed `-> a` | `Sys.loop (st, lost) (logTurn self)` |
| `std/store` front | `front` + `A.tidy` (copy when the heap doubled) | `Sys.loop st (frontTurn self)` |
| `std/store` shard | `shard` + `A.tidy` | `Sys.loop st (shardTurn self cfg)` |

None of the states hold a Vector (`Sys.loop` refuses one), so no owner needed `loopWith`.
The store no longer uses `A.tidy`; the turn arena replaces it. `Sys.loop` copies the
state at every turn boundary. Generational retention avoids copying unchanged immutable
parts again, but a large kvlog or shard map costs more per turn than the old amortised
tidy. If a store benchmark regresses, look here first.

The journal's step is not named `serveTurn`, because `core/prelude.fpr:764-768` defines
both `serve` and `serveTurn`. Run `fpr check` on its own against a module that defines
either name at top level (std/journal, qos fprlive) and it unifies the module's
definition with the prelude's signature. On main it reports "declared type of serve:
cannot unify ...". Builds of programs that import the module are not affected. This
looks like a checker name leak. It is recorded here and not fixed.

**Bool `case` to `if`** in std and examples is a follow-up on this branch (std/store's `drain` is converted here).

**Already done on main.** `tools/sol-bundle-archive.sol` and `sol-bundle-activate.sol`
already run `Proc.streamNow` under `>!`. Both run correctly with the branch's Sol.
`tools/build-static-arena.sol`'s `writeNow` was already renamed `writeStreamed` (7902bea1).

## Other repositories (same branch name)

- qos: `programs/mods/fprlive` (register, acceptor and connection actors) and
  `programs/mods/arcsvc` run on `Sys.loop`. fprlive's three self-send `boundary*`
  functions are gone. arcsvc now passes `fpr check`: before, its loop made `Arc.start`
  unsafe. Bool cases became `if` in `scene2d` and others. `qlog` was not touched: other
  modules pin it by hash (v26.0), and constructor tags are per module version.
- terra-ii, newstorygame, dungeon, qos-guishell: Bool cases as `if`, `unsafe module.`
  headers removed (a few kept, see each commit), and prelude aliases replaced by std.
  The key codes were left alone because SDK 0.6.1 ships no `std/keys`.

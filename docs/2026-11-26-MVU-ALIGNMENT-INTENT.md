# MVU alignment: review findings and intent (26 November)

Kind: review findings and statement of intent. Nothing here is implemented
yet. Code references are to fprisc `main` at `dcd3db0f`, qos `main` at
`988d7296` and grapher `main` at `2f2b3caa` unless stated. The QOS side has a
pointer page, `qos/docs/2026-11-26-MVU-ALIGNMENT-INTENT.md`, which links here.

## What was reviewed

On 26 November Jack moved several apps toward the MVU style:

- fprisc `dcd3db0f`: named evdev key constants in `std/game.fpr:109-118`.
- grapher `2f2b3caa`: `desktop/main.fpr` returns `[D.Log …]` commands
  instead of calling `print` in `update`, and matches keys by name.
- qos `02c57bb3`: a shared `AS.run me init update view` loop
  (`programs/mods/appsession.fpr:108-137`) used by browser, clock, disk and
  logs; `Log String` in `D.Cmd` with `performLogs`
  (`sdk/qos/desktop.fpr:9,48-53`), performed by the generated adapter
  (`tools/desktop-adapter.fpr.in:8`); key constants in `appwire.fpr` and
  `sdk/qos/desktop.fpr`.
- qos `988d7296`: modifier helpers `shift`, `ctrl`, `ctrlShift`, `alt`
  (`appwire.fpr:26-31`) and named keys in editapp and termapp.

Every key mapping was checked against the old literals, including the 26
editor ctrl/alt codes, and they are identical. The six qos apps type-check
against fprisc `dcd3db0f`, and qos CI on `988d7296` is green. Logs as
commands matches `std/game`'s `Log` and `std/mvu`'s `MLog`.

## Findings

1. **grapher's desktop app does not build on the released SDK.** grapher's
   README says it builds with only the installed SDK, but `desktop-v0.6.0`
   has neither `D.Log` nor `D.key*`. Type-checking the generated adapter
   against the `desktop-v0.6.0` SDK fails with `unbound name: Log`,
   `keySpace`, `key1`, …; against qos `main` it passes.
2. **Named keys from another module are not zero-cost.** The compiler does
   not fold a nullary `Int` definition from another module, or a constant
   call such as `ctrl keyC`, into the dispatch. Measured below.
3. **The key constants exist three times and have drifted.**
   `std/game.fpr:111`, `qos/programs/mods/appwire.fpr:32` and
   `qos/sdk/qos/desktop.fpr:12`. Only `appwire` has the modifier helpers and
   the extra keys (Y U O F J K Z X V B, brackets). terra-ii, on `std/game`,
   still matches raw codes (`src/input.fpr:37,45-46,100-102`).
4. **`AS.run` takes application callbacks.** `appsession.fpr:2` says the
   module "never accepts an application callback", as does qos
   `docs/2026-10-29-INSTALLED-DESKTOP-SDK.md:86-87`; qos
   `docs/2026-10-18-QOS-DESIGN-ALIGNMENT.md:94-96` says the trusted loop
   grants no callback a safety exemption, and `appsession` is an
   `unsafe module`. The compiler reports at `appsession.fpr:110` and `:117`:
   `remark[generic-call] callback specialization attempt for <dynamic>:
   computed callback target is not safely known`. So `update` and `view` are
   indirect calls that cannot be inlined, and the per-step work bound cannot
   see through them.
5. **Initial-resize commands are handled two ways.** `AS.run` drops them
   (`appsession.fpr:114`, `(model, ignored)`); the desktop adapter issues
   them (`desktop-adapter.fpr.in:14-16`). `AS.run` also requires every model
   to have a `phase` field (`appsession.fpr:136`), which no type states.
6. **Effects remain in `update`.**
   - qos editapp: `print` at `:351,371,375,386,391,406,432,439,491`;
     `Sys.memTotal` at `:423`; spawns with `RP.open` at `:428`; synchronous
     policy calls at `:421,454`; `tellProg` sends at `:479`;
     `RP.pollActor` at `:444`.
   - qos termapp: `Sys.logSnap`, `Sys.uptimeMs`, `Sys.actLive`,
     `Sys.actInfo` (`:175,191-194`).
   - inventory and `examples/pos1.fpr`: `Sys.timeUs` and the journal append
     inside `update` (`inventory.fpr:336-345`, `flush` at `:309`;
     `pos1.fpr:386-397`); pos1 also writes a file (`writeStock`,
     `:345-346`).
   - The cause is in the frameworks: `std/live`'s `Cmd` is
     `After | Run | Navigate | Emit | Quit` with no typed journal append or
     clock read, and QOS has no command or subscription for process start,
     policy reads or runtime statistics. `std/game` already has the shape
     wanted (`Attempt` with `Task = Replay | ReadLatest | Append`, `Log`).

## Measurements

Key dispatch, 3,000,000 calls of an 8-key function plus a fallthrough, on
the box (Linux x86-64), with `fpr` built from `dcd3db0f`. Median of 7–9 runs
of the whole process.

| dispatch style | time |
|---|---|
| literal patterns (`f 19 x = …`) | 13.9 ms |
| guards against literals (`f k x \| k == 19 = …`) | 14.3 ms |
| guards against constants in the same module | 18.4 ms |
| guards against constants from another module | 47–53 ms |
| the same plus one `K.ctrl K.keyC` guard | 62–64 ms |

The benchmark:

```
# keys.fpr
keyR = 19. keyG = 34. keyLeft = 105. keyRight = 106. keyUp = 103. keyDown = 108. keyEnter = 28. keyC = 46.
modCtrl = 4000.
ctrl k = modCtrl + k.

# grd.fpr (lit.fpr is the same with literal patterns: f 19 x = x + 1. …)
K = use "keys".
f k x | k == K.keyR = x + 1.
f k x | k == K.keyG = x + 2.
f k x | k == K.keyLeft = x + 3.
f k x | k == K.keyRight = x + 4.
f k x | k == K.keyUp = x + 5.
f k x | k == K.keyDown = x + 6.
f k x | k == K.keyEnter = x + 7.
f k x | k == K.ctrl K.keyC = x + 8.
f k x = x.
go : (i : Int | measure (3000000 - i)) -> Int -> Int .
go i acc = if i >= 3000000 then acc else go (i + 1) (f (i % 5000) acc).
main = print "{go 0 0}".
```

```
FPR_HOME=<fprisc checkout> fpr build lit.fpr -o lit    # and grd, …
./lit; ./grd                                            # both print 21600
```

Per keypress the cost is nanoseconds, but it breaks the zero-cost rule, and
it is largest in qos editapp, where every typed character passes 26
`editKey` guards and the 24-step `navigate` chain before it is inserted.

Callback remarks:

```
fpr compile --target=qx64 --plugin --remarks=all \
  --prelude=$FPRISC/core/prelude.fpr apps/clock.fpr /tmp/clock.s 2> clock.rem
grep 'generic-call' clock.rem | grep appsession
```

with `FPR_HOME=<qos>`, `FPR_PATH=<qos>/programs:<fprisc>` and
`FPR_FOREIGN=<qos>/core/foreign.fpr`, from the qos checkout.

## Intent

### 1. grapher builds on a released SDK

Release QOS Portable SDK 0.7.0 with `D.Log` and the key constants (after
step 2 settles their home, so the SDK ships the shared names), and move
grapher's requirement to 0.7.0. Until then, grapher documents that its
desktop app needs qos `main`.

Success: grapher's `desktop/main.fpr` builds and its GUI check passes
against the installed 0.7.0 SDK, with no qos checkout present.

### 2. Zero-cost named keys

- Compiler: fold a nullary definition whose body is an integer literal, and
  a call of a known pure function on constant arguments (`ctrl keyS`), across
  `use` boundaries, so a guard `k == K.keyX` becomes the same comparison as
  `k == 19`, and a run of such guards on one scrutinee compiles like literal
  patterns.
- Library: one `std/keys` module holding the evdev codes and the modifier
  encoding (shift +1000, ctrl +4000, alt +8000) with its helpers. `std/game`,
  `std/mvu`, qos `appwire` and `sdk/qos/desktop` re-export it instead of
  carrying copies. terra-ii moves to the names.

Success: on the benchmark above, cross-module constants and the
`K.ctrl K.keyC` guard run within noise of literal patterns (about 14 ms);
the key table appears once in fprisc and nowhere in qos.

### 3. `AS.run` without callbacks

Replace `AS.run`'s `updateFn`/`viewFn` with a per-app loop the compiler
specializes, generated the way `desktop-adapter.fpr.in` already is, or
written so the callee is a known name. If a shared callback loop is kept
instead, record that as a deliberate change to the design rule in qos's
`INSTALLED-DESKTOP-SDK` and `QOS-DESIGN-ALIGNMENT` pages and fix the comment
at `appsession.fpr:2`. In both cases:

- issue the initial-resize commands in the native loop as the desktop
  adapter does, or drop them in both, and state which;
- take the status from a function the app supplies (or a stated type)
  rather than an implicit `phase` field.

Success: compiling the qos apps with `--remarks=all` shows no
`callback specialization … <dynamic>` remark in `appsession.fpr` or the
generated loop; initial-resize behaviour is the same for native and SDK
apps and covered by a test.

### 4. Typed commands, then effects out of `update`

- `std/live`: a typed journal-append command and a clock read (as a command
  result or a subscription), following `std/game`'s `Task` shape.
- QOS: commands or subscriptions for process start, run-policy and access
  policy reads, and runtime statistics (log snapshot, uptime, live actors,
  memory total).
- Then move the effects listed under finding 6 out of `update` in qos
  editapp and termapp, inventory and `examples/pos1.fpr`; prints become
  `Log` commands.

Success: those `update` functions (and what they call) contain no `print`,
`Sys.*`, `spawn`, `RP.*` or file/journal writes; existing tests pass; pos1
and inventory keep their 0.15.0 profile numbers within noise.

## Order

1 first, since it is a released app that does not build. 2 next, because
1's SDK should ship the shared key names. 3 and 4 are independent of each
other and follow; 4's library commands land before the app moves that use
them.

## Non-goals

- Unifying the four MVU surfaces (`std/mvu`, `std/game`, `std/live`, qos
  `D.*`/`AW.*`) into one event, key and log vocabulary. That was suggestion
  5 of the review and comes later, once 1-4 have landed.
- Changing app behaviour or key bindings.
- New view diffing or rendering work.

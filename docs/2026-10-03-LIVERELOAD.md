# LiveReload as an object-level message

Date: 2026-10-03. Kind: design proposal.
Implementation status, 2026-10-04: the MVU runner/event and QOS adapter slice
is implemented; see [LIVERELOAD-RUNNER](2026-10-04-LIVERELOAD-RUNNER.md) for
tested scope and remaining gates. The complete watch/attach/certificate design
below remains a proposal.
Supersedes the mechanism split described in `qos/docs/2026-08-25-VERSIONING.md`
and `std/live.fpr`'s header; builds on `docs/2026-08-27-PATHS.md` §4.

## What exists, and why it diverged

There are two mechanisms today and neither is what the language promises.

| | Where | Trigger | Effect |
|---|---|---|---|
| In-place swap | `qos/std/livereload.fpr`, `qos/std/loader.fpr`, `qos/programs/mods/plug.fpr`, `qos/qos/appside/entry.c`, `qos/qos/portable/store.c` | someone sends `LLoad id` to a loader actor; nothing watches for new versions | `Plug.attach` + `Mod.compatAt` (arity only); a `LiveReload` broadcast; each worker calls `Mod.find` again |
| Restart | `std/live.fpr` | a 300 ms stat poll of source files; a successful `rebuild` | `OS.exec` of the new binary; state replayed from the kv log; browsers reconnect |
| Rerun | `qos/qos.py dev` | 0.3 ms mtime poll | kill and rerun `fprc sol` |

Three things are wrong with this picture, and they are the things to fix:

1. **It is meta-level.** The swap is a tooling protocol (a loader actor, a
   `.qa` record on a disk, a broadcast) that an app has to know about and
   wire up itself. The language has an object-level event stream already:
   std/mvu's `Ev`. A reload is an event like a key press.
2. **Nothing connects it to `fpr commit`.** The compiler is the one thing
   that knows a new version exists and whether it is compatible. Today it
   writes `.fpr/versions.db` and stops.
3. **It is in the wrong repository.** Loading an image and rebinding calls
   is a runtime concern with one platform-specific step (map pages, bind the
   import table). QOS implements that step; so does qosp's Unix host. The
   posix runtime in fprisc has no attach path at all, so the same program is
   live on QOS and restart-only on a Mac.

The constraint that shapes everything: **only calls through a module value
can be rebound.** A static `use` is linked at build time and cannot change
under a running program. `Mod.find` returns a PAP from the newest attached
table; that is the whole rebinding mechanism. So a module that is to be live
has to be *passed down as a value*, which is exactly the MVU shape the user
wants: the runner holds the modules, hands them to `update` and `view`, and
replaces them between turns.

## The proposal

### 1. The message

std/mvu's `Ev` gains one constructor:

```
Ev = Type (ETick | EKey k | EMsg m a | EResize w h | EWheel dy dx
          | EReload { name : String, from : String, to : String, version : String }).
```

`name` is the module id (`dep`), `from`/`to` its hashes, `version` the
semver string commit minted (`v1.3`). It is a value in the program, matched
like any other event. It is **not** an actor-protocol message between tools.

### 2. Live modules are values the runner owns

```
Dep = use "dep#79d8a0d77ddf9930".      # static: linked, never changes
live Deps = { dep = use "dep", json = use "std/json" }.   # proposed syntax
```

A `live` binding makes a record of module values. Each field has the row
type of the module's exports (its record of functions), so passing it down
is ordinary row-polymorphic code: `view : { dep : { twice : Int -> Int | r } | q } -> …`.
The runner's `App` gains an `env` role carrying this record:

```
App init update subs view
  init env             -> model
  update env ev model  -> (model, List MC)
  subs model           -> List Sub
  view env model       -> scene
```

Semver is then literally row compatibility: a patch is a version whose
export row is a supertype of the old one (every old field, same written
signature; additions allowed), which is what `fpr commit` already classifies.
A major version does not reload; it restarts (below).

### 3. Default handling in the runner

The runner, not the app, swaps modules. On `EReload`:

1. attach the new image (platform step),
2. check `Mod.compatAt` against the row the program was built against,
3. rebuild `env` with the new module value in that field,
4. deliver `EReload …` to `update` with the new `env`.

An app that does not care has `_ -> (m, Nil)` and gets the new code on its
next turn. An app that cares can migrate its model or log. Because `update`
runs on one actor between frames, there is no interleaving to reason about:
turn n ran old code, turn n+1 runs new code, and the model is the only
state that crosses. If the check in step 2 fails, the runner delivers
`EReloadRefused reason` instead and keeps the old env; it never half-swaps.

What this does **not** cover, and should say so in the docs: closures
already stored in the model keep pointing at old code until the model is
rebuilt (that is correct, not a bug); nominal ADT tids are per unit version,
so a live boundary must be records, tuples and primitives (the rule
`qos/std/livereload.fpr` already states); old images are never unmapped, so
a long dev session leaks one image per reload.

### 4. The trigger: `fpr watch`

`fpr commit` stays a pure publication. A new dev command drives it:

```
fpr watch prog.fpr        # build, run, and keep it live
```

`watch` holds the program's module closure. On a source save it runs the
commit classification on the changed module:

- **compatible (patch)**: `fpr commit` it, build that module as a plugin
  image for the running target, publish `.fpr/store/<hash>.<target>.img`
  beside the source blob, append `versions.db`.
- **major**: do what `std/live.fpr` does today: rebuild the whole program
  and restart it, state through the kv log.
- **does not compile**: report, keep the old program running.

The program learns about the new version through a **subscription**, not a
tool protocol:

```
subs m = MVU.SStore :: …          # "tell me when a module I use gains a version"
```

`std/watch.fpr` implements `SStore` by watching the fpr store: on posix a
stat poll of `versions.db` (300 ms, the same loop `std/live.fpr` runs now,
or `Os.watch` once `os_watch.c` grows a directory watch); on QOS the qlog
disk's `apps/<id>` records. Both yield `EReload` events. This is the "it
could just be std.watch on the fpr db, implemented however" in the request:
the db is the contract, the watcher is per platform.

### 5. The platform step moves into the runtime

`fpr_mod_attach` exists in `runtime/mod.c` but only QOS calls it. The
missing piece on posix is the one qosp's Unix host already has in
`qos/qos/portable/host.c` (`qosp_load_plugin`): map the image's pages
executable and bind its import table. That function belongs in
`machine/posix`, with QOS's `entry.c` path as the other implementation of
the same HAL hook (`Sys.attachImage`). Then:

- `qos/std/livereload.fpr` and `qos/std/loader.fpr` are deleted; their
  checks (ABI stamp, imports, arity) become the runner's step 2 in
  `std/mvu.fpr` plus `Mod.compatAt`;
- `qos/tools/fprd.py`'s `plugin:` op becomes `fpr watch`'s build step;
- `qos.py dev` becomes `fpr watch` with the sol profile;
- the `sys/live` replay-at-boot record stays a QOS policy (which chain to
  re-attach when an image restarts), fed by the same `EReload` log.

QOS keeps what is genuinely its own: the store format on the qlog disk and
the syscall that maps pages. Everything that decides *whether* and *what*
to reload lives in fprisc.

### 6. What must be true first

- **Compatibility has to be real.** Commit compares written signatures;
  the audit's open item "commit compares inferred interfaces" stops being a
  nicety here, since a reload is an unchecked claim otherwise. With bounds
  in interfaces since yesterday, a patch also keeps every `work`/`alloc`
  bound: a reload can never make a proven budget false.
- **Record types are now signature grammar** (yesterday's fix), which the
  row-typed module records need.
- **`Mod.compatAt` checks arity only.** It should check the written
  signature hash of each export; the compiler can stamp it into the image.

## Order of work

1. `EReload` in `Ev`, `env` in `App`, runner steps 1–4 with the attach path
   stubbed on posix (QOS already attaches). Test: `qos/tests/livereload.fpr`
   rewritten as an MVU app whose `update` ignores the event and whose
   accumulator survives the swap.
2. `std/watch.fpr` with `SStore` on posix (stat poll of `versions.db`).
3. `fpr watch`: classification, plugin build, publish, restart on major.
4. Posix attach in `machine/posix` from qosp's loader; delete qos's
   `std/livereload.fpr`, `std/loader.fpr`, `tools/fprd.py`'s plugin op.
5. Signature-hash compatibility in `Mod.compatAt`; inferred-interface diff
   in commit.

Steps 1–3 give a working posix dev loop with restart-on-major and a
reload that is already correct on QOS. Step 4 is the merge the request asks
for. Step 5 is what makes "compatible" mean something.

# Paths + Live Iteration

Most application iteration — games especially — happens in **value
space**, not type space. Types form a stable skeleton; values and
implementations vary live. This document describes the shipped stack:
first-class paths (two tiers, one meaning), the MVU message port, and
the LiveReload rung — and the razor that decides where a change
belongs.

    changeable-while-running        => value space (a path-set)
    should-break-all-consumers      => type space (edit the shape, recompile)

## 1. The Path type (typed tier)

A **type-rooted literal** `@Model.field.sub` is validated
unconditionally at elaboration against the declared record shapes
(`Model = {field : ...}.`) — a typo'd field or a descent into a
non-record is a **compile error**, never a getter that can panic. It
desugars (FPRISC.expandPathLits, the first pass after module load) to
an ordinary record value

    { get  : s -> a,          -- fn s -> s.field.sub
      set  : a -> s -> s,     -- fn v s -> {s | field.sub = v}
      segs : List String }    -- ["field", "sub"], reified for the wire

at plain type `Path s a`. **No new type-system machinery**: all the
magic lives in the literal rule; everything downstream (rows, safety,
linearity, codegen, every profile) sees a user record with two
lambdas. Composition is a normal function:

    L = use "std/lens".
    fgP = L.comp (@Model.ui) (@Style.fg)     -- == @Model.ui.fg

The parser note: `@...` was already sol's file-path literal. A literal
whose first segment names a **declared shape** is a path into it;
everything else (lowercase, `/`, `~` roots) stays a file path. The two
uses cannot collide because shape names are capitalized declarations.

Any field type works in the typed tier — `@Model.notes` over a
`List String` field gets/sets the whole list. What the typed tier does
NOT have (yet): list **indices** (`model.courses[2]`) and
sum-constructor segments — those are prisms/traversals (partial), and
the design razor is that partiality must be **type-indexed**, not
smuggled into `Path`. Named future work.

## 2. The schema (string tier)

The **bare literal** `@Model` is the schema: the flattened list of
every string-addressable leaf, emitted by the same compiler pass —

    { path : String,          -- "ui.fg" (dotted, from the root)
      tag  : "int" | "str",
      get  : s -> String,     -- leaf read, RENDERED to a string
      set  : String -> s -> s -- leaf write, PARSED by tag
    } list

Leaves are `Int` and `String` fields plus nested declared shapes
(flattened recursively). Fields of any other type (lists, vectors,
actor handles...) are typed-tier-only and skipped. Both tiers are
built from the same elaboration, so a string-resolved path and a
literal path are **indistinguishable downstream** — two tiers, one
meaning. The literal resolves at compile time (zero cost); a string
pays one schema walk (`std/lens`).

`std/lens` is the runtime half:

    L.find sch "ui.fg"            -- Result entry String
    L.set  sch "ui.fg" "7" m      -- Result model String  (Err = model untouched)
    L.get  sch "ui.fg" m          -- Result String String
    L.setWords sch "ui.fg 7" m    -- the WIRE form: "path value..." (value may
                                  --   contain spaces; split at the first)
    L.dump sch m ""               -- every leaf as "path=value\n" -- the
                                  --   GENERIC INSPECTOR, no per-app code

A bad path or unparsable leaf **refuses transactionally**: `Err`,
model unchanged. There is no backdoor: the schema's set closures are
the same `{s | path = v}` updates the app itself would write.

## 3. Value-space iteration in MVU (the message port)

`std/mvu` grew the third subscription:

    Sub = STick ms | SKeys | SPort p

`port = spawn MV.port` is a mailbox proxy any actor may send
`(tag, arg)` **string pairs** to; the MVU loop drains it once per
frame and hands each pair to `update` as `EMsg tag arg` — the same
arm the LiveView driver feeds browser events through. So a debug
path-set is an **ordinary message to the Model actor**:

  * the model actor stays the **single writer** — sets are applied by
    `update`, transactionally, log-refused when invalid;
  * one sender's messages arrive in order (per-sender FIFO);
  * every step is atomic: a message lands **between** MVU steps, never
    inside one.

Design your model so variance points are **data**: tuning constants,
kinds as stat records, caps and modes as fields — one addressable
subtree, editable over the wire while the app runs. (tests/pathnotes
sets a nested `ui.tag`, retunes `cap` live, and walks the whole model
with the inspector — zero inspector code in the app.)

## 4. LiveReload (signature-stable module swap)

The next rung up: types stay the same, the **implementation** varies.
Composes std.livereload (see its header for the reload-safety rules)
with the port:

  * a `("swap", "<id>")` message makes `update` call `LR.load` — the
    commit-time signature gate (Mod.compatAt) means a compatible
    version swaps and an arity-drifted impostor is **refused with the
    old binding intact**, checked, not conventional;
  * the app resolves the function **at each use** (`LR.bind` is a
    registry walk, newest attachment wins) and stores data + the
    module's *name* in the model, **never the closure** — a stored
    closure silently pins its old version;
  * because the swap is an ordinary state transition, the live
    version's name is a **value in the Model** (`ver`), so any replay
    or history mechanism knows which code was live at each step.

tests/pathnotes is the reference composition: the notes EDIT function
is swapped mid-run from "append a newline" (v1) to "capitalize the
first letter" (v2) — same signature, same actor, same accumulated
notes — and the arity-changed v3 bounces off the gate.

## 5. The ladder (priced tiers)

    path-set          free, per-value, per-message
    module swap       gated at load by the commit-time signature diff,
                      per-step atomic
    major migrate     ModelN -> ModelN' (fpr commit --major; audited)
    restart           topology changes -- out of live-reload scope

The module-swap rung closes ON-QOS too: `CP.plugin slot id src`
(std/compile) packages a source string into a hot-loadable module .qa
through the host fprd daemon, the bytes land on the app's own qlog
store as apps/<id>.qa, and LR.load pulls them through the same compat
gate as a seeded disk -- tests/selfhost.fpr is the whole loop (edit,
compile, package, store, hot-swap, impostor refused) without leaving
the running system.  The packaged .qa is a MATCHED SET with the exact
shell image it linked against (plugsyms bakes absolute addresses); the
daemon re-derives plugsyms from the current build per package, and
the set is now CHECKED, not conventional: mkqa stamps every plugin
with the shell image's LOAD sha (`shell = ...`), and the host REFUSES
an attach whose stamp does not match the hosted image -- what used to
be a silent, layout-dependent memory corruption is a named error.

## 6. The disk is the system (std.fs + std.loader)

Everything that exists is a record on the ONE append-only log, and
services are the only interpreters: `std/fs` is the client of the
storage actor (the log's one writer -- apps hand it the device once
and never touch it again), and `std/loader` is the actor that turns
`apps/<id>.qa` records into live code.  Every gated, successful load
appends the attach chain as the `sys/live` record, so THE RUNNING
MODULE SET IS A PURE FUNCTION OF THE LOG: on boot, `LD.replay` reads
`sys/live` and reassembles the whole chain -- hot swaps included --
through the same gates, with no compiler and no operator present.
A refused version (shell-stamp mismatch, arity drift) is detached and
never recorded: the log cannot describe a set that was not live.

tests/sysdisk.fpr is the proof, two boots of one image: boot 1 builds
the live set message by message (load v1, hot-swap v2, impostor
refused); boot 2 replays `sys/live` and the swap is simply THERE.

## Files

    compiler/FPRISC.hs   expandPathLits (+ shapeTyTable): the literal
                         and schema rewrite, validation, tags
    compiler/Compile.hs  wiring: first pass after loadProgram, one
                         shape table for root+units (AOT profiles)
    std/lens.fpr         comp, find/set/get/setWords/dump
    std/mvu.fpr          SPort + MV.port + the per-frame drain
    tests/paths.fpr      both tiers + compose + refusal, minimal
    tests/pathnotes.fpr  the full stack on the Notes app
    tests/notesed{1,2,bad}.fpr  the swap surface (v1/v2/impostor)

## Open edges (named, not hidden)

  * list indices / constructor prisms: partial paths, type-indexed
    (`PathP`), not yet implemented;
  * ~~the sol profile does not run the rewrite~~ — closed: the sol
    pipeline runs expandPathLits too, and with the VM's actor shim
    (green actors + Sys/mtime stubs, VM.hs) whole std.mvu apps — the
    message port and schema sets included — run INTERPRETED under
    `fpr sol` / `qos.py dev`, same results as the compiled tier;
  * unit-local shapes: literals resolve against the merged shape
    table; a shape declared inside a `use`d module is addressed by its
    qualified name, so in practice declare your Model in the root
    program (where the app lives);
  * schema history / time-travel: `ver` in the model enables it, the
    append-only model log itself is not built;
  * the `Pause` idiom (gate ticks by a model flag while the mailbox
    stays open) works today via subs -- drop `STick` from the list --
    but has no dedicated convention yet.

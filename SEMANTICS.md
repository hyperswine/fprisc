# SEMANTICS -- what FP-RISC and QOS promise

The contract for 2.0.  Skeleton for now: dot points, plain words, a
`[test: ...]` slot on every clause.  A clause with a test is a rule.  A
clause without one is a proposal.  Where today's behaviour is known it
is written as it IS, marked (today); where a decision is open it is
marked (decide).  See docs/V2.md for the plan around this file.

Conventions: `.fpr` is the AOT surface (bare-metal, qos-native,
qos-portable), `.sol` the hosted-bytecode surface.  ONE grammar, two
file suffixes; a clause applies to both unless it says which.

---

## Part I -- the language

### 1. Programs and evaluation

- A file declares its PROFILE in its first lines: `profile builtin.`,
  `profile base.`, `profile extbase.`, `profile sol.` -- or `unsafe
  base.` (and the others) for the blanket-unsafe marker and the profile
  in one line.  A `.sol` file is sol; a file that says nothing is base.
  The command line's `--profile=` may serve a silent file, never
  contradict a declaring one.  The SYSTEM a program is built for is the
  compiler's `--system=` flag, not the file's.  (decided)
  `[test: tests/check_profiles.py]`

- A program is a list of top-level definitions ended by `.`; `main` is
  the entry.  A `.sol` file (or `--sol`) also accepts `>` top-level
  effects, run in file order.  (today)  `[test: tests/hello.fpr, sol/examples/stddemo.sol]`
- Strict evaluation, left to right.  Arguments before the call.  (today)  `[test: ]`
- Blocks: `x = e; body` binds then continues.  Every statement in a
  block BINDS -- a bare effect before `;` is a parse error; discard
  with `_ = e;`.  (today)  `[test: ]`
- A top-level `x = (a = e; body).` is a parse error: blocks live in
  function bodies.  (today -- decide: keep as a rule, or allow)  `[test: ]`
- Clause groups: `f pat1 = ...` / `f pat2 = ...` are one function even
  when another definition sits between them.  First match wins.
  Guards `| cond` on clauses; `case` arms carry no guards.  (today)  `[test: tests/split.fpr]`
- Lambdas `fn x y -> e` take variables, not tuple patterns.  (today --
  decide)  `[test: ]`

- A `case` inside a NON-FINAL arm of another `case` must be
  parenthesised: unparenthesised, the arms after it attach to the inner
  case.  The grammar stays as it is; the shape is REFUSED at compile
  time by case coverage, whatever the types involved: the outer case is
  left non-exhaustive, or the inner one gains an arm it can never
  reach.  (decided)  `[test: tests/check_cases.py]`
- Case coverage: every `case` must be exhaustive (constructor sets from
  the type; `Int`/`String` literals need a catch-all arm), and an arm
  with a refutable head (constructor, literal, tuple) that the arms
  before it already cover is an error.  A trailing `_` is never an
  error: an actor's `receive` is typed unsafely, and the catch-all is
  how a loop queues the messages the type does not name.  (decided)
  `[test: tests/check_cases.py]`

### 2. Names, reserved words, operators

- Reserved: `fn case of Type Sig Struct use unsafe measure`.  Defining
  a function named `use` or `keep` silently collides with a builtin
  today -- 2.0 refuses by name.  (decide)  `[test: ]`
- Operators: `+ - * / % ^` on numbers; `+ -` on strings and lists; `+
  - *` on Vec/Matrix; `==` `!=` (NOT `/=`); `< <= > >=`; `&& ||`;
  `::` cons; `|>` pipe; `|>?` Ok/Err pipe; `$` low-precedence apply;
  `>>` sequence; `!` 1-based list index (sol).  (today)  `[test: tests/opsugar.fpr, sol/examples/algebra.sol]`
- `+` on a tuple is not defined and is refused by name.  User types
  get operators through a struct.  (today)  `[test: sol/examples/operators.sol]`
- Precedence table: (write it down).  `[test: ]`

### 3. Values and types

- Ints are 64-bit.  Overflow: (decide -- wrap / trap / refuse where
  `measure` can derive it).  `[test: ]`
- Floats: `F64`, `F32`, literal suffixes `1.5`, `1.5d`, `2f`, `1e3`.
  Floats inside structures cannot be printed via the tid-directed
  render and the compiler REFUSES at compile time rather than printing
  garbage.  (today)  `[test: tests/float.fpr, check-all "Literal suffixes"]`
- Strings: (decide) bytes or code points.  Sol is 1-based (`charAt`,
  `Str.at`).  Interpolation `"{expr}"`.  Escapes: (list).  `[test: ]`
- Bool, Unit, tuples up to 8, lists, records `{a = 1, b = "x"}` with
  update `{r | b = 2}` and nested `{n | p.q = 42}`, sum types `T = Type
  (A Int | B String Int)`.  (today)  `[test: ]`
- Type inference: Hindley-Milner-shaped over the builtin table
  (`Infer.hs builtinEnv`, `Sol/Infer.hs solBuiltins`).  A 2-tuple
  compared to a 3-tuple is a type error, not a runtime False.  (today)  `[test: tests/eq.fpr]`
- Typed holes: `?name` refuses at compile time and prints the type;
  `??` runs the prefix then traps.  (today)  `[test: tests/holes_named.fpr, tests/holes.sol]`

### 4. Equality

- `==` is DEEP: ints by value, strings by content, tuples/lists/records/
  constructors by structure and content, variant AND payload.  `!=` is
  its negation everywhere.  Identity-only types (Vector, actor
  handles, PAPs, devices, registers, bit fields) compare by identity.
  (today, since v1.1.0 -- it was header-only before)  `[test: tests/eq.fpr]`
- Depth: today gives up at 64 and answers "equal".  2.0: cycle
  detection, no depth number.  (decide)  `[test: ]`

### 5. Linearity

- A type declared with `1` (`Handle 1 = Type ...`, `Vector`) is linear:
  consumed exactly once per path.  Threading is explicit -- `readAll h`
  returns `(String, Handle)` and you use the NEW handle.  Both `case`
  arms consume the same linears.  Leaking or double-using is a compile
  error, by name.  (today)  `[test: tests/linpap.fpr, sol/examples/*]`
- Partial applications and lambdas may capture linears; the closure
  becomes linear.  (today)  `[test: tests/linpap.fpr]`
- Discarding a linear with `_` is refused.  (today)  `[test: check-all "linear PAPs"]`

### 6. `unsafe` and `measure`

- A function that recurses without a decreasing measure needs `unsafe`
  in its signature (`f : unsafe Int -> Int .`) or the file needs
  `unsafe program.` / `unsafe module.`.  (today)  `[test: tests/measure.fpr]`
- `measure n` on a parameter declares what decreases; the compiler
  verifies non-decrease and the floor (`>= 0`) or refuses with the
  reason.  (today)  `[test: tests/measure.fpr]`
- Packaging rule: blanket `unsafe module.` is core-only; a `std/`
  module must mark unsafe per function.  (today)  `[test: ]`
- 2.0 goal: `unsafe` in std only on genuinely unbounded loops (a
  server's receive loop), each with a comment.  (plan)

### 7. Modules, `use`, pins, the store

- `A = use "path"` resolves relative to the importing file; an
  extensionless spec tries the importer's own suffix first, the
  sibling second.  A miss then tries the toolchain home (`$FPR_HOME`,
  else beside the `fpr` binary): `use "std/mvu"` works from any
  project.  (today)  `[test: qos/tests-host/install-check.sh]`
- `use "name#hash"` pins the module's AST hash (a Merkle root over its
  deps).  Drift = refusal with both hashes.  A pinned module missing on
  disk resolves from `.fpr/store/` (the project's, then home's).
  (today)  `[test: check-all "versions"]`
- `fpr commit` mints an immutable version; `fpr.lock` is the tree's
  pin set.  (today)  `[test: check-all "versions"]`
- Module cycles are refused.  (today)  `[test: ]`

- Builtin profile only: `Addr.symbol "name"` is the address of a linker
  symbol, the argument a literal; `--raw` units are allocation-free by
  check and uninstrumented; `--lib`/`--export` make C entries with a
  declared signature over Int/Word/Addr/Bool/Unit/F64/F32.  (today)
  `[test: tests/check_export.py]`

### 8. Records, paths, schemas

- `@Model.field` is a first-class typed path; compose, get, set;
  `Model` must declare the field or the compiler refuses.  (today)  `[test: tests/paths.fpr]`
- String paths (`"ui.fg"`) resolve at runtime against a schema and
  `Err` on a bad leaf.  (today)  `[test: tests/paths.fpr]`

### 9. Effects, IO, transactions

- The Base environment, on every profile whose HAL grants it (today: the
  Base profile, `machine/posix`): `Sys.args`, `Sys.env`, `Sys.exit`,
  `Sys.readLine`, `Sys.stderr`, `Sys.timeUs`, `fileRead`, `fileWrite`,
  `fileAppend`, `fileExists`, with the types and results in docs/BASE.md.
  A profile that does not grant one fails at link time on its `fpr_g_`
  name, never silently.  (today)  `[test: tests/check_base.py]`

- `.fpr`: effects are calls into the HAL through `Sys.*` and services
  (Part II).  `print` is immediate.  (today)
- `.sol`: a script is ONE atomic transaction over the filesystem;
  writes land at commit; `print` is not transactional (a retried
  script re-prints).  A panic aborts totally.  (today)  `[test: tests/txnabort.sol, check-all "txn"]`
- `sh`/`shq` are deferred commands with an honest receipt.  (today)  `[test: check-all "sol txn hygiene 2"]`

### 10. Actors and messages

- `spawn f` makes an actor; `send a v` returns `Result Unit String`
  (never spins); `receive` blocks; mailboxes are `Static n` (refuses
  when full, says so) or `Dynamic n` (grows, in order).  (today)  `[test: tests/mailbox.fpr]`
- Messages are copied or ARC-shared by the runtime; the ARC table
  grows.  (today)  `[test: tests/mailbox.fpr]`
- Actor identity, death, and a send to a dead actor: answered, not
  hung.  (today)  `[test: tests/mailbox.fpr]`
- Scheduling: per-hart run queues with stealing; what is promised
  about fairness and latency: (decide; docs/SCHEDULER.txt is the
  account).  `[test: tests/pingpong.fpr, tests/fanin.fpr, tests/mvulat.fpr]`

### 11. Vec, Matrix, columns

- `Vector` is linear; `Vec.*` thread it; `Vec.free` or a consuming op
  ends it.  Record vectors are SoA with up to `VMAXCOLS 8` columns
  (decide: grow).  Fusion of adjacent maps is a guarantee of the AOT
  tier, not the interpreter.  (today)  `[test: tests/vecedge.fpr, tests/fuse.fpr]`

### 12. Sigs, structs, generics (sol)

- `Sig` names a row; `Struct` conforms to sigs; a generic function over
  a sig is monomorphised when the struct is a literal name, else
  first-class.  Conformance is checked at struct definition AND at
  call sites.  (today)  `[test: sol/examples/*]`

---

## Part II -- the OS

### 13. What a service is (decide first)

- Today there are three idioms: path strings (`/services/storage`),
  named devices (`device "blk"`, `reg32 clint 49144`), and `Sys.*`
  builtins.  2.0 has ONE: a capability-typed handle obtained once,
  with a typed protocol.  The three become ways to OBTAIN a handle.
  (decide)  `[test: ]`
- A handle is linear where the resource has phases (`std/uart` is the
  model: open -> configured -> in use -> closed, each a type).  (decide)
- Capabilities: an app names what it needs in its manifest
  (`QA_MAX_PERMS 32` today); the host grants or refuses at load; a
  call outside the grant is refused with the capability named.
  (today, partly)  `[test: check-all "/services/uart"]`

### 14. What a driver is

- A driver is an actor that owns a device and exposes the service
  protocol for it.  It is written in FP-RISC (`std/uart`, `mods/timer`
  are the existing ones).  (today, partly)
- IRQs: bound to an actor (`Sys.timerBind`, the aux-hart bridge);
  delivered as a message; `IRQ_MAX 64` today (decide).  `[test: tests/timer.fpr, tests/uartsvc.fpr]`
- DMA / device memory: granted as a typed region, never a raw address
  in app code.  (decide)
- Registers: `reg32 dev off` today; 2.0 -- only inside drivers.
  (decide)

### 15. What a process is

- A `.qa` image with a manifest; loaded at a slot; owns an arena;
  memory comes home when it exits.  (today)  `[test: tests/apps.fpr, tests/memory.fpr]`
- Fixed slot base `0x4_0000_0000`, `QOS_SLOT_SIZE 16 MiB` per image,
  8 x 4 MiB plugin sub-slots: 2.0 sizes images and plugin regions from
  the manifest.  (decide)  `[test: ]`
- Plugins: a library image attached to a running shell, linked against
  the shell's symbols; the gate refuses drift.  (today)  `[test: tests/livereload.fpr, tests/sysdisk.fpr]`
- The disk IS the system: `sys/live` records replay the live set on
  boot; no compiler needed at boot.  (today)  `[test: tests/sysdisk.fpr]`

### 16. Memory

- One memory actor owns the buddy; the runtime requests blocks by
  message; an app owns its arena; blocks come home.  (today)  `[test: tests/memory.fpr, tests/bigfree.fpr]`
- Sizes: `FPR_SLAB_SZ 256 K`, `FPR_MSG_SLAB_SZ 64 K`, `FPR_STACK_SZ
  256 K` -- machine defaults; 2.0: per app from the manifest, the
  machine's total from the DTB / host.  (decide)
- What is promised when memory runs out: refuse the grant, the
  requester gets `Err`, never a silent wrap or a hidden kill.  (decide)  `[test: ]`

### 17. Storage

- QLOG: an append-only page log; `apps/<id>.qa` records; a kv per app
  (`qos-store/<id>.kv` on qosp).  (today)  `[test: tests/qdisk2.fpr]`
- Disk size: today from the image; 2.0 from the device.  (decide)

### 18. Time and scheduling

- `mtime` at 10 MHz is the clock; `Sys.sleepUs`; `STick` pacing in
  MVU.  (today)  `[test: tests/timer.fpr]`
- Hart count: `FPR_NHARTS` compile-time today; 2.0: discovered.
  (decide)  `[test: ]`

### 19. The ABI

- `QOS_ABI_VERSION 12`, `codegenRev 8`: a `.qa` carries both; a
  mismatch refuses to load with both numbers printed.  (today)  `[test: check-all "QAR2 process load"]`
- 2.0: bump to v13 once, then frozen.  A change = a new version + a
  compat note + a migration.  (plan)

### 20. Hosts and targets

- Systems: `--system=bare-metal | qos-native | qos-portable | posix`.
  The matrix: profile builtin runs on bare-metal only; sol on posix only
  (the VM); base and extbase on every system whose HAL grants what they
  use.  The 1.x `--profile=bare-metal|qos-native|qos-portable|
  bare-metal-builtin|base` spellings mean the same as before.  (decided)
  `[test: tests/check_profiles.py]`
- The posix system (`--system=posix`, `fpr build`): an ordinary executable
  for the machine the compiler runs on, the core runtime linked with a
  libc HAL; harts are pthreads (`FPR_HARTS`).  Exit status = main's Int
  result, else 0; a panic is 1.  Nothing is echoed at exit.  (today)
  `[test: tests/check_base.py]`

- qosp (Linux x86-64, macOS arm64, Linux a64 cross) hosts one `.qa`;
  virt (QEMU) boots the native kernel; a board target is the 2.0
  addition (docs/V2.md workstream 4).  What each host promises of the
  HAL table (`qos_abi.h`, 26 entries): (write it down per host).  `[test: ]`

---

## Part III -- the tools

- `fpr compile | sol | stdcheck | commit | versions | push | pull`,
  `qos.py build | run | new | pack | dev | serve | native | disk |
  commit | lock | release | test | install | clean`: the names and
  flags are part of the contract from 2.0.  (plan)
- The workspace: nothing a run does writes into the tree; `.qos/`
  under the invoking directory.  (today)  `[test: qos/tests-host/install-check.sh]`
- The `#:` directives a program may carry: `name`, `expect`, `plugins`,
  `host`, `music`, `disk-mb`, `fprd`, `version`.  (today)  `[test: ]`

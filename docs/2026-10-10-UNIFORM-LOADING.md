# Uniform loading: a module is a file, a load is a message

Kind: direction, 2026-10-10, stated by the owner and mapped to the code.
Nothing here is built. It is the second part of
`2026-10-08-SCHEDULER-API.md`: that page's first two steps are the gate
for this one. Paths: `runtime/` and `std/` are this repository, `Q/` is
`../qos`.

## The statement

There should be no "other" concept. An FP-RISC library or module is
compiled to one binary object file, a `.qa`, and loaded into a running
program as just another message that the program's supervisor actor
understands, independently of the operating system. An application on
QOS is the same file with the same extension, which the QOS runner
(System.qa, Loader.qa) reads from its URL, hands to a fresh supervisor,
and that supervisor creates the memory and control blocks it needs,
spawns its program's actors, and those actors ask Memory.qa for memory
on spawn and on allocation. Everything is URL-addressed files and
services, with operating-system functionality just another function or
actor of a service `.qa`, all the way down.

## What already matches it

- **One image format.** A `.qa` carries MANIFEST, LOAD, IMAGE, RELOC and
  IMPORT (`Q/docs/2026-07-19-QA-FORMAT.md`, `Q/tools/mkqa.py`). Images
  are linked at 0 with a relocation list, so they land anywhere
  (`Q/docs/2026-10-01-PROCESS-IMAGES.md`). LOAD is read and gated in
  FP-RISC (`Q/programs/mods/qaimg.fpr`), including the digests, the
  native ABI and the two plane contract versions.
- **Files serves bytes by URL.** `apps/<id>.qa` is a record on the one
  log, newest wins (`Q/std/fs.fpr`, `Q/programs/mods/files.fpr`).
- **Identity and grants precede the first instruction.** A pid is
  reserved and its grants recorded in the namespace before placement
  (`Q/programs/system.fpr` `placeGranted`, `Q/programs/mods/ep.fpr`);
  a launched program is handed exactly one actor handle, the namespace
  (`Q/tests/epproc.fpr`).
- **Memory is uniform.** An image is a buddy block like an actor's slab
  or stack; a process's actors grow their pools through the memory plane
  (`fpr_plane_memory_t`), and the memory actor serves every take
  (`2026-10-07-STATES.md` section 3).
- **The registry answers names.** `Mod.find` resolves an export to its
  newest attachment; checked interfaces (`2026-10-04-CHECKED-INTERFACES.md`,
  `2026-10-04-RUNTIME-INTERFACES.md`) are the compatibility test.

## What breaks it

| Today | Why it is an "other" concept |
| --- | --- |
| two placers in C: `Sys.placeImageAt` (native process: takes caps, a pid and a boot block) and `Sys.attachImage` (Portable plugin: binds imports by name) | one file format, two load paths, each with its own refusals and its own test suite |
| the manifest's `loadMode` | the FILE decides which world it belongs to, instead of the loader deciding what to do with it |
| native refuses an IMPORT section ("rebuild a self-contained process") | a native image must carry its own copy of the runtime and reach the kernel's through the plane tables (`2026-10-08-PLANE-TABLES.md`), so it cannot be a library |
| the boot block (`Q/qos/native/shared_boot.h`) | a C struct filled by the loader and read by the image's C entry, instead of the root's first message |
| the word "plugin" (`Q/programs/mods/plug.fpr`, `Q/std/loader.fpr` `LLaunch`, `Q/docs/2026-10-01-IMPORT-TABLE.md`) | names the Portable half of the split; on Portable a launched app is a plugin at load time and a process at run time |
| the loader actor's protocol (`LLoad`, `LReplay`, `LList`, `LLaunch`) | a tooling protocol on the OS side, which `2026-10-03-LIVERELOAD.md` already calls meta-level |

## The uniform shape

**One primitive set in the runtime, with no operating system in its
signature.** What the two placers do now, minus caps and boot blocks:

| Primitive | Does |
| --- | --- |
| `place bytes` | a block from the memory plane, the image copied and relocated there, the code published (I-cache fence here, remote harts at dispatch); answers an image handle or a refusal by name |
| `bind image` | the image's exports into the loading program's registry; its imports resolved by name against that program's export table (FP-RISC names through `Mod`, C primitives through a published table, as Portable's import table does today) |
| `release image` | detach, and return the block once no actor of the image is live (`fpr_pid_live`) |

These exist as `fpr_qaimg_place`, `fpr_qaimg_relocate`, `fpr_code_publish`,
`fpr_image_add/remove`, `fpr_mod_attach` and the import stubs; the change
is their signature and their number, not their mechanism.

**One supervisor actor per program, in FP-RISC** (`std/supervise`, the
S4 suggestion of `2026-10-05-SUPERVISION-AND-ADMISSION.md`), understanding
a few messages:

| Message | Meaning |
| --- | --- |
| `Load image` | place and bind as a library into this program's registry, gated by the checked interfaces; tell the program's runner a reload happened (the `EReload` of `2026-10-03-LIVERELOAD.md`) |
| `Run image args` | spawn the image's root under this supervisor's identity (its pid, its grants); the root's first message is what the boot block carries today: the namespace handle and the reply address |
| `Unload image` | release when no actor of it is live |
| a child's death | the monitor S3 asks for: the supervisor hears every death of its program with the reason |
| `Budget ...` | the process's resource budget (`Q/docs/2026-10-03-RESOURCE-ACCOUNTS.md`), see below |

A module and an application then differ only in whether the supervisor
is asked to `Run` it. The same file can be loaded as a library by one
program and run as an application by another.

**System.qa and Loader.qa become compositions.** Open a URL, read the
bytes, send `Load` or `Run` to a supervisor; the journal of the live set
stays a Files record as `sys/live` is now, and replay at boot is the
supervisor reading it. Nothing in them places memory or reads a C struct.

## The two prerequisites, in order

1. **Images stop carrying their own runtime.** Steps 1 and 2 of
   `2026-10-08-SCHEDULER-API.md`: the scheduler contract in plain words,
   the channel block moved above it. Until the kernel is the only runtime
   in the address space, loading a module INTO a process means two
   runtimes agreeing on every struct, which is what the plane tables and
   `FPR_NATIVE_ABI` exist to police. A library bound into a program must
   call that program's runtime, not its own copy.
2. **Imports by name on native.** Portable binds 46 symbols through
   stubs and slots (`Q/docs/2026-10-01-IMPORT-TABLE.md`); native needs
   the kernel to publish the same table for its C primitives. The FP-RISC
   names already come from the module registry.

After those, removing the plugin concept is mostly deletion: the
Portable attach path, `loadMode`, the IMPORT refusal, the boot block,
the loader's four-message protocol.

## What does not change

- **The gates.** Digests, the ABI and contract versions, the checked
  interfaces: they are the only isolation this system has, and every
  page says so. The supervisor applies them at `Load`; nothing places
  memory for an image that fails one.
- **Files as the one store, and the endpoint contract** (`Q/docs/2026-10-02-ENDPOINTS.md`):
  a load begins with `open` of a URL.
- **Newest-wins in the registry** stays as the mechanism; the
  runner-owned swap of `2026-10-03-LIVERELOAD.md` is built on the
  supervisor's reload notice instead of the loader's broadcast.
- **The register.** The plugin lifecycle entry this replaces becomes the
  supervisor's: Load, Run, Unload and the child-death states get owners,
  exits and tests like the others in `2026-10-07-STATES.md`.

## One decision

The statement has actors ask Memory.qa directly on spawn and on
allocation. They do, through the memory actor; but the memory actor is
C behind the buddy and applies no policy beyond availability (section
3.5, A4), and nothing holds a per-process budget (A8). A supervisor that
owns `Run` is the natural admission authority: it holds its program's
budget and the memory actor stays a mechanism. The alternative, budgets
inside Memory.qa, makes Memory.qa know pids. **Suggested:** the
supervisor holds the budget; Memory.qa answers takes and frees and
nothing else. Then "an actor asks Memory.qa on spawn" is literally what
happens, and "who may have how much" is one actor's state, replaceable
without touching the allocator.

## Order of work

1. `2026-10-08-SCHEDULER-API.md` steps 1 and 2 (the gate).
2. The three primitives, used by BOTH current paths; delete
   `placeImageAt`'s caps and boot-block parameters and `attachImage`.
3. `std/supervise`: `Load`, `Run`, `Unload`, monitors (S3), then the
   budget (S4, A8).
4. System.qa and Loader.qa as compositions over URLs; `sys/live` as the
   supervisor's journal.
5. The native import table.
6. Delete `loadMode`, the IMPORT refusal, the boot block, and the word.

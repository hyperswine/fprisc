# Reducing the C: policy and limits move above the line

Kind: plan, with what has landed. Started 2026-09-19. Companion to
`BOUNDS.md` here and `../qos/docs/BOUNDS.md`.

## The goal

From the lowest service to the highest application, one model: FP-RISC code
running as an actor, its parameters adjustable at run time by message. The only
hard-coded parts are the driver HALs and the memory service. Above that line a
program does not care where its memory comes from, only that it is allocated,
and a growing thing is a `List a` or a `Vec a` -- no special mechanism.

The goal is **not** zero C. It is: no *policy* and no *limit* lives in C.

## Why this is the same project as BOUNDS.md

Nearly every open limit in the bounds registers is a static array in C:
`irq_act[IRQ_MAX]`, `conns[NETCONN]`, `meshes[MAX_MESHES]`,
`plug_ranges[PLUG_MAX]`, `xtabs[MOD_MAXATTACH]`, `perms[QA_MAX_PERMS]`. C that
runs below the allocator and outside the actor model cannot say `List`, so it
says `T tab[N]`. Move the logic above the line and the limit goes with it.

The manifest parser was the proof. `qos/portable/qa.c` held 32 permissions,
95-byte urls and a 4 KiB blob, each silently cut. `programs/system.fpr` parsed
the same manifest into lists with no capacity anywhere. The bugs were only ever
in the C copy.

## Three tiers, not two

Some code cannot be "just an actor with a List", and saying so keeps the rest
honest.

| Tier | What | Written in | How it avoids limits |
|---|---|---|---|
| 0 | context switch, trap entry, boot, machine primitives, device register access | assembly and the HAL (`hal/*/` `.S`, about 450 lines) | it has none to avoid |
| 1 | the allocator, the scheduler's queues, channel rings, message transfer, interrupt delivery | today C; target the `builtin` profile | it **cannot allocate** (the scheduler allocating would message the memory actor, which needs the scheduler; interrupt handlers may not allocate, and `check_raw.py` enforces it). Unbounded here means **intrusive**: a run queue linked through a field inside the acb needs no allocation and has no capacity. What remains (hart count, RAM) comes from the device tree at boot, not from `#define` |
| 2 | everything else | the `base` profile: actors, `List`, `Vec` | memory is the only bound; tuning is a message to the owner |

Tier 2 should hold most of the code. Tier 1 should be small, and is where a
`Static n` style of declared bound is legitimate.

One caution carried over from the mailbox design: a `Vec` that reallocates is
amortised O(1) with an O(n) step, and an unbounded mailbox turns overload into
exhaustion. `Static n` / `Dynamic n` already has this right. The rule is:
unbounded by default, bounded when the programmer declares it, never bounded by
the implementation.

## What the C is (2026-09-19)

About 9.5K lines of C and assembly in `hal/`, about 5.5K in QOS, against 14K
lines of FP-RISC programs. `runtime.c` (2474) and `actors.c` (2098), by section,
approximately:

| Kind | Lines | Examples | Destination |
|---|---|---|---|
| plain library, needs no privilege | ~850 | render, string prims, log rings, floats, `sin`/`cos`/`exp`/`log` | tier 2 |
| generic walks over untyped heap objects | ~500 | deep copy for send, `==`, `render` | **compiler-generated** per type. The runtime has lost the types, so this code inspects headers and guesses field counts -- the source of the `==` depth bug and of the "two statics keep the header-only answer" hack. The compiler knows the types |
| policy | ~1000 + QOS | timer and irq routing, sleep, the syscall mailbox, the process loader (`process.c`, `elfload.c`, `qaimg.c`), the TCP stack in `hal/virt/net.c`, qosp's manifest parse, permission gate and store | tier 2 actors |
| mechanism | ~2000 | scheduler core, rings, slab allocator, ARC table | tier 1; `MEMORY-V2-PLAN.md` phases 4 and 5 already move ARC and the locks behind owner actors |

Drivers need not be C: `programs/mods/uart.fpr` is an interrupt-driven 16550
driver written as an actor, its interrupts arriving as mailbox messages.

## What the language needs first

1. **Typed memory layouts.** `hal/builtin/heap.fpr` works, and reads like
   assembly: `rd b 24`, `wr a 56 v`. Porting the scheduler in that style would
   be less readable and less safe than the C. A `layout` declaration -- named,
   typed fields at fixed offsets, zero cost -- is the prerequisite for tier 1.
2. **Stack safety.** Building a 20,000-element list by ordinary recursion dies
   with SIGBUS (BOUNDS.md). FP-RISC recurses where C loops, so this matters more
   with every line that moves. Guaranteed tail calls, or an overflow check.
3. **`builtin` beyond first-order and one hart**, and raw exports past 8
   register parameters.
4. **Compiler-generated equality, show and copy.**

The migration tool already exists: `--lib --export`. `heap.fpr` replaced
`heap.c` behind the same C symbols with a `HEAP=fpr` switch, and
`check_export.py` holds the two to each other. One file at a time, switchable,
same tests.

## Order

1. **Delete duplicates** -- C that repeats logic already written in FP-RISC.
2. Move the unprivileged library code out of `runtime.c`.
3. Typed layouts, then the policy pieces, one at a time.
4. Generated equality, show and copy.
5. The scheduler and ARC last, or never: ~2K lines of well-tested tier-1 C is a
   reasonable place to stop.

## Landed

### Step 1a: one manifest implementation (2026-09-19)

- `../qos/programs/mods/manifest.fpr`: the manifest's TOML subset folded into a
  `Man`, and the capability blob. Pure -- strings in, values out -- with no
  capacity anywhere. Keys under a table that is not one of the two permission
  tables are ignored (both older implementations let them overwrite `id`).
- `programs/system.fpr` uses it; its inline copy (about 100 lines, including a
  byte-at-a-time `strcat` line splitter) is gone. Verified on rv64: the kernel
  reads its config, parses TUIAppLauncher's four required permissions and
  launches it.
- `../qos/tools/qainfo.fpr`: the same module as a **Base program on the posix
  system** -- the kernel's modules compile for the host unchanged and read real
  200 KB archives.
- `../qos/tools/qainfo-parity.sh` holds `qos/portable/qa.c` to it: for each
  manifest it launches an app under qosp and compares the blob the app
  *received* with the blob the module computes, byte for byte. The shipped
  manifests plus one past every old limit (300 permissions, a 1000-byte url,
  a 6.9 KB blob): all agree.

### Step 1c: qosp is an FP-RISC program (2026-09-19)

`qos/portable/qosp.fpr` is the portable host's `main`: a Base program for the
posix system, about 90 lines, that reads the archive, interprets the manifest,
gates the abi, verifies the image's sha, asks for the permissions and builds
the capability blob -- with the kernel's own `qar.fpr` and `manifest.fpr`.
`main()`, `abi_gate`, `perm_gate` and the C blob serializer are gone.

Two things made it possible, and both are general:

- **A signature with no definition is a foreign declaration.** It already
  type-checked, and codegen already treats an undefined global as an `fpr_g_`
  external. `Host.init : Bool -> Result String String .` is the whole FFI.
- **`fpr build --with hal.c --cflag F --link F`**: a program brings its own HAL,
  compiled beside the runtime. qosp's is `portable/host.c` (five primitives: map
  the arena, hash, place and protect the image, enter it, log) plus the device
  tiers in `hal/unix`. This is the goal in miniature: FP-RISC policy over a C
  HAL, the primitives named in the program that uses them.

What had to be right: the app's freestanding entry keeps ITS hart in `x28` and
does not restore the host's, so `enter_app` saves and restores it around the
call (a thread would also work, but GLFW on macOS needs the main thread). The
host runtime is built `--harts 1`; it blocks in `Host.run` while the app runs.

Checked: `./qos.py test` 10/11 as before, plugins, LiveView multi-client, the
301-permission archive, and every gate -- y/n/y grants exactly that subset, a
denied required permission refuses, an abi mismatch and a name-dispatch archive
refuse by name, an unstamped archive warns and runs, one flipped byte in IMAGE
is caught. `qosp-gl` builds; it was not run (it opens a window).

**What is left of `qa.c`** (261 lines) serves one caller: `Sys.attachQa`. A
plugin arrives on an APP thread, where the host's FP-RISC cannot run, so the
host still parses that archive in C. The fix is native's shape:
`Sys.loadImageAt` already takes section extents that FP-RISC computed with QAR.
When plugin attach takes the fields the app computed, `qa.c` goes entirely,
and with it the last C manifest parser. Six callers: `mods/qsys.fpr`,
`tests/qload.fpr`, `std/loader.fpr` (three), `std/livereload.fpr`.

Also fixed on the way: `fpr build` / `fpr run` discarded the compiler's stdout,
where type and safety errors are reported, so a refused program exited 1 having
said nothing. The log is kept and replayed on failure.

### Found on the way, fixed

- **`print` of a String longer than 4095 bytes panicked** ("render buffer
  full"). The parity test's 6.9 KB blob hit it on both sides. `str` already
  returned a String unchanged; `print` now writes one straight to the console
  the same way. Checked with 20,000 bytes on rv64 bare metal.

### Step 1b: the console's line ending belongs to the device (2026-09-19)

`runtime.c` inserted `\r` before every `\n` and ended lines with `\r\n` -- a
serial-console habit in the portable core. Every Base program's stdout was
CRLF, which breaks ordinary pipelines, and `check-all.sh` pipes nearly every
leg through `tr -d '\r'` to cope. The core writes `\n` now; the two HALs that
front a raw 16550 (`hal/virt/hal.c`, `hal/builtin/virt.c`) add the carriage
return in `hal_putc`. posix and the qosp host add nothing: the OS line
discipline already does it on a terminal, and a pipe wants none. Checked: posix
and qosp stdout carry no CR, both rv64 UARTs still put CRLF on the wire.
A small instance of this whole document: console policy living in the core.

# Profiles and systems: what a program is written against, and where it runs

Kind: reference for what ships today; SEMANTICS.md sections 1 and 20 carry
the contract lines.

Two axes, kept apart because they answer different questions:

- The **profile** is the program's: the surface it may use, the guarantees it
  gets.  A file declares it in its first lines, the way it declares blanket
  unsafety, and the compiler takes the file's word.
- The **system** is the compiler's flag: the backend the program is built
  for, `--system=bare-metal | qos-native | qos-portable | posix | esp-idf`.

```text
profile base.              # what I am written against
```

```sh
fpr compile --system=posix prog.fpr prog.s      # where I run
fpr build prog.fpr                              # the posix system, one step
fpr run prog.fpr                                # build and run; sol programs go to the VM
```

## The profiles

| profile | surface | systems |
|---|---|---|
| `builtin` | Word/Addr/Mem/CPU and the raw ABI, no allocator or prelude behind it; `--arc` adds first-order automatic ownership, `--raw` an allocation-free unit, `--lib`/`--export` C entry points (docs/BAREMETAL-BUILTIN.md) | bare-metal |
| `base` | the language, the prelude, `use "std/..."`, actors, and the Base environment where the system's HAL grants it (docs/BASE.md) | every system |
| `extbase` | Base plus the extended ecosystem (the std modules beyond Base, QOS services where present); today the compiler treats it as Base and records the name | every system |
| `sol` | Base plus top-level `>` statements, the transactional runtime and the safe scripting API; runs on the bytecode VM | posix |

Declaring it:

```text
profile builtin.        profile base.        profile extbase.        profile sol.
unsafe base.            # the blanket-unsafe marker and the profile in one line
```

A `.sol` file is `profile sol` without saying so.  A file that says nothing
is Base.  `--profile=builtin|base|extbase|sol` on the command line serves a
file that says nothing and may not contradict one that does: the refusal
names both.

What the profile decides in the compiler: `builtin` selects the HAL-free
raw surface (no prelude, the machine primitives, the ownership modes);
`sol` admits `>` at the top level and sends `fpr run` to the VM; `base`
and `extbase` are the ordinary pipeline.  Everything else -- the target ISA,
the runtime that links, the HAL -- follows from the system.

## The systems

| system | ISA and lowering | what links | how it runs |
|---|---|---|---|
| `bare-metal` | rv64 (rv32 with `--target=rv32`), `--rvv` for the vector tier | `machine/virt` + `runtime`, or `machine/builtin` for profile builtin | QEMU virt, a board |
| `qos-native` | rv64 | the QOS kernel's app link (qos/qos/Makefile) | the QOS kernel on virt |
| `qos-portable` | x86-64 QOS app image (`qx64`; `qa64`/`qa64mac` by `--target=`) | qos/appside | `qosp`, the portable host |
| `posix` | the host this compiler was built on: x86-64, AArch64 Linux, AArch64 macOS, AArch64 FreeBSD | `machine/posix` + `runtime`, harts as pthreads | an ordinary executable; also the VM for sol |
| `esp-idf` | rv32 (rv32imafc on the ESP32-P4) | `machine/esp-idf` + `runtime` as an ESP-IDF project, harts as FreeRTOS tasks pinned one per core | an ESP-IDF app image, flashed to the chip (machine/esp-idf/README.md) |

The 1.x spellings still work and mean what they meant: `--profile=bare-metal`
is `--system=bare-metal`, `--profile=qos-portable` is `--system=qos-portable`,
`--profile=bare-metal-builtin` is `--system=bare-metal --profile=builtin`,
`--profile=base` is `--system=posix`.

## `posix` and `qos-portable`: two systems on the same kind of host

Both run on a Unix-like host, and both put harts on pthreads over the same
`runtime/`. They are still two systems, kept apart on purpose, because they
answer different questions.

**`posix` is FP-RISC on an operating system.** It is part of porting the
language (docs/HAL.md, layer 2): the host OS is the board, and a program
gets what a process gets -- the command line, the environment, the three
streams, files, directories, processes, sockets, the clock and an exit status
(docs/BASE.md, `std/os`). The result is an ordinary executable that needs
nothing installed beside it and nothing from QOS. This is how running
FP-RISC stays independent of QOS: servers, tools and scripts are posix
programs (`fpr build`, `fpr run`).

**`qos-portable` is QOS on an operating system.** A program built for it is
a QOS app image: it carries its own copy of the runtime, linked against
`qos/appside` at the fixed arena address QOS apps are loaded at, and it sees
the machine through QOS's HAL (`qos_hal_t`: graphics, sound, net, block,
keyboard, tty -- docs/HAL.md, layer 3) and QOS's services, exactly as it would
on QOS Native. `qosp`, the portable host, loads the image and supplies that
HAL from the host OS. The point is the same app on either QOS; the host is
an implementation detail.

How they relate:

- `qosp` is itself a `posix` program: `qos/qos/Makefile` builds
  `portable/qosp.fpr` with `fpr build`, and the host's device C links beside
  it. So QOS Portable sits ON the posix system; it does not replace it.
- Choosing: a program that should run as a plain process on the host --
  talk to its files, its network, its terminal -- is `posix`. A program that
  should run on QOS, and on a desktop only for development or as an
  appliance (tools/buildroot), is `qos-portable`.
- Some libraries exist in both worlds and are not yet shared: the FPRLive
  driver is `std/live` on posix and `qos/programs/mods/fprlive.fpr` on QOS
  (qos/docs/FPRLIVE.md). The view layer (`std/view`, `std/ma`,
  `std/livejs`) is pure and is shared.

What "a Unix-like host" means today: macOS, Linux and FreeBSD, on AArch64
and x86-64, built on the machine it targets (`fpr build --cc` changes the
libc, not the instruction set: docs/BOUNDS.md). Windows is not supported by
either system.

## `esp-idf`: its own system, not a flavour of `posix`

ESP-IDF looks POSIX-ish -- newlib, pthreads over FreeRTOS, BSD sockets from
lwIP, a VFS -- and `machine/posix` was the first candidate. It is a separate
system because what matters to FP-RISC differs:

- The ISA is rv32, so the code generator is the rv32 emission (4-byte words,
  31-bit Int), not the host lowering `posix` uses.
- There is no process: no command line, environment, exit status, `fork` or
  files by default, so most of `std/os` has nothing under it.
- The things worth having are not POSIX at all: the second core, GPIO, the
  radio through ESP-Hosted, NimBLE, NVS. They come as platform libraries with
  neutral names (`std/wifi`, `std/ble`, `std/gpio`, implemented in
  `platform/esp-idf/`), and blocking IDF calls run as jobs off the harts.

What it does share with `posix`: `runtime/` unchanged in design (the actors,
the allocator, the deadlock detector), and the hart-as-thread shape (a
FreeRTOS task pinned per core, parking on a task notification). Where the IDF
APIs match -- lwIP sockets, the poller's readiness model -- `machine/posix`'s
descriptor and socket objects now link into ESP-IDF and pass a loopback
hardware test. The full Unix machine layer is still not linked as a whole.
The decisions and workarounds, one by one, are in ESP-IDF.md, along with a
proposal for folding it into posix later: ESP-IDF as a second kind of posix
host, with its hardware moved into platform libraries.

## The matrix, enforced

- `builtin` on anything but `bare-metal`: refused ("profile builtin runs on
  the bare-metal system only").
- `sol` on anything but `posix`: refused; `fpr build` refuses a sol program
  outright (it runs, it is not linked).
- `>` at the top level outside `profile sol`: refused as a profile error,
  not a parse error -- the sentence is grammatical everywhere, it just is
  not part of that profile's contract.
- `esp-idf` with another `--target`, a QOS app image, a plugin or RVV:
  refused (it is rv32 code for an ESP-IDF application).
- A Base builtin the system's HAL does not grant fails at link time on its
  `fpr_g_` name: the image's imports are its capability manifest.

`tests/check_profiles.py` runs the matrix, the file-versus-flag rule, the
1.x spellings and the `fpr run` dispatch.

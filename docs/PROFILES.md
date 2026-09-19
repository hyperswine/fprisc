# Profiles and systems: what a program is written against, and where it runs

Kind: reference for what ships today; SEMANTICS.md sections 1 and 20 carry
the contract lines.

Two axes, kept apart because they answer different questions:

- The **profile** is the program's: the surface it may use, the guarantees it
  gets.  A file declares it in its first lines, the way it declares blanket
  unsafety, and the compiler takes the file's word.
- The **system** is the compiler's flag: the backend the program is built
  for, `--system=bare-metal | qos-native | qos-portable | posix`.

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
| `posix` | the host this compiler was built on: x86-64, AArch64 Linux, AArch64 macOS | `machine/posix` + `runtime`, harts as pthreads | an ordinary executable; also the VM for sol |

The 1.x spellings still work and mean what they meant: `--profile=bare-metal`
is `--system=bare-metal`, `--profile=qos-portable` is `--system=qos-portable`,
`--profile=bare-metal-builtin` is `--system=bare-metal --profile=builtin`,
`--profile=base` is `--system=posix`.

## The matrix, enforced

- `builtin` on anything but `bare-metal`: refused ("profile builtin runs on
  the bare-metal system only").
- `sol` on anything but `posix`: refused; `fpr build` refuses a sol program
  outright (it runs, it is not linked).
- `>` at the top level outside `profile sol`: refused as a profile error,
  not a parse error -- the sentence is grammatical everywhere, it just is
  not part of that profile's contract.
- A Base builtin the system's HAL does not grant fails at link time on its
  `fpr_g_` name: the image's imports are its capability manifest.

`tests/check_profiles.py` runs the matrix, the file-versus-flag rule, the
1.x spellings and the `fpr run` dispatch.

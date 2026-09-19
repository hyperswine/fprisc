# Runtime, machine layer, HAL: three things that were one word

Kind: the model the tree follows, and what still does not. Written 2026-09-19.

"HAL" used to mean three different things here, in one directory. They are
separate now, and only one of them is a HAL. (This tree has no `hal/` directory
any more: it was `hal/core` and `hal/{virt,posix,builtin,unix}` until 2026-09-19.)

| | What | Whose | Where |
|---|---|---|---|
| 1 | **The runtime**: allocator, actors and scheduler, vectors, strings, the panic path | the language's | `runtime/` (to be renamed `runtime/`) |
| 2 | **The machine layer**: what the runtime needs from whatever it runs on | the language's, one per system | `machine/virt/`, `machine/posix/`, `machine/builtin/`, `machine/unix/` (to be renamed `machine/`) |
| 3 | **The HAL**: the devices a PROGRAM sees | **QOS's** | `../qos/hal/`, `../qos/qos/appside/qos_abi.h` |

## 2. The machine layer

Small, and the same list on every system: put a byte on the console, end the
machine, wake a hart, sleep until woken, read the clock, arm a deadline,
fabricate and switch a context, guard a stack. About fifteen functions
(`hal_putc`, `hal_poweroff`, `hal_ipi_send`, `hal_mtime`, `hal_timer_arm`,
`hal_stack_guard`, ...). It is part of PORTING THE LANGUAGE, not of any
operating system.

- **virt** (rv64 bare metal): boot, context switch, the 16550's transmit
  register, the sifive test finisher, the CLINT (`clint.fpr`: the doorbell and
  the timer, which the SCHEDULER needs), and generic register access --
  `device`, `reg8`/`reg32`, `read`, `write` over a two-entry table (`uart`,
  `clint`). Register access is to a bare-metal program what files are to a
  hosted one: the machine itself, not a driver.
- **posix**: a process. The command line, the environment, the three streams,
  files, the clock, an exit status (docs/BASE.md). No register map: it used
  to model a 16550 over stdio so board programs ran unchanged, and that is
  gone. A portable program says `print`.
- **builtin**: the unsafe profile's own small runtime and machine primitives.

## 3. The HAL is QOS's

Devices are what an operating system gives a program, so they are QOS's, with
two backings behind one interface (`qos_hal_t`, versioned in `qos_abi.h`):

- **QOS Native** (`qos/machine/virt/`): the PLIC driver (`plic.fpr`), virtio net
  with its TCP stack, virtio block, the pin bus, and `devices.c`, which names
  them. They moved out of this tree's `machine/virt` on 2026-09-19.
- **QOS Portable** (`qos/machine/unix/`): graphics, sound, net, block, keyboard
  and tty over the host OS.

The one seam between layers 2 and 3 is `machine/virt/devtable.h`: the machine layer
resolves `device "name"` against its own two entries, then against whatever a
HAL above it supplies by DEFINING `hal_devtable_ext` (weak and empty by
default). No registry, no capacity. `make bare-metal` takes a HAL's sources
through `EXTRA_RT`; built from this tree alone an image has no drivers, and
`actors.c`'s weak `hal_irq_*` fallbacks mean interrupts simply do not exist.

## How a program reaches hardware outside QOS

The way any host facility is reached: a module declares the primitives it needs
as **signatures with no definition**, and `fpr build --with driver.c` links the
C that implements them. A program that references a primitive nobody supplied
fails at LINK time on the `fpr_g_` name: the image's imports are its capability
manifest.

## What still does not follow the model

- **The compiler's type environment** (`Infer.hs`) still types about 60 QOS and
  device primitives -- `glRender`, `sndPlay`, `inputPoll`, `blkRead`,
  `netRead`, `Pin.*`, `Sys.irqBind`, `Sys.timerArm`, `Sys.caps`, `Sys.store*`,
  `Mod.*`, `Apps.*`. Each belongs in the QOS module that uses it, as a
  body-less signature (`Sys.attachImage`, `Sys.placeImageAt` and `Host.*`
  already are). Module by module, because committed module versions that use
  a name break when it leaves (see QOS `fpr.lock`).
- **The irq and timer ROUTING** (`Sys.irqBind`, the drains) is in `actors.c`:
  HAL policy inside the runtime. It runs on every host, where the raw ABI has
  no lowering yet, so it cannot become an FP-RISC unit today.
- **`qos/qos/appside/hal.c`** still mixes an app image's machine layer with
  its device bindings.

# ESP-IDF: what the port decided, and what it bent

Kind: explanation and decision record.
Applies to: `--system=esp-idf` and `machine/esp-idf/`, as built on 2026-09-23
with ESP-IDF 5.3.2 on an ESP32-P4 rev 1.3 (the board in
machine/esp-idf/README.md).
Status: implemented. Evidence: the four programs in `machine/esp-idf/examples/`
run on that board (results in the README). How to build and flash is the
README's job; this page is about why the port looks the way it does.

## Why ESP-IDF needed its own shape

The two systems FP-RISC already had sit at opposite ends:

- **bare-metal** (`machine/virt`): the runtime owns the machine. It boots
  the harts, owns every trap, drives the CLINT for doorbells and timers, and
  takes all of RAM from a linker symbol. It assumes almost nothing, because
  nothing else is there.
- **posix** (`machine/posix`): the runtime is a process. The OS supplies
  threads, virtual memory with guard pages, signals, a file system and a
  clock, and the runtime borrows them.

ESP-IDF is neither. It is an RTOS that owns boot, every interrupt, the heap
and both cores, like an OS does. But it has no process, no virtual memory,
and no files unless asked, and the hardware (GPIO, the radio) is the reason
to be there at all. Most decisions below follow from sharing the chip with a
system that owns it, while getting none of the protection an OS would give.

## Decisions

Each entry gives the choice, the alternative that was turned down, and what
the choice costs.

### 1. Its own system, not a flavour of posix

`--system=esp-idf` rather than `--system=posix` with an ESP backend. The ISA
is rv32 while posix lowers to the host's, there is no process for `std/os`
to stand on, and the useful features are not POSIX calls. The reasoning is
in PROFILES.md. **Cost:** the compiler flag is thin. It selects the same rv32
code generator as `--system=bare-metal --target=rv32` and adds only refusals,
so nothing in the compiler knows about ESP-IDF.

### 2. A hart is a FreeRTOS task pinned to a core

Each hart is a task created with `xTaskCreatePinnedToCore` at priority 1,
one per core (main.c). **Alternative:** take a core away from FreeRTOS and
run the hart loop on it bare, the way `machine/virt` does. That would lose
IDF's drivers, interrupts and timers on that core, and ESP-Hosted's tasks
need both cores to be schedulable. **Cost:**
- Every IDF task outranks the harts, so any of them can preempt an actor.
  That is deliberate: lwIP and the SDIO transport produce what actors wait
  for. It also means actor latency is IDF's to decide.
- A CPU-bound actor keeps IDLE off its core indefinitely, so the idle-task
  watchdog checks are switched off (`sdkconfig.defaults`). A real hang on a
  hart is no longer caught by that watchdog.

### 3. `tp` holds the hart pointer, overwriting IDF's thread pointer

Generated code reaches the running hart through `tp` on every system, and
FreeRTOS saves and restores the live `tp` per task, so a hart task simply
sets its own (hal.c). **Alternative:** another register, or a call to
`pvTaskGetThreadLocalStoragePointer` per access. `gp` is IDF's global
pointer, the callee-saved registers belong to generated code, and a call
per access would slow every hart-local read. **Cost:** on RISC-V, IDF uses
`tp` for C thread-local storage. Any C code on a hart task that touches a
`__thread` variable reads through the hart block instead. IDF 5.3 has no
such variable on the paths the primitives call, but nothing enforces that.
A later IDF that adds one fails silently.

### 4. Park and wake are task notifications, with a 20 ms cap

`hal_wfi` waits on the task's notification and `hal_ipi_send` gives it,
from an ISR if need be. The wait is capped at 20 ms, the same rule as
`machine/posix`: no wake source may be load-bearing. **Cost:** an idle
board still wakes each hart about 50 times a second.

### 5. The runtime's heap is one PSRAM block, claimed at boot

`hal_heap_span` takes the largest PSRAM block less a sixteenth, about
30 MB, once. `CONFIG_SPIRAM_USE_CAPS_ALLOC` keeps plain `malloc` in internal
RAM, so IDF's own allocations never compete for PSRAM. **Alternative:** grow
the runtime heap through `heap_caps_malloc` on demand, the way posix grows a
reservation. **Cost:**
- The split is fixed at boot. `hal_heap_release` is a no-op, and IDF cannot
  get PSRAM back from the runtime.
- Actor stacks live in PSRAM, which is slower than internal SRAM and runs at
  the default 20 MHz here.
- IDF's external-RAM documentation says PSRAM is unreachable while the flash
  cache is disabled, for example during a flash write. A primitive that runs
  on an actor's stack must therefore never write flash. This was not tested
  here. It is one more reason blocking IDF work runs in the broker, whose
  stack is internal (decision 7).

### 6. The context switch saves the float registers, and never restores `gp`

IDF compiles for the ilp32f ABI, where `fs0`-`fs11` are callee-saved, so
`ctx.S` saves 28 words where `machine/virt` saves 16. **Cost:** the size of a
saved context became a knob in shared code (`FPR_CTX_WORDS` in fpr.h),
chosen by one machine layer. `gp` is IDF's global pointer and is left
alone. Restoring it from a fabricated first context, which sets only
`ra` and `sp`, started new actors with `gp = 0`. The only symptom was a
watchdog reset, because the panic handler reads globals through `gp` too.

### 7. Blocking IDF calls are jobs on a broker task

A radio call can take seconds: a scan, or an RPC to the C6 that times out
after 5 s. Run on a hart, it would stall every actor on that core. So
`Esp.wifiScan` and friends queue a job to one broker task (`wifi.c`), which
is allowed to block. On completion it raises an interrupt that the runtime
delivers to the actor bound with `Sys.irqBind`. `std/esp`'s `job` wraps that
so only the calling actor waits. **Alternative:** a task per call, or calling
IDF directly from the actor. **Cost:**
- Jobs run one at a time. A 5 s BLE scan delays every Wi-Fi job behind it.
- Job slots take interrupt numbers 900 to 963, a range carved out of the
  IRQ space by convention, not by anything that reserves it.
- Each call spawns a helper actor and binds an interrupt. That is heavy for
  a status query.
- The deadlock detector had to learn that an actor waiting on an interrupt
  is not stuck (`g_irq_waiting`), and later that a sleeper is not either
  (see below).

### 8. Results come back as tab-separated text

A job returns a string, one line per item and fields split by tabs;
`std/esp`'s `rows` splits it. **Alternative:** build FP-RISC lists and records
in C. That needs the object layout in C. The rv32 bring-up showed how easy
that is to get wrong: the runtime's own C built lists with a 64-bit-only
layout (`FPR_FLD` below). It also needs a type contract per result.
**Cost:**
- The results are stringly typed, and numbers come back as text.
- A field cannot contain a tab or a newline. BLE names are sanitized. Wi-Fi
  SSIDs are not, so an SSID containing a tab shifts the row's fields.

### 9. Board features are body-less signatures in `std/esp`

`Esp.core : Unit -> Int .` with no body is resolved at link time to
`fpr_g_Esp_x2ecore` in `esp.c`. This is the tree's foreign-function rule
(HAL.md). **Cost:** `std/esp` is a std module that links on one system only.
Anywhere else it fails at link time on the missing `fpr_g_` names, which is
the matrix's rule, not a clear message.

### 10. The build runs outside `fpr build`

`machine/esp-idf/build.sh` compiles the program, copies the generated
units, then hands over to `idf.py`. **Alternative:** `fpr build
--system=esp-idf` driving `idf.py` itself. That would pull CMake, the IDF
Python environment and the component manager into `fpr`. **Cost:** two
entry points, and `fpr run` means nothing for this system.

## Workarounds that exist only because of ESP-IDF

None of these would be needed on posix or bare metal. Each is a candidate to
delete when its cause goes away.

| Workaround | Where | Why | Risk while it stays |
|---|---|---|---|
| Hardware stack guard off | `sdkconfig.defaults` | It checks `sp` against the FreeRTOS task's stack, and actors run on their own stacks, so every switch looked like an overflow | IDF's overflow check is gone for hart tasks |
| Idle-task watchdog checks off | `sdkconfig.defaults` | A CPU-bound hart keeps IDLE off its core (decision 2) | A hung hart is not reported |
| No stack guards | `hal.c`: `hal_stack_guard` is a no-op | No MMU; the P4's PMP or a debug watchpoint would be the tool, and neither is wired up | FP-RISC code checks its own stack window and grows it. C code that overruns an actor stack corrupts the block below, silently |
| ESP-Hosted buffers in PSRAM | `sdkconfig.defaults`: `MEMPOOL_PREFER_SPIRAM` | ESP-Hosted initialises in a C constructor, before the scheduler frees the startup stacks. Only about 110 KB of internal RAM exists then, and its buffers used it all, so FreeRTOS put its idle stacks in RTC RAM and asserted | Transport buffers are in slower memory |
| `sdmmc_req` log tag silenced | `main.c` | IDF 5.3's SDMMC driver assumes no SDIO and logs the C6 link's between-transfer interrupts as errors, dozens a second | A real SDMMC error, for example from an SD card added later, is silenced too |
| BT controller start treated as optional | `ble.c` | The board's C6 firmware (version 0.0.0) ignores that RPC but already runs its controller | 5 s lost on first BLE use. A failed bring-up is remembered, so BLE never retries until reset |
| `ESP_IDF_VERSION` exported by the build | `build.sh` | ESP-Hosted's Kconfig compares it, and IDF defines it only from 5.4 | Tied to how IDF's git tags are spelled |
| `CONFIG_WIFI_RMT_CACHE_TX_BUFFER_NUM` defined by hand | `wifi.c` | esp_wifi_remote 1.6.3 takes headers and Kconfig from two different IDF revisions on 5.3.2 | The value (32) may drift from what the component expects |
| `env.sh` instead of `export.sh` | `machine/esp-idf/env.sh` | `export.sh` refuses to run without openocd | Paths are guessed from `~/.espressif` |
| Borrowed context fabrication | `project/main/CMakeLists.txt` compiles `machine/virt/ctx_fab.c` | Same first-context shape on both | One machine layer depends on another's file |
| A program's end does not end anything | `hal.c`: `hal_poweroff` prints and parks | A board has nowhere to exit to | The radio and IDF tasks keep running. Running again needs a reset |
| Time masked to 30 bits | `esp.c` | Int is 31 bits on rv32 | `Esp.ms` wraps after about 12 days. `Sys.timeUs` wraps after about 18 minutes, while the same name on posix does not wrap. A program that is correct on posix can be wrong here |
| `sdkconfig.defaults` applies to a fresh config only | IDF behaviour | A build directory keeps its sdkconfig | Editing the defaults does nothing until `BUILD/sdkconfig` is deleted |
| Component versions pinned | `project/main/idf_component.yml` | They match the firmware the board shipped with | Held at 2.12.11 while the C6 runs 0.0.0: ESP-Hosted warns of a version mismatch at boot |
| Runtime sizes set in CMake | `project/main/CMakeLists.txt`: `FPR_NHARTS=2`, `FPR_STACK_SZ` 64 KiB, `FPR_SLAB_SZ` 32 KiB | Two cores; first stacks half and slabs an eighth of the defaults (128 KiB, 256 KiB) | Tuning, not measured. Stacks still grow on demand |

## Changes the port forced into shared code

These landed in `runtime/` and the compiler. They are not ESP-specific: any
32-bit target, and in one case every system, needed them.

- **`FPR_FLD(p, i)`** (fpr.h): the runtime's C built lists and tuples with
  `((V *)p)[1 + i]`. That equals the header-plus-fields layout the code
  generator emits only when a word is 8 bytes. On rv32 the first field
  landed on the header, and `tests/memory.fpr` failed with "no matching
  clause for nth" on the list `Sys.memInfo` returns.
- **A locked 64-bit timer deadline** (actors.c): rv32 has no 64-bit atomics,
  so the deadline is read and written under a lock where a word is 32 bits.
- **`FPR_CTX_WORDS`** (fpr.h): see decision 6.
- **The deadlock detector and sleepers** (actors.c): it declared a deadlock
  whenever more actors were blocked than sleeping. An actor waiting on a
  message a sleeper would send after more than 2 s was therefore reported as
  a deadlock. The board's Wi-Fi example found it, and it reproduced on
  posix. Now any sleeper means not deadlocked
  (`tests/base/sleepwait.fpr`).
- **`--system=esp-idf`** (Compile.hs, Target.hs, Main.hs): see decision 1.

## Toward merging with posix

Status: proposed, not implemented. Checked against the ESP-IDF 5.3.2
source on 2026-09-23; nothing below has been built.

Decision 1 split ESP-IDF off because of what differed on the day: the ISA,
the missing process, and the hardware. The first two describe the host, not
the API the runtime talks to. ESP-IDF implements most of POSIX: pthreads
over FreeRTOS, newlib's clocks, `poll`, lwIP's BSD sockets, and a VFS for
files and the UART. So the long-run shape could be **one posix system with
more than one kind of host**. The ISA would be a separate axis, and everything
hardware-specific would move out of the machine layer into platform libraries.

### What machine/posix uses, and what ESP-IDF 5.3 has

| machine/posix uses | for | ESP-IDF 5.3 | in a merged tree |
|---|---|---|---|
| `pthread_create`, `pthread_cond_timedwait` | harts; park and wake | yes (the `pthread` component). Core pinning goes through `esp_pthread_set_cfg` | shared; pinning is a per-host line |
| `clock_gettime`, sleeping | `hal_mtime`, host sleeps | yes (`newlib/time.c`); sleeping is `usleep` | shared |
| `sysconf(_SC_NPROCESSORS_ONLN)` | how many harts | yes (`newlib/sysconf.c`) | shared; also retires the fixed `FPR_NHARTS=2` |
| `mmap` reservation, `madvise` | a heap that grows | none: no MMU | per-host: today's one `heap_caps` block |
| `mprotect` guard pages, `sigaction` on SIGSEGV/SIGBUS, `sigaltstack` | stack guards; a named panic on overflow | none | per-host: nothing today; the PMP or a debug watchpoint later |
| `fork`, `execvp`, `waitpid`, `kill`, `pipe` | `Os.run`, child processes | none (`kill` is a stub) | not provided: a program using `std/proc` fails at link time on its `fpr_g_Os_` name, the existing rule |
| `socket`, `bind`, `listen`, `accept`, `connect`, `setsockopt`, `getaddrinfo` | `std/tcp`, `std/poller`, servers | yes, lwIP (`getaddrinfo` is a lwIP macro) | shared, once a network interface is up |
| `poll`, plus a self-pipe to wake the watcher | `Os.poll`, the `Os.watch*` watcher thread | `poll` yes (`newlib/poll.c`, over `select`); no `pipe`, but `eventfd` (`vfs_eventfd.c`) | shared; the watcher wakes through an eventfd where there is no pipe |
| `opendir`, `readdir`, `stat`, `mkdir`, `rename`, `getcwd` | `std/file`, `std/dir` | yes through the VFS, once a filesystem (FAT, SPIFFS, LittleFS) is mounted | shared; mounting is a per-host boot step |
| `tcsetattr` | `std/term` raw mode | the VFS has it for UART consoles | probably shared; untested |
| argv, `getenv`, the exit status | `Sys.args`, `Sys.env`, `Sys.exit` | newlib `getenv` over an empty environment; no argv; nothing to exit to | defined but trivial: no arguments, `Err "unset"`, and the end-of-program path |

The posix watcher and this port's job broker are the same idea. A host
thread does the blocking work, then raises an interrupt that the runtime
delivers to a bound actor (hal.c's "external interrupts from host threads"
on posix; `hal_irq_raise` here). In a merged tree there would be one such
mechanism, with the Wi-Fi and BLE jobs as its users.

### The shape

- **A posix core** in `machine/posix`: harts on pthreads, park and wake on
  condition variables, the clock, streams, sockets and the watcher, files.
  It is written against the POSIX subset both kinds of host have.
- **Per-host pieces** behind the existing machine-layer functions, one small
  file each:
  - boot (`main()` versus `app_main`)
  - the heap (a reservation versus a claimed block)
  - stack guards (`mprotect` versus nothing yet)
  - hart pinning
  - the context switch (`machine/unix/ctx_*.S` versus the rv32 `ctx.S`)
  - processes, where the host has them
  - the ESP-IDF workarounds listed above
- **Platform libraries** for what POSIX does not cover. Each is a C file that
  uses its platform's own library, plus a std module of body-less
  signatures:

  | library | ESP-IDF implementation | what another platform could use |
  |---|---|---|
  | `wifi.c` / `std/wifi` | `esp_wifi` through `esp_wifi_remote` and ESP-Hosted | nl80211 or NetworkManager on Linux |
  | `bluetooth.c` / `std/ble` | NimBLE over ESP-Hosted's VHCI | BlueZ on Linux, CoreBluetooth on macOS |
  | `gpio.c` / `std/gpio` | `gpio_ll` register reads, the `driver/gpio` API | libgpiod on Linux |
  | `nvs.c` / `std/nvs` | `nvs_flash` | a file |

  The module names say what the facility is, not whose it is: `Wifi.scan`,
  not `Esp.wifiScan`. A program that uses `std/ble` then builds wherever
  some `bluetooth.c` exists, and fails at link time by name where none does.
  That is how `std/dir` already behaves on a system without directories. A
  library is linked only when the program imports it, so an image carries
  NimBLE only if it uses Bluetooth.

### What changes elsewhere

- **The compiler.** `--system=posix` picks the host's ISA today. A merge
  would make the ISA its own axis: `--system=posix --target=rv32` for
  ESP-IDF, with `--system=esp-idf` kept as the 1.x-style spelling of it.
- **The build.** `fpr build` would need a host that builds through `idf.py`,
  or it would hand off to `build.sh` as now. The IDF project, its
  `sdkconfig.defaults` and its component manifest stay per-host either way.
- **The Base promise.** docs/BASE.md promises a posix program its command
  line, environment, exit status and files. On ESP-IDF those exist but mean
  little. PROFILES.md would have to say that a posix host may grant a
  subset, which the link-time rule already enforces name by name.
- **Result types.** Decision 8's tab-separated text was acceptable for one
  board. Interfaces shared across platforms should return typed values.

### Order of work

1. Split `machine/posix` into the core and its per-host pieces with no change
   in behaviour. The posix suites (`check_base`, `check_std`,
   `check_machine`) are the guard.
2. Build that core against ESP-IDF, replacing this layer's `hal.c` and
   `main.c` piece by piece. Keep the task-notification park unless
   condition variables measure as fast on the board.
3. Merge the job broker into the watcher mechanism.
4. Move `wifi.c` and `ble.c` out of `machine/esp-idf` into platform
   libraries with neutral std modules. GPIO and NVS follow.
5. Sockets over lwIP. This needs station mode, which waits on how
   credentials are supplied.

**What would not merge.** No MMU means no guard pages and no growing heap,
so those stay per-host. `tp` still gets overwritten on hart tasks, and every
workaround in the table above stays with the ESP-IDF host. The merge moves
the boundary, it does not remove it. What it removes is a second copy of
threads, park and wake, sockets and files, and hardware code sitting in a
machine layer.

## Left open

- **Float on rv32.** A Float literal is split into 32-bit halves, and the
  high half does not fit a tagged 31-bit word, so the compiler refuses it.
  The Vec float fast paths also emit double-precision instructions the P4
  lacks. This needs a Float representation for 32-bit targets, a language
  decision.
- **31-bit Int.** It is behind the masked clocks above.
- **Station mode, sockets, `std/os`.** lwIP's sockets are close to the
  posix ones, so `machine/posix`'s socket and poller code is the model.
- **GPIO output.** `Esp.gpioOutput` and `Esp.gpioWrite` exist but have not
  been driven on the board. The board's safe pins are not yet identified.
- **The fixed limits** of this machine layer are registered in BOUNDS.md.
  Several are silent, which the tree's rule does not allow.

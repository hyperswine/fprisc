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

### 3. Original `tp` ownership (superseded on 2026-09-25)

The original port reached the running hart through `tp`, and
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

Status: migration proposed; preparatory HAL and OS-facility splits are implemented
(2026-09-25). The ESP-IDF build still uses its existing machine layer and
`--system=esp-idf`. The review below checks the installed ESP-IDF 5.3.2 source;
sharing the POSIX core on the board has not yet been validated.

Decision 1 split ESP-IDF off because of what differed on the day: the ISA,
the missing process, and the hardware. The first two describe the host, not
the API the runtime talks to. ESP-IDF implements a useful subset of POSIX: pthreads
over FreeRTOS, newlib's clocks, `poll`, lwIP's BSD sockets, and a VFS for
files and the UART. So the long-run shape could be **one posix system with
more than one kind of host**. The ISA would be a separate axis, and everything
hardware-specific would move out of the machine layer into platform libraries.

### What machine/posix uses, and what ESP-IDF 5.3 has

| machine/posix uses | for | ESP-IDF 5.3 | in a merged tree |
|---|---|---|---|
| `pthread_create`, `pthread_cond_timedwait` | harts; park and wake | yes (the `pthread` component). Core pinning goes through `esp_pthread_set_cfg` | shared candidate; boot, task configuration and timed-wait semantics remain host-specific |
| `clock_gettime`, sleeping | `hal_mtime`, host sleeps | yes (`newlib/time.c`); sleeping is `usleep` | shared |
| `sysconf(_SC_NPROCESSORS_ONLN)` | how many harts | yes (`newlib/sysconf.c`) | shared discovery; `FPR_NHARTS` remains the compiled capacity, not the online count |
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
   in behaviour. The POSIX suites (`check_base`, `check_std`) are the guard.
   `check_machine` additionally exercises bare-metal RV64 under QEMU; it is
   a cross-system check, not a POSIX test.
2. Build that core against ESP-IDF, replacing this layer's `hal.c` and
   `main.c` piece by piece. Keep the task-notification park unless
   condition variables measure as fast on the board.
3. Merge the job broker into the watcher mechanism.
4. Move `wifi.c` and `ble.c` out of `machine/esp-idf` into platform
   libraries with neutral std modules. GPIO and NVS follow.
5. Sockets over lwIP. This needs station mode, which waits on how
   credentials are supplied.

**What would not merge.** No MMU means no virtual-memory guard pages or
Unix-style address-space reservation. It does not prohibit growing a heap
with additional allocations: that would require the runtime allocator to
support additional spans (or a suitable contiguous extension). Heap supply
and guards stay per-host. The original `tp` overwrite is now replaced by a TLS slot (milestone below); every
workaround in the table above stays with the ESP-IDF host. The merge moves
the boundary, it does not remove it. What it removes is a second copy of
threads, park and wake, sockets and files, and hardware code sitting in a
machine layer.

## Migration review and first implementation (2026-09-25)

The useful boundary is shared facilities plus explicit host capabilities.
An ISA is not a host: `posix + rv32` alone cannot distinguish ESP-IDF from
another RISC-V host. Preserve host identity in the build plan even if the
public system spelling eventually becomes `posix`. Keep `esp-idf` working
until the replacement builds and runs the same board programs.

The initial change extracts existing Unix HAL code without changing its
functions:

- `machine/posix/hal.c`: console, clock and task-raised IRQ delivery.
- `machine/posix/park.c`: the existing pthread doorbells and timed waits.
- `machine/posix/host.c`: process termination, native context fabrication,
  virtual-memory heap reservation and signal-based stack guards.
- `main.c`: Unix boot, arguments and pthread creation, still host-specific.
- Both `fpr build` and the Makefile link the new translation units.

The subsequent OS extraction separates `os_proc.c` (run/exec), `os_net.c`
(BSD sockets), `os_watch.c` (pthread/self-pipe readiness worker), and
`os_term.c` (Unix terminal lifecycle). `os.c` keeps files, directories,
clocks and generic descriptors. `os_value.h` shares only value construction,
string conversion and buffer helpers. All 27 existing `Os.*` primitive
symbols retain their implementation and owning facility. Both build paths
link the separate objects; no runtime capability registry is introduced.

This is preparatory work in step 1, not completion of the merge. `base.c`
still contains host assumptions. ESP-IDF's source list and working firmware
are unchanged.

Validation of this first extraction on the macOS host: `make fpr`,
`tests/check_base.py`, `tests/check_std.py` (including Logbook), and a
`make posix` hello build/run passed. `tests/check_machine.py` passed under
RV64 QEMU. No board was flashed or reset for this refactor, and these tests
do not establish that the extracted code runs under ESP-IDF.

Before step 2:

1. **Timed waits are not interchangeable.** In IDF 5.3.2,
   `components/pthread/pthread_cond_var.c` implements
   `pthread_condattr_setclock` as a success-returning stub, ignores the
   condition attributes, and uses `gettimeofday` for timed waits. Feeding
   the Unix monotonic absolute deadline to it is wrong. Keep task
   notifications until a correctly adapted wait is tested, including after
   wall-clock adjustments. This is correctness work before benchmarking.
2. **Preserve the host TLS ABI.** The original hart implementation overwrote `tp`.
   Broader libc/pthread use requires a hart-pointer convention
   that preserves IDF TLS, including across actor migration. Merely defining
   `FPR_POSIX` changes the C hart accessor without changing generated rv32
   code; it is not a complete port. The TLS implementation below now addresses
   this boundary without defining `FPR_POSIX` for the whole ESP runtime.
3. **Separate optional implementations at link time.** Leaving `fork` and
   `exec` in the same object as sockets can cause unresolved references even
   for a socket-only program. Process primitives are now extracted. Likewise,
   today's CMake unconditionally lists Wi-Fi/BLE sources and dependencies;
   import-driven component selection is proposed, not implemented. Unsupported
   facilities need meaningful failures, not success-shaped stubs.
4. **Keep capability contracts explicit.** An empty argument list can be
   legitimate on a board, but it does not supply processes or a mounted
   filesystem. Document which Base facilities are available and distinguish
   unavailable APIs from temporarily unavailable services.
5. **Share delivery before execution policy.** The readiness watcher and
   blocking-job broker both signal actors, but have different lifetimes,
   cancellation and result ownership. Reuse their notification mechanism
   without assuming they are interchangeable services. An ISR cannot take
   the POSIX IRQ registration mutex.

Reference: [Espressif's POSIX/pthread support documentation](https://docs.espressif.com/projects/esp-idf/en/v5.3.2/esp32p4/api-reference/system/pthread.html).
The timed-wait finding above is from the installed 5.3.2 implementation,
not an inference from a list of available function names.

## OS extraction validation (2026-09-25)

- Base and std suites passed after the extraction, including child-process
  timeout/environment/streams, sockets and readiness workers, terminal
  restoration, clock behavior and the Logbook replay/restart test.
- `tests/check_posix_facilities.py` compiles each facility separately and
  checks primitive ownership. File/socket objects must not import process,
  pipe, thread-creation or terminal-setup functions. Comparing native object
  symbols before and after the split also preserved all 27 primitives.
- An isolated ESP-IDF 5.3.2 CMake project for ESP32-P4 compiled `os_net.c`
  with the installed cross-toolchain and SDK headers. This is object-build
  evidence only: it does not link an FP-RISC firmware, initialize a network,
  validate the hart/TLS ABI, or exercise sockets on the device.
- `os.c` does not yet compile unchanged against that SDK. The first blocker
  is `<poll.h>` (IDF provides `<sys/poll.h>`). A temporary probe with that
  include corrected then fails on `tm.tm_gmtoff`, which newlib does not
  expose. Clock representation/time-zone conversion needs a defined adapter
  or further extraction, not a fabricated zero offset. Generic descriptors
  also retain Unix SIGPIPE handling and require a behavior audit.

Next: isolate/adapt clock and descriptor differences, settle the host-safe
hart pointer, and then link a small shared-I/O firmware before exercising it
on the board. Keep the existing target and task-notification parking during
that work. No device was flashed or reset in this step.

## Hardware milestone reached (2026-09-25)

The board now runs an FP-RISC firmware using **shared POSIX descriptor and
socket implementations**, with a host-safe hart accessor:

- IDF keeps its `tp`. `fpr_esp_hart` is a real task-local pointer. C reads use
  volatile inline TLS loads, preventing a cached slot address from following
  an actor onto another hart. Generated ESP code uses matching TLS relocations;
  bare-metal lowering is unchanged. Cache tags distinguish these ABIs.
- `os_io.c` contains shared descriptor operations, with IDF's `sys/poll.h`
  include and no Unix SIGPIPE handler on ESP. `os_net.c` preserves lookup
  failure codes in an error string where `gai_strerror` is unavailable.
- The opt-in `posix-io.fpr` firmware passed on the attached P4 after flash and
  reset: TCP request/reply on loopback across two pinned actors, readiness,
  EOF, close, bad-descriptor rejection, actual initialized C TLS on both harts,
  and 64 yielding actors. It completed with status 0 and no observed panic.
  The test does not instrument or prove a cross-hart actor migration.
- The shared primitive boundary check, host Base suite and bare-metal QEMU
  machine suite passed. `tests/check_esp_tls.py` checks generated TLS access,
  unchanged bare-metal rv32 code and separation of cold/warm unit caches.

There is no filesystem mount or radio connection in this test. `std/os`
currently emits wrappers for all its primitives, so importing it still pulls
unsupported symbols into the image: splitting C files alone is insufficient.
The smoke declares only supported signatures. Calendar-clock representation,
VFS behavior and public system/host selection remain unfinished. The watcher
and facility-scoped libraries are covered by the next milestone below. The original task-notification park
is retained. See the machine README for the reproducible build command.

## Shared library and readiness milestone (2026-09-25)

`std/tcp`, `std/stream` and `std/poller` now import narrow internal primitive
modules (`osnet`, `osio`, `oswatch`). They build for IDF without pulling in
unsupported process primitives. The existing `std/os` API remains available.

The shared watcher uses an IDF eventfd to interrupt its blocking poll; Unix
keeps its nonblocking pipe. Replacing the watched set advances a generation
so results from an old in-flight poll cannot be delivered as current readiness.
Failed watcher starts release their descriptors and synchronization objects
without consuming a slot. Tests inject thread-creation failures and force a
concurrent re-arm to check these paths on the desktop.

Hardware testing also exposed a runtime RV32 bug: `receiveNow` wrote its
payload at word index 1, overwriting the 8-byte result header on a 32-bit
machine. It now uses the shared field accessor. The new smoke checks this
result directly before exercising queued poller requests.

A fresh flash/reset of `machine/esp-idf/examples/posix-poller.fpr` on P4 rev 1.3,
IDF 5.3.2 passed ten loopback TCP request/reply exchanges through `Stream.readOn`
and `Poller.await`, EOF/close and TLS checks on both pinned cores. It reported
40 watcher readiness interrupts and status 0, with no fallback polling or
panic. The desktop std suite, Base suite and facility/watcher checks passed.
This establishes loopback integration, not external networking or load capacity.

Watcher lifecycle remains incomplete at the library level: at most 24
simultaneous watchers (IRQ IDs 1000–1023), and no automatic release when its
owner exits. The low-level close operation is covered below. The previous 64-slot limit exceeded the IRQ controller's range; excess
opens now fail explicitly instead of creating unusable watchers. See BOUNDS.md.

## Explicit watcher teardown (2026-09-25)

`Os.watchClose : Int -> Bool` now starts shutdown without joining a worker on
an actor's hart. False means yield/sleep and retry; True means the worker has
finished using its buffers and wake descriptor and the handle has been released.
The slot can then be reused. Registry lookup and close use a shared lock order
so an in-flight arm/take cannot race control-block reclamation.

The caller must own the handle, stop issuing arm/take calls before closing,
finish the handshake, and never use the handle after True. As with Unix fds,
reusing a stale handle can address a new resource. Shutdown does not consume
or cancel IRQ messages already delivered, unbind IRQ actors, or wake clients
blocked in `Poller.await`. Use the coordinated library stop below instead of
closing an active Poller's low-level handle directly.

The attached P4 passed 80 idle/armed close/reopen cycles, then the ten shared
TCP exchanges with 40 interrupts, both-core TLS checks and status 0. Desktop
regressions cover descriptor counts, close with a poll result in flight,
releasing all 24 simultaneous watchers, and existing poller behavior. The
hardware test does not measure heap usage or prove long-term absence of leaks.

## Coordinated Poller shutdown (2026-09-25)

`Poller.stop : Poller -> Unit` now cancels registered waiters, disarms the
watcher, asks its helper to unbind its IRQ, waits for the helper's acknowledgement,
closes the host watcher, and acknowledges shutdown. The helper and poller return
normally rather than being killed. The timer fallback supports the same stop.

`Poller.awaitResult : Int -> Poller -> Result Unit String` distinguishes
readiness from `Err "poller stopped"`. The existing `await` remains Unit-returning
and raises that error on cancellation; `Stream.readOn` propagates Err and
`Tcp.serveOn` returns the stop reason. Multiple waiters on one descriptor are
retained instead of overwriting each other. Readiness can race cancellation:
a waiter whose readiness was already processed may complete normally.

This is an **owner-coordinated API**, not a concurrent mailbox-close primitive:
all registration sends must have completed before stop, and no new waits or
concurrent stops may begin. Discard the handle after stop returns. Killing the
poller bypasses cleanup. A future atomic mailbox-close/monitor facility is
needed to safely accept arbitrary registrations racing retirement; the current
protocol deliberately does not claim that guarantee.

`Sys.irqUnbind : Int -> Bool` is called by the bound actor itself. It clears
the source atomically and returns False while the IRQ hart finishes delivery;
the caller sleeps/yields and retries until True. It preserves the actor's IRQ
wait flag if other sources still bind it. This is routing detachment, not
hardware interrupt masking: disable/quiesce the producer separately. Rebinding
a source must be coordinated with the previous recipient's completed unbind.

The P4 passed 80 coordinated start/stop cycles, including duplicate waiter
cancellation, followed by ten TCP exchanges and shutdown of that active poller
(40 readiness interrupts, both-core TLS checks, status 0). The desktop standard
library suite passed, including the new shutdown regression and forced timer
fallback cancellation. The tests establish coordinated teardown and reuse;
they do not establish arbitrary concurrent stop/register safety or automatic
actor-exit cleanup.

## Left open

- **Float on rv32.** A Float literal is split into 32-bit halves, and the
  high half does not fit a tagged 31-bit word, so the compiler refuses it.
  The Vec float fast paths also emit double-precision instructions the P4
  lacks. This needs a Float representation for 32-bit targets, a language
  decision.
- **31-bit Int.** It is behind the masked clocks above.
- **Station mode and remaining `std/os` facilities.** Shared sockets, streams
  and the eventfd watcher pass loopback tests. External connectivity, mounted
  filesystems, calendar-clock adaptation and public target consolidation remain.
- **GPIO output.** `Esp.gpioOutput` and `Esp.gpioWrite` exist but have not
  been driven on the board. The board's safe pins are not yet identified.
- **The fixed limits** of this machine layer are registered in BOUNDS.md.
  Several are silent, which the tree's rule does not allow.

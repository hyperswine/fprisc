# machine/esp-idf: FP-RISC Base on the ESP32-P4

The posix system's esp-idf host: `--host=esp-idf` (docs/2026-09-19-PROFILES.md;
`--system=esp-idf` is the 1.x spelling and still works). An FP-RISC program becomes an
ESP-IDF application: the rv32 code generator's output, `runtime/`, and this
machine layer, built as one IDF project and flashed to the chip.

Why it is built this way, and the workarounds ESP-IDF forced, are in
docs/2026-09-23-ESP-IDF.md; its fixed limits are registered in docs/2026-09-19-BOUNDS.md.

Board it was brought up on: ESP32-P4 rev 1.3 (two rv32imafc cores at
360 MHz, 32 MB PSRAM, 32 MB flash), with an ESP32-C6 on SDIO as its radio,
console on UART0 through a CH343 bridge.

## Build, flash, run

ESP-IDF 5.3 (tested with 5.3.2 under `~/.espressif`). `env.sh` sets up
its tools without `export.sh`, which refuses to run without openocd; `fpr`
sources it when `IDF_PATH` is not set.

```sh
fpr run machine/esp-idf/examples/cores.fpr --host=esp-idf
```

That builds, flashes and becomes the program's console, like `fpr run` of a
posix program:

- The program's output goes to stdout. The runtime's own `[fpr]` lines and
  ESP-IDF's error lines go to stderr; `-v` shows the build and everything
  else.
- Lines on stdin are typed into the board's console.
- `fpr` exits with the program's status: `Program.exit 3` exits 3, a panic
  exits 1. A board reset under the program exits 2. `FPR_ESP_TIMEOUT=N`
  stops waiting after N seconds and exits 124.
- The port is `--port P`, else `FPR_ESP_PORT`, else the one USB serial
  device attached.
- The build goes to `build/esp-idf/<program>`, or `-o DIR`.
- The board has one console, so a program's stderr lines arrive on stdout.

`fpr build prog.fpr --host=esp-idf [-o DIR]` builds without flashing. The
parts underneath are `build.sh` (compile, then `idf.py`), `run.sh` (build,
`esptool` flash, console) and `console.py`, all in this directory.

`tests/check_esp_board.py` runs every example on an attached board this way
and checks their output and exit status. It skips, exit 0, when no board is
attached; `--quick` leaves out the radio examples.

The first build fetches the pinned components listed in
`project/main/idf_component.yml` (ESP-Hosted, esp_wifi_remote and their
dependencies, about 11 MB) from the Espressif component registry.
`FPR_ESP_DEBUG=1 build.sh ...` adds boot markers, a per-second report of
each hart, and a report of any failed allocation.

`sdkconfig.defaults` applies only when a build directory has no sdkconfig
yet. After changing it, delete `BUILD_DIR/sdkconfig`.

## How the runtime sits on ESP-IDF

| runtime need | here |
|---|---|
| a hart | a FreeRTOS task pinned to its core, priority 1 (just above idle) |
| the hart pointer | `fpr_esp_hart` in actual task TLS; IDF retains `tp` |
| park / wake | task notification; the wait is capped at 20 ms or the hart's timer deadline |
| the heap | the largest PSRAM block, less 1/16 left for IDF (about 30 MB) |
| context switch | `ctx.S`: ra, sp, s0-s11, fs0-fs11. Not gp: a fabricated context has gp = 0 |
| blocking IDF calls | jobs on the posix system's broker thread (`machine/posix/os_job.c`, a pthread with an internal stack at priority 5); completion raises an IRQ bound to the waiting actor |
| the console | `stdout` (UART0) |

Two IDF settings matter: the hardware stack guard is off, since it treats
actor stacks as overflows, and the idle-task watchdog checks are off, since
a busy hart never yields to idle.

## What a program can use

- **The chip: `std/esp`.** `core` is the core the caller runs on, `ms` is
  milliseconds since boot (30 bits, so it wraps after about 12 days),
  `freeKb` is free heap, `random` is 30 bits from the hardware RNG.
- **GPIO: `std/gpio`.** `pins`, `level` and `info` read pin state and its
  IO_MUX setup (`describe` puts it in words). `input` configures a pin as an
  input. `output` and `write` exist but have not been exercised on hardware.
- **Wi-Fi through the C6: `std/wifi`.** `info`, `scan`, `startAp ssid pass`,
  `stations`, `stop`, as typed records. `""` is an open network; any other
  password must be 8-63 characters or 64 hex digits, or it is refused.
- **Bluetooth LE through the C6: `std/ble`.** `scan ms` lists address, rssi
  and name, strongest first. `advertise name ms` advertises non-connectable.
- **Files: `std/file`, `std/dir`** on FAT at `/data`; **sockets and HTTP:
  `std/tcp`, `std/stream`, `std/poller`, `std/httpcore`.**

The radio and GPIO libraries live in `platform/esp-idf/`, not in this
machine layer. Radio calls are jobs (`std/job`): each blocks only the calling
actor, while every other actor keeps running on both cores. A program that
does not import `std/wifi` or `std/ble` links neither stack.

## Examples, as measured on the board

| example | shows | result on 2026-09-23 |
|---|---|---|
| `examples/cores.fpr` | actors pinned to each core report that core; CPU-bound work in parallel; cross-core round trips | two fib 27 jobs in 160 ms against 158 ms for one (98% of ideal); 10,000 round trips in 284 ms |
| `examples/gpio.fpr` | a read-only report of all 55 pins, sampled from both cores | pins report their IO_MUX function and level; the SDIO pins show ESP-Hosted's setup |
| `examples/wifi.fpr` | radio info, a scan while a core-1 actor ticks, a WPA2 access point with a random password, client counts for 60 s | 4 networks in 4.8 s; access point up on 192.168.4.1 |
| `examples/ble.fpr` | advertising as `fpr-p4-ble` while scanning three times; a core-1 actor counts throughout | 13 to 14 devices per 5 s scan |

## Board facts found on the way

- **ESP-Hosted starts before the scheduler.** It runs from a C constructor,
  when only about 110 KB of internal RAM is usable. Its transport buffers used
  to take all of it, so FreeRTOS placed its idle stacks in RTC RAM and
  asserted at boot. `CONFIG_ESP_HOSTED_MEMPOOL_PREFER_SPIRAM=y` moves the
  buffers to PSRAM, which the P4's DMA can reach.
- **The C6's firmware is old.** It reports version 0.0.0, and ESP-Hosted
  warns that it should be upgraded. It does not answer the RPC that starts
  the BT controller, which times out after 5 s, but its controller is
  already running, so `platform/esp-idf/bluetooth.c` goes on to the NimBLE sync, which is the real
  test.
- **SDMMC log noise.** IDF 5.3's SDMMC driver logs SDIO interrupts that
  arrive between transfers as errors, dozens a second, although every
  transfer completes. `main.c` silences that one log tag.
- **Flash above 16 MB.** IDF 5.3 warns that it cannot address flash above
  16 MB on this flash model. Images are far smaller than that.

## Limits

- **No Float on rv32.** A Float literal is split into 32-bit halves that do
  not fit a tagged 31-bit word, so the compiler refuses it. The Vec float
  fast paths also emit double-precision instructions, which the P4 lacks.
  Both need a Float representation for 32-bit targets.
- **Int is 31 bits.** Literals must fit in ±2^30, so Unix time does not fit.
  Times here are milliseconds since boot.
- **Radio coverage.** Wi-Fi station mode is not wired up yet. Shared POSIX
  sockets, streams and readiness are tested on loopback; external connectivity
  and the remaining `std/os` facilities are still open.
- **One radio job at a time.** A 5 s BLE scan delays Wi-Fi jobs behind it.
- **PSRAM speed.** PSRAM runs at the default 20 MHz. 200 MHz is available in
  menuconfig but untested.

## Shared POSIX I/O and host TLS milestone (2026-09-25)

The esp-idf host now uses a real TLS hart slot, preserving IDF's `tp`.
Both generated code and C runtime reload it instead of caching its address
across actor switches. Rebuild compiler, generated units and firmware
together; the compiler uses a distinct `rv32-idftls1` unit cache tag.
Bare-metal rv32 keeps its original hart-register convention.

The IDF project links shared `machine/posix/os_io.c` and `os_net.c` (and, since 2026-09-25, all of `machine/posix`).
The following opt-in test initializes lwIP loopback and links a TLS probe:

```sh
make fpr
. machine/esp-idf/env.sh
FPR_ESP_IO_SMOKE=1 machine/esp-idf/build.sh machine/esp-idf/examples/posix-io.fpr /tmp/fpr-posix-io
# Flash using the normal command above, with this build directory.
```

On ESP32-P4 rev 1.3 / IDF 5.3.2, a fresh flash/reset passed TCP request/reply
between actors pinned to different cores, readiness polling, EOF, close,
invalid-descriptor rejection, real C TLS checks on both harts and 64 yielding
actors. The program reported `shared POSIX IO: done`, status 0, without a
panic. This does not prove actor migration occurred in that run, sustained
network load, Wi-Fi connectivity or filesystem support.

The example declares only the primitives it uses: `std/os` currently pulls
in wrappers for every facility, including unsupported processes. No fake
process implementations are linked to make it pass. The next milestone uses
normal library imports and a real readiness watcher, as described below.


## Shared TCP / Stream / Poller milestone (2026-09-25)

```sh
. machine/esp-idf/env.sh
FPR_ESP_IO_SMOKE=1 machine/esp-idf/build.sh machine/esp-idf/examples/posix-poller.fpr /tmp/fpr-posix-poller
```

Flash using the normal command with this build directory. This test uses the
ordinary `std/tcp`, `std/stream` and `std/poller` modules. Their narrow primitive
imports avoid unsupported process APIs; the shared watcher uses IDF eventfd
and pthreads, with readiness delivered through the actor IRQ mechanism.

A fresh flash/reset on the same P4 passed ten TCP exchanges, EOF, a direct RV32
`receiveNow` regression and both-core TLS checks. It reported 40 readiness
interrupts, `shared poller: done`, and status 0 without fallback polling.
The board was left with this test firmware. No external network or filesystem
was configured. Files/directories, calendar clock,
terminal support and public target consolidation remain follow-up work.

The smoke now first closes/reopens 80 low-level watchers, alternating idle
and armed operation. A fresh flash/reset passed that exercise and the TCP
checks above. `Os.watchClose` returns False while teardown is pending; yield
and retry until True, then discard the handle. The 24 slots are reusable.
This primitive releases host resources only. `Poller.stop` now supplies the
coordinated library protocol: registered waiters are cancelled, the IRQ helper
unbinds, and the watcher closes before shutdown is acknowledged. The owner must
ensure registration sends have completed and prevent new waits/concurrent stops;
discard the handle afterward. Automatic owner-exit cleanup remains open.

A subsequent fresh flash/reset passed 80 library start/stop cycles with duplicate
waiter cancellation, then ten TCP exchanges and explicit stop, with 40 readiness
interrupts and status 0. `Stream.readOn` returns `Err "poller stopped"` on
cancellation; direct callers can use `Poller.awaitResult`. See docs/2026-09-23-ESP-IDF.md
for the ownership contract and concurrent registration limitation.

## Access point server and files (2026-09-25)

The project now has its own partition table (`project/partitions.csv`): a
4 MiB app and an 8 MiB FAT partition mounted at `/data`. A build directory
made before this keeps its old sdkconfig and the 1 MiB app partition, which
the current image no longer fits. Delete `BUILD_DIR/sdkconfig` once.

```sh
. machine/esp-idf/env.sh
machine/esp-idf/build.sh machine/esp-idf/examples/ap-server.fpr build/esp-ap
machine/esp-idf/build.sh machine/esp-idf/examples/files.fpr build/esp-files
```

- `examples/ap-server.fpr` checks the access point's password rule, starts
  `fpr-p4-test` with a random WPA2 password, serves HTTP on port 80 and
  checks itself through 192.168.4.1. It prints `READY` with the password,
  then serves until reset. From a phone, join the network and open
  `http://192.168.4.1/`; each request is printed on the console.
- `examples/files.fpr` exercises `std/file` and `std/dir` on `/data`: a boot
  counter that survives resets and reflashes, a tree, append, rename, a
  64 KiB streamed write with an in-place patch, and simultaneous appends
  from both cores. Paths must be absolute (`/data/...`).

Opening the serial port on macOS resets the board, so the access point's
password changes each time a monitor attaches. Read it from the `READY` line.

## Console programs and the radio link (2026-09-25)

`std/program` works on the board: no arguments, an empty environment,
`readLine` from the serial console (it blocks only the reading hart), and
`exit` ends the program for good. `examples/console.fpr` is a plain posix
program that runs on both:

```sh
machine/esp-idf/build.sh machine/esp-idf/examples/console.fpr build/esp-console
```

Type into the serial console; Enter ends a line. A program that does not use
`std/wifi` or `std/ble` no longer starts the link to the C6 at all. One that
does starts it on its first radio call, which takes about 2 s longer.

## Capacity and the stack guard (2026-09-25)

- `examples/load.fpr` measures simultaneous TCP connections. The board
  holds 12 loopback connections at once; the 16th pair outruns its 32
  sockets. Clients from other devices get about 31. A server out of
  sockets now says so on stderr and keeps serving.
- `FPR_ESP_STACK_GUARD=1 fpr run ... --host=esp-idf` arms a watchpoint on
  the running actor's stack bottom, so C code that overruns it stops the
  board by name. It costs about a third of compute speed, so it is for
  development builds; `examples/stack-guard.fpr` shows it, with the probe
  build (`FPR_ESP_IO_SMOKE=1`).


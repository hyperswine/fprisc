# machine/esp-idf: FP-RISC Base on the ESP32-P4

`--system=esp-idf` (docs/PROFILES.md). An FP-RISC program becomes an
ESP-IDF application: the rv32 code generator's output, `runtime/`, and this
machine layer, built as one IDF project and flashed to the chip.

Why it is built this way, and the workarounds ESP-IDF forced, are in
docs/ESP-IDF.md; its fixed limits are registered in docs/BOUNDS.md.

Board it was brought up on: ESP32-P4 rev 1.3 (two rv32imafc cores at
360 MHz, 32 MB PSRAM, 32 MB flash), with an ESP32-C6 on SDIO as its radio,
console on UART0 through a CH343 bridge.

## Build and flash

ESP-IDF 5.3 (tested with 5.3.2 under `~/.espressif`). `env.sh` sets up
its tools without `export.sh`, which refuses to run without openocd.

```sh
. machine/esp-idf/env.sh
machine/esp-idf/build.sh machine/esp-idf/examples/cores.fpr build/esp
idf.py -C machine/esp-idf/project -B build/esp/idf -DSDKCONFIG=build/esp/sdkconfig -p /dev/cu.usbmodemXXXX flash monitor
```

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
| the hart pointer | `tp`, which FreeRTOS saves per task (IDF 5.3 C uses no TLS on this path) |
| park / wake | task notification; the wait is capped at 20 ms or the hart's timer deadline |
| the heap | the largest PSRAM block, less 1/16 left for IDF (about 30 MB) |
| context switch | `ctx.S`: ra, sp, s0-s11, fs0-fs11. Not gp: a fabricated context has gp = 0 |
| blocking IDF calls | jobs on a broker task; completion raises an IRQ bound to the waiting actor |
| the console | `stdout` (UART0) |

Two IDF settings matter: the hardware stack guard is off, since it treats
actor stacks as overflows, and the idle-task watchdog checks are off, since
a busy hart never yields to idle.

## What a program can use: `std/esp`

- **Cores and time.** `Esp.core` is the core the caller runs on, `Esp.ms`
  is milliseconds since boot (30 bits, so it wraps after about 12 days),
  `Esp.freeKb` is free heap, `Esp.random` is 30 bits from the hardware RNG.
- **GPIO.** `gpioPins`, `gpioLevel` and `gpioInfo` read pin state and its
  IO_MUX setup. `gpioInput` configures a pin as an input. `gpioOutput` and
  `gpioWrite` exist but have not been exercised on hardware.
- **Wi-Fi through the C6.** `wifiInfo`, `wifiScan`, `wifiAp ssid pass`
  (WPA2 when the password has 8 or more characters), `wifiApClients`,
  `wifiStop`.
- **Bluetooth LE through the C6.** `bleScan ms` lists address, rssi and
  name, strongest first. `bleAdvertise name ms` advertises non-connectable.

Radio calls are jobs. `job` blocks only the calling actor, while every other
actor keeps running on both cores. Results are rows of text fields.

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
  already running, so `ble.c` goes on to the NimBLE sync, which is the real
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
- **Radio coverage.** Wi-Fi station mode, sockets and `std/os` are not
  wired up yet. lwIP's BSD sockets are the natural next step, and
  machine/posix's socket and poller code is the model for them.
- **One radio job at a time.** A 5 s BLE scan delays Wi-Fi jobs behind it.
- **PSRAM speed.** PSRAM runs at the default 20 MHz. 200 MHz is available in
  menuconfig but untested.

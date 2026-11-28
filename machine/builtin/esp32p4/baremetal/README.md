# ESP32-P4 bare-metal Builtin

Build from the FP-RISC repository root with CMake, Espressif RV32 GCC,
and esptool 4.x on PATH. Run `make fpr` first if the compiler is missing.

    machine/builtin/esp32p4/baremetal/build.sh build/p4-baremetal
    python3 machine/builtin/esp32p4/baremetal/check.py PORT build/p4-baremetal/selfcheck.bin

The build accepts `CC` and `ESPTOOL` overrides. It uses the existing
`riscv32imc` Builtin compiler target and the same FP-RISC arithmetic
program as the ESP32-C3 check. The P4 entry parks secondary harts,
zeros BSS and starts the Builtin runtime on hart 0. Code, heap and
stack use internal SRAM. UART0 uses the ROM downloader's 115,200 baud
setup. The checker sends a query after the ROM handoff, verifies the
result, and resets back to normal flash boot.

## Hardware qualification

The board reported ESP32-P4 rev 1.3, a 40 MHz crystal and 32 MiB flash
through its CH343 UART bridge. A full flash read matched the device MD5
and the partition-table digest verified. The active layout has a 4 MiB
factory app, an 8 MiB storage partition and no OTA slots.

The ROM loaded the 3,944-byte segment at `0x4ff10000` and executed it
there. The attached board returned the expected integer result and
returned from FP-RISC main.

    P4 BARE METAL integer self-check: 827204 [PASS]
    FPR DONE

## Board-specific BLE HCI check

    python3 machine/builtin/esp32p4/baremetal/check.py --ble-hci PORT build/p4-baremetal/selfcheck.bin

Use this mode on the qualified P4 board with the onboard ESP32-C6 and
its installed ESP-Hosted firmware. The probe pulses companion EN on
GPIO54, then uses SDMMC slot 1 in 1-bit mode at 400 kHz. GPIO18 and
GPIO19 carry clock and command. GPIO14 is DAT0. The probe confirms the
C6 chip ID in the startup frame and sends HCI Reset (opcode `0x0c03`)
over the hardware SDIO link. The expected H4 response is
`04 0e 04 01 03 0c 00`, a matching Command Complete with status zero.

Both chips' flash contents stay intact. This checks the BLE controller
command path and leaves Wi-Fi work deferred.

## SYSTIMER, CLIC and GPIO checks

    python3 machine/builtin/esp32p4/baremetal/check.py --timer PORT build/p4-baremetal/selfcheck.bin
    python3 machine/builtin/esp32p4/baremetal/check.py --button-dtr PORT build/p4-baremetal/selfcheck.bin

UNIT0 uses the 40 MHz crystal and fixed divide-by-2.5 clock. The timer
check recovers from a machine ECALL and verifies three absolute deadlines
50 ms apart, each dispatched through a SYSTIMER interrupt after WFI.
Core 0 uses direct CLIC dispatch with separate level-triggered lines for
the timer and GPIO.

The GPIO test is specific to the qualified board's CH343 auto-download
wiring. It drives the same active-low GPIO35 input as BOOT using DTR,
with RTS deasserted. A synthetic 7 ms bounce on both edges produced six
hardware IRQs and two transitions after 25 ms of stability. The check
returns the board to normal flash boot.

## Standalone Builtin BLE advertising

Set `P4_SOURCE` to the path of a custom Builtin program when building a
RAM image. Import the port's `lib/ble.fpr` from that program. `start` takes a
canonical 128-bit UUID string and returns zero on success. An active
advertiser can be started again with the same UUID. Call `service`
regularly so the P4 can detect and recover from companion resets.
`stop` disables advertising. This board profile uses the installed
ESP-Hosted controller firmware on the C6 and the P4's native SDIO
driver. The advertiser shares HCI command construction and response
checking with ESP32-C3.

The sample exposes serial commands for start, stop, statistics, and a
physical C6 EN pulse. On macOS, build the shared CoreBluetooth observer
and run:

    P4_BLE_SAMPLE=1 machine/builtin/esp32p4/baremetal/build.sh build/p4-ble
    swiftc machine/builtin/esp32c3/baremetal/radio/observe.swift \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
        -Xlinker machine/builtin/esp32c3/baremetal/radio/BluetoothInfo.plist \
        -o build/p4-ble/observe
    python3 machine/builtin/esp32p4/baremetal/check_ble.py PORT \
        build/p4-ble/selfcheck.bin build/p4-ble/observe --seconds 1800

The check requires discovery of `ACAF3791-694C-4F66-AC82-12C4D04D35D9`,
a full 30-second scan with no matching advertisement after stop, and
rediscovery after three stop/start cycles and after the EN pulse. The
endurance option samples the P4 Builtin heap and repeats discovery once
per minute. It measures the P4 host heap. The C6 controller's internal
allocator is outside its instrumentation.

On the attached board the RAM prototype passed 1,800.340 seconds of
endurance with 31 Mac discoveries and zero live or peak P4 Builtin heap
bytes. The release build repeated discovery, silence, restart and
recovery after a physical C6 EN pulse with host state left intact.
It also passed the arithmetic, GPIO and HCI Reset checks again.

Custom Builtin code can use `lib/clock.fpr` for millisecond timestamps
and absolute deadlines. The release image verified a 75 ms sleep
through the FP-RISC clock API.

## Cold-boot journal qualification

The board's original flash layout contains a factory app and storage.
The qualification tool adds one test OTA slot, an OTA selector, a
64 KiB append-only journal, and a separate 4 KiB erase test sector.
They use verified-erased space beyond the original partitions. The
original partition-table sector and full flash image must be backed
up before staging. The tool checks the original bootloader and factory
app digests, verifies every write and, during restore, compares flash
outside its test ranges.

    P4_FLASH_CHECK=1 machine/builtin/esp32p4/baremetal/build.sh build/p4-flash
    python3 machine/builtin/esp32p4/baremetal/flash_bench.py plan BACKUP SHA256 \
        --image build/p4-flash/selfcheck.bin
    python3 machine/builtin/esp32p4/baremetal/flash_bench.py install BACKUP SHA256 \
        --port PORT --mac MAC --image build/p4-flash/selfcheck.bin
    python3 machine/builtin/esp32p4/baremetal/check_flash.py PORT power-cycle
    python3 machine/builtin/esp32p4/baremetal/check_flash.py PORT endurance
    python3 machine/builtin/esp32p4/baremetal/flash_bench.py restore BACKUP SHA256 \
        --port PORT --mac MAC

The flash image uses the board's existing second-stage bootloader and
executes from internal SRAM. It exercises `lib/journal.fpr` during
startup. The timed check programs and erases the scratch sector,
confirms that a committed record survives power loss, and checks that
the next record is skipped when power fails after its body is verified
but before the commit marker is programmed. The checker holds the CH343
serial session open until it sees the USB disconnect and reconnect. This
prevents reopening the port from resetting the P4 before power is cut.
Endurance appends once per minute for at least two hours and replays
the complete log after reset.

The journal shares the C3 raw record format. Its flash driver validates
both data partitions and bounds each transfer to the requested region.
The scratch erase routine has a fixed, separate sector. After testing,
restore puts back the original table, verifies the test allocation is
erased, and checks the bootloader's factory app load message on UART.

The P4 loader requires both mapped segments even for an SRAM-only
application. The 65,616-byte bench image supplies them and starts at
`0x4ff10000`. On the target, the bootloader selected `0xd10000`,
the Builtin journal API and integer self-check passed, and the
scratch sector passed program, full readback, erase, and full erased
readback.

During the physical power-cut run, the USB-UART device disappeared
for 5.23 seconds. The flash boot replayed committed record 1 and skipped
record 2, whose body had been verified before the cut but whose commit
marker was still erased. The next append succeeded and replay returned
records 1 and 3 in order.

The endurance run passed on the same P4 after 7,200.101 seconds, with
121 acknowledged appends and a maximum sample interval of 60.015
seconds. All 123 committed records matched before and after reset.

The restore audit matched the original bootloader, factory app, NVS,
PHY data and storage against the verified 32 MiB backup. It restored
the original partition table, erased and checked the temporary
allocation, and verified that flash outside the test ranges stayed
unchanged through the restore. The bootloader confirmed the original
factory app at `0x10000` over UART. The onboard C6 retained its
installed firmware.

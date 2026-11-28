# ESP32-C3 bare-metal RAM self-check

From the repository root, build the compiler with `make fpr`. Put CMake,
the RV32 Espressif GCC cross-compiler and esptool 4.x on PATH. Use the
Python interpreter that has esptool installed for the hardware check.

    machine/builtin/esp32c3/baremetal/build.sh build/c3-baremetal
    python machine/builtin/esp32c3/baremetal/check.py PORT build/c3-baremetal/selfcheck.bin

The builder accepts CC and ESPTOOL executable overrides. The CMake script
invokes the same Builtin compiler and assembles the same selfcheck.fpr as
the ESP-IDF port. Inspect selfcheck.map in the build directory for the
linked objects. Firmware inputs are startup assembly, a polling USB
Serial/JTAG console, the FP-RISC guest and runtime, and compiler support.

The checker enters the C3 ROM downloader over native USB, loads code and
data into separate SRAM ranges, and verifies the computed result and the
return from FP-RISC main. The console uses the USB configuration inherited
from the downloader. Execution ends in an idle loop; reset resumes the
installed flash firmware. The image leaves GPIO8 alone.

Verified on the physical C3 with GCC 13.2.0 and esptool 4.9.0:

    C3 BARE METAL integer self-check: 827204 [PASS]
    FPR DONE

## BOOT button on the SuperMini

    machine/builtin/esp32c3/baremetal/build.sh build/c3-button button
    python machine/builtin/esp32c3/baremetal/check.py --button PORT build/c3-button/button.bin

Start with BOOT released. When the checker reports GPIO9 high, hold BOOT
briefly and release it. The FP-RISC program imports the board definition and
the same GPIO library used by the IDF examples. It samples once per millisecond and requires a 20 ms debounce window.
It sends each accepted electrical level with an eight-byte little-endian
millisecond timestamp over USB. The checker first compares a one-second
device deadline with the host monotonic clock, then requires high, low,
high and a return from main. GPIO8 stays untouched.

The Clock API reads a latched snapshot of the 52-bit SYSTIMER UNIT0 counter
at 16 MHz and returns milliseconds. For this RAM image the counter is
already running at ROM handoff. Deadline waits arm SYSTIMER comparator 0 and idle in WFI. See chapter 10 of the [ESP32-C3 TRM](https://documentation.espressif.com/esp32-c3_technical_reference_manual_en.pdf).

The polling GPIO backend programs the C3 IO MUX and GPIO Matrix directly.
It implements input with optional pull-up, level reads, push-pull and
open-drain output, and level writes on the same header pins as the IDF
backend. An invalid pin or operation for the configured direction returns
-EINVAL. This hardware check exercises the input path.

The button example arms both GPIO9 edges, waits for a GPIO interrupt, then
uses timer interrupts to sample during the debounce window. The GPIO ISR
acknowledges the status and queues up to seven samples for the main loop.
The queue reports -EOVERFLOW if it fills. The hardware can coalesce edges
that arrive before the status bit is serviced. Unexpected traps print
mcause and mepc over USB and halt.

On the physical C3, the alarm test measured 1,000 ms on both the device
and the Mac. The GPIO interrupt test reported initial high at 1,204 ms,
low at 38,638 ms, and high at 39,710 ms. A temporary breakpoint after
interrupt setup reported cause 3 and PC 0x40380040 over USB.

## Flash boot with the existing C3 bootloader

    machine/builtin/esp32c3/baremetal/build.sh build/c3-flash button flash
    python machine/builtin/esp32c3/baremetal/check.py --flash --button PORT

The flash build produces button-flash.bin, an ESP32-C3 application image for
the existing second-stage bootloader. Its descriptor is mapped from flash.
The bootloader loads executable code and data into SRAM. The application
enables the USB and SYSTIMER clocks, enables the USB pad, and disables the
bootloader RTC watchdog. It waits for the checker to query its identity
over USB, then runs the timed BOOT check. The checker attaches without
resetting the board so the same command works after a cold boot.

Use the adjacent ota_slot.py utility to inspect the live selection, back up
the inactive slot, install button-flash.bin into that slot, and select the
previous slot to roll back. The utility uses the ESP-IDF partition-table
parser on the host. The flash application links the FP-RISC runtime and
compiler support, and uses the bootloader already installed on the board.

The physical C3 cold-booted the 13,824-byte button image from OTA slot 1
after a USB power cycle. The flash identity was visible over USB, the
one-second timer measured 1,000 ms on the C3 and 999.4 ms on the Mac, and
GPIO9 reported both debounced BOOT edges. The rollback selected slot 0
and verified its original image digest. The test then restored the
previous slot 1 image and OTA metadata, matched the pre-test digest over
all 4 MiB of flash, and replayed all 151 records from the restored logger.

## Bare-metal journal

    machine/builtin/esp32c3/baremetal/build.sh build/c3-journal journal flash
    machine/builtin/esp32c3/baremetal/build.sh build/c3-endurance endurance flash

The journal uses the existing FPR-C3-LOG-v1 format and command protocol.
After flash boot, open USB serial with DTR and RTS deasserted, send ASCII
question mark, and read the identity line and journal status byte. The
parent directory's check_journal.py provides the length-prefixed replay
decoder. The endurance image starts after the same identity query and
emits heap and allocation statistics at every checkpoint.

The backend accepts the dedicated 64 KiB fprjournal partition at
0x280000 and checks that no other table entry overlaps it. ROM read and
program calls are confined to that partition. Bounded, aligned transfers
use SRAM buffers, and the cache is suspended around each ROM operation.
The private flash driver also supports single-sector erase for regions
explicitly configured to allow it. It checks 4 KiB alignment and full
sector containment before entering ROM. The journal region allows read and
program only.
The journal verifies the programmed body before writing its commit
marker. Existing records remain available after a partially written
record. SPI initialization comes from the flash bootloader.

Physical verification used one durable append and a separate journal-cut
build. The latter paused immediately before programming the commit word.
After two USB power cycles, replay returned all 151 original records and
the new durable record. Independent flash readback confirmed the new
commit in slot 279, an intact body with erased commit word in slot 280,
and byte-for-byte preservation of the preceding records.

The LED-off endurance build wrote 122 checkpoints at one-minute
intervals on the same C3. Independent flash readback verified their
commit words and CRCs over 7,260,004 ms of device time. Every USB
checkpoint reported three live allocations and 256 bytes of live and
peak heap use. Restoration verified all flash outside the journal
against the original backup. The restored logger replayed all 152
acknowledged records.

A separate bench image verified bounded read, program, and 4 KiB sector
erase through the C3 ROM. It programmed a marker into one verified-blank
sector inside the temporary OTA slot, read it back, erased the sector, and
verified all 4 KiB were erased. The test also checked the permission,
alignment, and range guards.

## Standalone BLE

The bare-metal BLE profile exposes advertising through `../lib/ble.fpr`.
See the [BLE library usage and hardware checks](radio/README.md#build-and-use-standalone-ble-advertising)
for the example, controller pins, and Mac observer.

## Hardware PWM

Both bare-metal ports expose the shared [LEDC PWM library and servo example](../../esp32/README.md).

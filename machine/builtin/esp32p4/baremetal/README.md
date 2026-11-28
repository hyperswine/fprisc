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

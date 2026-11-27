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

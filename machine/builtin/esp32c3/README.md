# ESP32-C3 Builtin with ESP-IDF

One FP-RISC Builtin program runs in IDF's main task. The C3 provides native USB Serial/JTAG. The program can use the on-chip SPI flash as a SPIFFS volume. The default images run from RAM through the ROM downloader. The flash build can also boot directly from an OTA slot.

## Build and run

Build the compiler with `make fpr` at the repository root. Activate ESP-IDF 5.3.2, then run these commands from this directory. Set `PORT` to the C3 USB Serial/JTAG port.

    idf.py -B build/echo -DSDKCONFIG="$PWD/build/echo.config" build
    python check_board.py "$PORT" build/echo/c3_builtin.bin echo

For the arithmetic example, pass `-DFPR_PROGRAM="$PWD/examples/selfcheck.fpr"` in a separate build directory and select `selfcheck` in the runner. The build invokes `fpr compile --system=bare-metal --profile=builtin --target riscv32imc` and assembles the program and imported units with `-march=rv32imc -mabi=ilp32`. The earlier `--target=rv32` compiler spelling also works.

## Flash files

Use an existing data/SPIFFS partition. The label defaults to `fprfiles`. To use the factory C3 layout tested here, select `-DFPR_FLASH_LABEL=spiffs`. The adapter only formats the selected partition when every byte is erased; a corrupt existing filesystem returns an error. Firmware, OTA metadata, NVS and other partitions are outside the volume. On IDF 5.3.2, C3 RAM startup sets a 2 MiB flash limit. For the 4 MiB build, the adapter probes the physical size before extending that limit to the end of the selected partition.

    idf.py -B build/logger -DSDKCONFIG="$PWD/build/logger.config" \
      -DFPR_PROGRAM="$PWD/examples/logger.fpr" -DFPR_FLASH_FILES=ON -DFPR_FLASH_LABEL=spiffs build
    python check_board.py "$PORT" build/logger/c3_builtin.bin write
    python check_board.py "$PORT" build/logger/c3_builtin.bin read

Each invocation resets the C3 and loads the image anew. Write creates `FPRLOG.BIN` exclusively and closes it. Read reopens it and checks all 1,028 bytes. A second write to the same filename is refused. Use separate sdkconfigs for echo and files: the serial build uses IDF's pure-RAM configuration, while the file build enables the flash stack.

## Library

Import the modules under `lib/`, using a path relative to the program. Allocate the buffer once with `Mem.alloc`. Provide its valid capacity on every call. Free the byte storage with `Mem.free` and release the address box with `Rc.release`.

- `IO.read p count` blocks for input and returns up to count bytes. `IO.readExact` collects a complete frame. `IO.write` queues the requested bytes, returning the number transferred or a negative error. All three preserve NUL, CR, LF, and high-bit bytes.
- `File.mount Unit` mounts the flash volume. `File.create name` opens a new file exclusively for writing. `File.open name` opens an existing file for reading. Names refer to files in the volume root.
- `File.read fd p count` and `File.write fd p count` return byte counts, including partial transfers. A zero-byte read with nonzero count means EOF. `File.close fd` returns zero on success. Failures return negative error numbers.

After mounting, the logger sends ACK (0x06). The protocol uses W to create a file, followed by length-prefixed binary chunks of 1–64 bytes. The device echoes each stored chunk before the next one. A zero length ends the write. R replays the file to USB. A log is considered complete after the device reports successful close.

## Boot the logger from flash

The tested 4 MiB C3 has two 0x140000-byte OTA applications, followed by the SPIFFS partition labelled `spiffs`. The original application was in slot 0 and slot 1 was unused. Match the device partition table and identify the inactive slot before installing. Writing an OTA slot replaces its previous contents.

    idf.py -B build/persistent -DSDKCONFIG="$PWD/build/persistent.config" \
      -DFPR_FLASH_BOOT=ON -DFPR_FLASH_FILES=ON -DFPR_FLASH_LABEL=spiffs \
      -DFPR_PROGRAM="$PWD/examples/logger.fpr" build
    ota="$IDF_PATH/components/app_update/otatool.py"
    python "$ota" --port "$PORT" write_ota_partition --slot 1 --input build/persistent/c3_builtin.bin
    python "$ota" --port "$PORT" switch_ota_partition --slot 1
    python check_board.py "$PORT" read

The last command resets the chip and reads the existing test file through the installed logger. After disconnecting and reconnecting power, use `python check_board.py "$PORT" read --attach` to read from the running logger without a downloader handshake or reset. The example processes one command per boot.

To select the original application on this two-slot layout, run `python "$ota" --port "$PORT" switch_ota_partition --slot 0`. Selecting slot 1 again boots the logger. Both applications share the existing flash partition table.

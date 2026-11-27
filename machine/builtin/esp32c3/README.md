# ESP32-C3 Builtin with ESP-IDF

One FP-RISC Builtin program runs in IDF's main task. The C3 provides native USB Serial/JTAG. The program can use the on-chip SPI flash as a SPIFFS volume. The default images run from RAM through the ROM downloader. The flash build can also boot directly from an OTA slot.

## Build and run

Build the compiler with `make fpr` at the repository root. Activate ESP-IDF 5.3.2, then run these commands from this directory. Set `PORT` to the C3 USB Serial/JTAG port.

    idf.py -B build/echo -DSDKCONFIG="$PWD/build/echo.config" build
    python check_board.py "$PORT" build/echo/c3_builtin.bin echo

For the arithmetic example, pass `-DFPR_PROGRAM="$PWD/examples/selfcheck.fpr"` in a separate build directory and select `selfcheck` in the runner. The build invokes `fpr compile --system=bare-metal --profile=builtin --target riscv32imc` and assembles the program and imported units with `-march=rv32imc -mabi=ilp32`. The earlier `--target=rv32` compiler spelling also works.

## Build an application outside the checkout

With ESP-IDF active and a current `fpr` built, run the following from your
application directory. Set `board` to the absolute path to this board directory.

    python "$board/build_app.py" main.fpr
    python "$board/build_app.py" main.fpr --flash --files spiffs

Each command prints the application image path. Builds default to
`build/<program>/<configuration>/` beside the source. Use `--build-dir DIR`
to override it. The first command builds a ROM-loadable RAM image. The
second builds an OTA application with the named SPIFFS volume. Installation
and slot selection are explicit steps described below.

Application modules can use importer-relative paths. Import the board library
from any checkout-external program with, for example,
`IO = use "machine/builtin/esp32c3/lib/io".` Native compilation accepts
`--depfile=PATH` to record the input and resolved imported sources for the
assembly output. The C3 build consumes this file so editing a transitive
import rebuilds the guest and relinks the application.

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

### Multi-command journal

Build `examples/journal.fpr` with the same file-enabled configuration as
`examples/logger.fpr` and a fresh sdkconfig. The journal uses synchronous
SPIFFS writes (`CONFIG_SPIFFS_CACHE_WR=n`) and checks close before sending
an acknowledgement. Its data file is `FPRJNL.BIN`. With the ESP-IDF Python
environment active, run `python check_journal.py PORT JOURNAL_RAM_IMAGE` to
append three test records and verify replay across a reset during an incoming
serial frame. Each invocation adds three records.

The initial status byte is 6 for a healthy journal and 21 for an error.
Send ASCII A, one length byte (1–64), and that many payload bytes to append.
Send L to replay length-prefixed records, followed by a zero and a status.
A short or CRC-invalid record ends replay at the preceding valid record and
produces status 21. Appends stay disabled while that suffix exists. Send R to truncate one
damaged final record after the valid prefix. R refuses interior damage.
Q exits.

On the tested generic ESP32-C3, a RAM probe sampled GPIO9 with the internal
pull-up enabled. Pressing BOOT changed the input from high to low and
releasing it restored high, with 140 ms between sampled edges. An open-drain double-blink test and visual confirmation identified GPIO8 as
the active-low onboard LED. The exact PCB model remains unknown.

## Button and LED timestamp logger

Build `examples/button.fpr` with `--files spiffs` for the tested board. It
uses the pin assignments in `boards/supermini.fpr`, samples BOOT every
20 ms, and accepts a change after two consecutive matching reads. Each
accepted change and the initial state append one CRC-checked record to
`FPRBTN.BIN`. The nine-byte payload contains eight little-endian bytes of
milliseconds since boot followed by 1 for pressed or 0 for released.
The LED follows the committed state. Logging runs without USB commands.

The GPIO module configures pull-up inputs, push-pull outputs, and open-drain
outputs. Operations return zero on success or a negative error. A successful
read returns 0 or 1. The clock module writes monotonic milliseconds to an
eight-byte caller-owned buffer. `afterMs stamp delay dest` forms an absolute
deadline and supports using the same buffer for both arguments.
`sleepUntil dest` yields to IDF and returns once the deadline has passed.


## Endurance measurement

Build `examples/endurance.fpr` with the file-enabled RAM configuration and
`-DFPR_RUNTIME_STATS=ON`. Run `python check_endurance.py PORT IMAGE` for
the two-hour qualification. The workload double-blinks the LED, samples BOOT
and appends one timestamped record to `FPREND.BIN` every 30 blink cycles.
Each checkpoint reports live Builtin allocation count and bytes, peak Builtin
bytes, current and minimum IDF 8-bit heap, and the main task's stack
high-water mark in bytes. The checker requires consecutive checkpoints,
positive remaining stack, and stable live allocator and IDF heap readings.

### Stage an external app and roll back

With the tested two-slot partition table and an unencrypted development C3,
`ota_slot.py` can install an image from `build_app.py --flash`.
All commands enter the ROM loader and reset the board on exit. Read the
selected slot first. For example, when status reports slot 0:

    python ota_slot.py "$PORT" status
    python ota_slot.py "$PORT" backup 1 previous-slot1.bin
    python ota_slot.py "$PORT" install 1 /path/to/c3_builtin.bin --replace-backup previous-slot1.bin
    python ota_slot.py "$PORT" select 0

The install checks the active image, target chip revision, image checksum
and SHA-256. A nonempty target requires a byte-for-byte backup unless it
already contains the requested image. The board reads back the programmed
digest before the tool updates one OTA selector sector. The previous valid
selector sector stays available across that update. Selection verifies the
destination application before switching. Keep backups locally.

See [C3 qualification](QUALIFICATION.md) for measured results and test scope.

### Check a physical power interruption

With the multi-command journal installed and running from an OTA slot, run
`python check_power.py arm PORT WITNESS`. Use a fresh local witness path.
The host fingerprints the existing journal and records each send and ACK.
After the first ACK, remove power from the C3 while appends continue, then
restore power. Run `python check_power.py verify PORT WITNESS` against the
rebooted journal. The checker compares the original prefix, every confirmed
append and the one possible unacknowledged record. If a partial final record
is present it checks the prefix before issuing R and verifying replay again.
The arm phase issues at most 3,000 short records, approximately ten per second.

# ESP32-C3 Builtin qualification

Tests used native USB Serial/JTAG, an ESP32-C3 revision 0.4 with 4 MiB
flash, ESP-IDF 5.3.2, and the RV32IMC Builtin target on 28 November 2026.
The USB device and pin tests identify the chip and wiring. The precise
PCB manufacturer and model remain unknown.

## Physical board

- The input probe observed a GPIO9 high-low-high sequence separated by
  140 ms between the pressed and released samples. A person at the board
  observed the distinctive double blink on GPIO8 in open-drain mode.
- With the FP-RISC button logger running unattended, the LED followed BOOT.
  After reset, the separate readback app decoded `FPRBTN.BIN` as
  `(130,0), (61,0), (41441,1), (41541,0)`. The first two entries are
  initial released states from separate boots. The final pair spans 100 ms
  on the device's monotonic millisecond clock.
- The appendable journal acknowledged three records including a 64-byte
  payload and embedded NUL and 0xff bytes. The physical C3 replayed every
  record after a reset halfway through the next incoming serial frame.
- `tests/journal-damage.fpr` creates three exclusive scratch files. A
  13-byte tail and a full record with a damaged header each caused scan
  failure. Explicit repair preserved the first record and restored EOF.
  Repair returned an error when another record followed the corruption.
  The RAM image finished with status 0 on the physical C3. The fixture
  leaves its files in place and will refuse a second exclusive create.

## Simulated flash interruptions and full volume

Run `tests/check_spiffs_power.sh BUILD_DIR` on a host with a C compiler,
zlib and the IDF checkout. Supply a file-enabled C3 build directory.
The test compiles IDF's SPIFFS source using the build's generated settings.
It uses a 64 KiB NOR array with 4 KiB erase blocks, 256-byte pages and
synchronous SPIFFS writes. A reset discards all in-memory filesystem state.

Three closed records preceded a fourth append crossing a page boundary.
Interrupting that append at each of 603 byte positions of mutating flash
operations preserved the acknowledged prefix on remount. After 631 successful
appends the test volume filled, the next append failed, and all 631 records
replayed. These results cover that append pattern and simulated failure
model. Physical power removal and garbage collection can have different
failure characteristics.

### Failure during SPIFFS garbage collection

Run `tests/check_spiffs_power.sh BUILD_DIR --gc` to reproduce the readback
failure. This command returns a nonzero status when it detects data loss.
Extending the same NOR simulator to the first append which relocated live
pages changed the outcome. After 79 acknowledged records, a simulated cut
at mutating byte position 523 left record 48 unreadable on remount
(`SPIFFS_read` returned -10004). At position 782 the prefix still failed
after a separate remount and `SPIFFS_check`. These positions count bytes
written or erased since the start of the candidate append. The earlier
603-position pass covers an append that did not relocate live pages.

The IDF 5.3.2 collector moves and retires a data page before publishing
the replacement object index. A journal CRC or a tail truncate cannot
restore a previously acknowledged record if its filesystem page becomes
unreachable. Treat SPIFFS acknowledgements as conditional on this limit.

## RV32 resource and ownership audit

The instrumented RAM endurance image was 228,896 bytes. Its guest object
contained 4,172 bytes of text and 3,924 bytes of read-only data. ELF attributes
identified ELF32 RISC-V with RVC, soft-float ABI and RV32IMC instructions.
The linked Builtin arena occupied 8,192 bytes. The IDF main task had a
3,584-byte stack and a 100 Hz tick.

- IDF enters `app_main` on its main task, which installs task-local hart
  state and calls the compiled FP-RISC entry point. In the linked ELF,
  `fpr_set_tp` stored the hart pointer at the TLS address relative to
  IDF's existing `tp`. The endurance guest object contained no direct
  references to `tp`. The board component is compiled with fixed x27.
- GPIO reads are polled. Deadline sleep yields the main task through IDF.
  USB and filesystem operations are synchronous calls from the guest
  into C. No adapter registers a guest closure as an IDF event, timer
  or interrupt callback. IDF's USB driver handles interrupts internally.
  The single-hart allocator is accessed by the guest task.
- The manual RV32 ABI passes tagged integers and immediate Booleans by value.
  `Mem.alloc` returns an address box owning a reference to manual storage.
  File and USB adapters borrow the address for the duration of a call.
  Journal encoding and timestamp arithmetic take caller-owned buffers.
  The button loop reuses its record and deadline buffers, plus a retained
  address box for the state-byte position. Error returns release the derived
  box, free the raw buffers, and release their address boxes.
- The endurance program reuses a 72-byte record buffer and an interior
  address box. Its first physical checkpoint counted three live allocations
  occupying 256 bytes including allocator overhead. IDF reported 135,728
  available 8-bit heap bytes, a minimum of 135,696, and 2,252 bytes of
  main-task stack headroom. IDF's RISC-V port uses an 8-bit StackType_t.

The two-hour test requires consecutive checkpoint records, stable live
memory occupancy and a host monotonic duration of at least 7,200 seconds.


## Dedicated journal provisioning

Before migrating the physical C3, the host read all 4,194,304 flash bytes
and independently matched their device-side digest. The original app in
slot 0 occupied 890,368 bytes. The installed FP-RISC logger in slot 1
occupied 218,608 bytes. Both image integrity checks passed and all 65,536
bytes proposed for the journal were erased. The full-device backup is
private to the board owner.

After writing the table, the host read back that sector and compared device
digests for every other flash byte with the pre-migration copy. The
flash-booted logger reopened the original SPIFFS file and returned 1,028
bytes with SHA-256
`848a039cf625b031dd86e6ec8804e0202a8f664e590a40528934d2a6f9049270`.
Selecting the original slot 0 advanced the OTA selector from sequence 2
to 3. Its firmware cycled native USB after boot, which can require BOOT
and RESET to re-enter the ROM downloader.

The dedicated format passed the host simulator at 129 signature-program
boundaries and 1,025 record-program boundaries. Every reboot preserved
previously acknowledged records and allowed a subsequent append. A full
volume rejected the next append and a corrupt committed record failed
mount. The same tests passed with address and undefined-behavior sanitizers.

The external flash app was installed from a separate application directory.
The installer matched the pre-existing slot 1 against its owner-held backup,
verified the programmed 226,768-byte image and selected slot 1 at sequence 4.
After reboot its ELF identity began `19bd37df9`, entry heap was 309,976
bytes, and it returned a healthy journal status. The power-cut checker
received 150 consecutive individual acknowledgements before deliberately
leaving an incoming serial frame incomplete.

The RAM-only `tests/media-reset` IDF project exercises an interruption
after body readback and immediately before marker programming. Build it with
`idf.py -C tests/media-reset -B /path/to/build build`, then load the resulting
`journal_reset.bin` through the ROM RAM loader with the journal app installed
in flash. A successful injection consumes one otherwise unused slot.

## Physical power loss and interrupted commit

After the host witnessed 150 acknowledgements, the operator unplugged the
C3 and reconnected it. The flash-booted app replayed all 150 records in
order and matched every payload. No repair was needed. The wire frame
pending at disconnection had not received a full payload.

In a separate test, the RAM fixture reset the chip immediately before
programming the commit word for physical slot 151. Reading the partition
through the ROM loader showed the expected payload and CRC with an erased
commit word. The flash app again replayed exactly the 150 acknowledged
records, then acknowledged another append and replayed it after the prefix.

The dedicated-journal endurance image was 233,216 bytes. At entry IDF
reported 134,356 free heap bytes. The first workload checkpoint reported
three live Builtin allocations using 256 bytes, 133,692 free IDF heap
bytes, a minimum of 133,660 bytes, and 2,252 bytes of stack headroom.


## Completed two-hour dedicated-journal run

With GPIO8 released and the onboard LED off, the physical ESP32-C3 completed 122 consecutive workload checkpoints
over 7,259.683 host-monotonic seconds. Each checkpoint reported
3 live allocations, 256 live Builtin heap bytes and
133,740 free IDF heap bytes. The maximum Builtin peak was
256 bytes. Minimum observed IDF heap was
133,708 bytes and minimum stack headroom was
2,252 bytes.

A ROM-loader readback found 122 CRC-valid committed endurance
records with strictly increasing device timestamps spanning
7,260.005 seconds. After reset, the installed
slot 1 journal replayed the 150 power-test records and the post-interruption
append. Slot 0 retains the board's original application.

"""Stage or undo the P4 flash bench layout using a verified full-device backup."""
import argparse
import hashlib
import io
from pathlib import Path
import struct
import time
import zlib

from esptool import detect_chip
from esptool.bin_image import ESP32P4FirmwareImage

FLASH_BYTES = 32 * 1024 * 1024
SECTOR = 4096
TABLE = 0x8000
TABLE_BYTES = 0xC00
SLOT = 0xD10000
SLOT_SIZE = 0x100000
SELECTOR = 0xE10000
JOURNAL = 0xE20000
JOURNAL_SIZE = 0x10000
SCRATCH = 0xE30000
TEST_END = SCRATCH + SECTOR
PART = struct.Struct("<HBBII16sI")
TABLE_MD5 = b"\xeb\xeb" + b"\xff" * 14
SELECTION_STATE = 0xFFFFFFFF
ORIGINAL = (
    (1, 2, 0x9000, 0x6000, b"nvs"),
    (1, 1, 0xF000, 0x1000, b"phy_init"),
    (0, 0, 0x10000, 0x400000, b"factory"),
    (1, 0x81, 0x410000, 0x800000, b"storage"),
)


def md5(data):
    return hashlib.md5(data).hexdigest()


def backup_image(filename, digest_filename):
    data = filename.read_bytes()
    if len(data) != FLASH_BYTES:
        raise ValueError("Expected the original 32 MiB flash backup")
    if hashlib.sha256(data).hexdigest() != digest_filename.read_text().strip():
        raise ValueError("Backup SHA-256 mismatch")
    if data[SLOT:TEST_END] != b"\xff" * (TEST_END - SLOT):
        raise ValueError("The proposed test allocation is occupied")
    return data


def table_sector(data):
    old = data[TABLE:TABLE + SECTOR]
    fields = []
    for at in range(0, TABLE_BYTES, PART.size):
        row = old[at:at + PART.size]
        if row.startswith(TABLE_MD5):
            if row[16:] != hashlib.md5(old[:at]).digest():
                raise ValueError("Invalid original partition table digest")
            break
        magic, kind, subtype, offset, size, label, flags = PART.unpack(row)
        if magic != 0x50AA or flags:
            raise ValueError("Expected original unencrypted partition entries")
        fields.append((kind, subtype, offset, size, label.rstrip(b"\0")))
    else:
        raise ValueError("No original partition table digest")
    if tuple(fields) != ORIGINAL:
        raise ValueError(f"Unexpected original P4 partition layout: {fields!r}")
    if old[at + PART.size:TABLE_BYTES] != b"\xff" * (TABLE_BYTES - at - PART.size):
        raise ValueError("Original table has unexpected bytes after its digest")
    fields += [
        (0, 0x10, SLOT, SLOT_SIZE, b"fpr_p4_bench"),
        (1, 0, SELECTOR, 2 * SECTOR, b"otadata"),
        (1, 0x40, JOURNAL, JOURNAL_SIZE, b"fprjournal"),
        (1, 0x41, SCRATCH, SECTOR, b"fprscratch"),
    ]
    entries = b"".join(PART.pack(0x50AA, *row, 0) for row in fields)
    table = entries + TABLE_MD5 + hashlib.md5(entries).digest()
    return old, table.ljust(TABLE_BYTES, b"\xff") + old[TABLE_BYTES:]


def checked_app(filename):
    data = filename.read_bytes()
    app = ESP32P4FirmwareImage(io.BytesIO(data))
    if (not app.segments or app.segments[0].addr != 0x40000020 or
            app.segments[0].data[:4] != bytes.fromhex("3254cdab") or
            [seg.addr for seg in app.segments if 0x40000000 <= seg.addr < 0x44000000]
            != [0x40000020, 0x40010020] or
            app.entrypoint != 0x4FF10000 or app.checksum != app.calculate_checksum() or
            not app.append_digest or app.stored_digest != app.calc_digest or
            len(data) != app.data_length + 32 or len(data) > SLOT_SIZE):
        raise ValueError("Expected a verified P4 Builtin flash bench image")
    return data


def program(stub, offset, data):
    compressed = zlib.compress(data)
    block = stub.FLASH_WRITE_SIZE
    blocks = stub.flash_defl_begin(len(data), len(compressed), offset)
    for index in range(blocks):
        stub.flash_defl_block(compressed[index * block:(index + 1) * block], index)
    stub.flash_begin(0, 0)
    stub.flash_defl_finish(False)
    if stub.flash_md5sum(offset, len(data)) != md5(data):
        raise RuntimeError(f"Flash readback mismatch at {offset:#x}")


def assert_readback(stub, offset, expected):
    if stub.flash_md5sum(offset, len(expected)) != md5(expected):
        raise RuntimeError(f"Live flash differs from expected bytes at {offset:#x}")


def outside_test(stub):
    ranges = ((0, TABLE), (TABLE + SECTOR, SLOT), (TEST_END, FLASH_BYTES))
    return [stub.flash_md5sum(start, end - start) for start, end in ranges]


def ota_selector():
    sector = bytearray(b"\xff" * SECTOR)
    seq = struct.pack("<I", 1)
    struct.pack_into("<I20xII", sector, 0, 1, SELECTION_STATE, zlib.crc32(seq, 0xffffffff))
    return bytes(sector)


def install(stub, backup, old, bench, app):
    assert_readback(stub, TABLE, old)
    assert_readback(stub, 0, backup[:TABLE])
    assert_readback(stub, 0x10000, backup[0x10000:0x410000])
    assert_readback(stub, SLOT, backup[SLOT:TEST_END])
    before = outside_test(stub)

    # Publish the selector and the table only after the app passes readback.
    program(stub, SLOT, app)
    program(stub, SELECTOR, ota_selector())
    program(stub, TABLE, bench)
    if outside_test(stub) != before:
        raise RuntimeError("Unexpected change outside the P4 qualification ranges")
    print("Verified temporary P4 flash bench layout and test app.", flush=True)


def replace_app(stub, backup, bench, previous, app):
    assert_readback(stub, TABLE, bench)
    assert_readback(stub, 0x10000, backup[0x10000:0x410000])
    assert_readback(stub, SELECTOR, ota_selector())
    assert_readback(stub, SLOT, previous)
    end = SLOT + (len(previous) + SECTOR - 1) // SECTOR * SECTOR
    assert_readback(stub, end, backup[end:SLOT + SLOT_SIZE])
    program(stub, SLOT, app)
    print("Verified replacement P4 test app. Partition table and selector retained.", flush=True)


def restore(stub, backup, old, bench):
    live = stub.read_flash(TABLE, SECTOR)
    if live not in (old, bench):
        raise RuntimeError("Unexpected partition table. Verify the board and full backup before restoring.")
    assert_readback(stub, 0, backup[:TABLE])
    assert_readback(stub, 0x10000, backup[0x10000:0x410000])
    before = outside_test(stub)
    if live != old:
        program(stub, TABLE, old)
    # The test allocation was completely erased before staging.
    stub.erase_region(SLOT, TEST_END - SLOT)
    assert_readback(stub, SLOT, backup[SLOT:TEST_END])
    if outside_test(stub) != before:
        raise RuntimeError("Unexpected change outside the P4 qualification ranges")
    print("Verified original partition table, erased bench space and factory boot selection.", flush=True)


def verify_factory_boot(stub):
    port = stub._port
    port.timeout = 0.2
    stub.hard_reset()
    output = bytearray()
    deadline = time.monotonic() + 10
    marker = b"Loaded app from partition at offset 0x10000"
    while marker not in output and time.monotonic() < deadline:
        output.extend(port.read(512))
    if marker not in output:
        raise RuntimeError("Original flash restored, but no factory boot marker appeared on UART")
    print("UART confirmed the original factory app loaded at 0x10000.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "install", "replace", "restore"))
    parser.add_argument("backup", type=Path)
    parser.add_argument("sha256", type=Path)
    parser.add_argument("--port")
    parser.add_argument("--mac", help="12 hex digits from the originally backed-up P4")
    parser.add_argument("--image", type=Path)
    parser.add_argument("--previous", type=Path, help="previous test-slot image for replace")
    args = parser.parse_args()
    backup = backup_image(args.backup, args.sha256)
    old, bench = table_sector(backup)
    app = checked_app(args.image) if args.image else None
    if args.command == "plan":
        print("Verified backup, original table, and erased test allocation.")
        print(f"OTA slot {SLOT:#x}, selector {SELECTOR:#x}, journal {JOURNAL:#x}, scratch {SCRATCH:#x}.")
        if app:
            print(f"Verified {len(app)}-byte P4 flash image.")
        return
    if not args.port or not args.mac or (args.command in ("install", "replace") and app is None):
        parser.error("Flash operations require --port and --mac. Install and replace also require --image.")
    previous = args.previous.read_bytes() if args.previous else None
    if args.command == "replace" and (not previous or len(previous) > SLOT_SIZE):
        parser.error("replace requires the previous test-slot image")
    chip = detect_chip(port=args.port, baud=115200)
    try:
        if (chip.CHIP_NAME != "ESP32-P4" or bytes(chip.read_mac()).hex() != args.mac.lower() or
                chip.get_secure_boot_enabled() or chip.get_flash_encryption_enabled()):
            raise ValueError("Expected the original P4 with secure boot and flash encryption off")
        stub = chip.run_stub()
        if (stub.flash_id() >> 16) & 0xff != 0x19:
            raise ValueError("Expected 32 MiB flash")
        if args.command == "install":
            install(stub, backup, old, bench, app)
        elif args.command == "replace":
            replace_app(stub, backup, bench, previous, app)
        else:
            restore(stub, backup, old, bench)
            verify_factory_boot(stub)
        # After install, the flash checker opens the console before it resets.
    finally:
        chip._port.close()


if __name__ == "__main__":
    main()

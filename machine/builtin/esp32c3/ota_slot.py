"""Stage and select C3 apps on the two-slot partitions-ota.csv layout (IDF 5.3)."""
import argparse
import hashlib
import io
import os
from pathlib import Path
import struct
import sys
import zlib

from esptool import detect_chip
from esptool.bin_image import ESP32C3FirmwareImage


SECTOR = 4096
ERASED = 0xffffffff


def expected_table(filename="partitions-ota.csv"):
    sys.path.insert(0, str(Path(os.environ["IDF_PATH"]) / "components/partition_table"))
    from gen_esp32part import PartitionTable

    return PartitionTable.from_csv(Path(__file__).with_name(filename).read_text())


def image_size(data, revision):
    image = ESP32C3FirmwareImage(io.BytesIO(data))
    if (image.chip_id != 5 or not image.append_digest or image.stored_digest != image.calc_digest
            or image.checksum != image.calculate_checksum() or not image.segments
            or not image.is_flash_addr(image.segments[0].addr)
            or image.segments[0].data[:4] != bytes.fromhex("3254cdab")):
        raise ValueError("Expected an intact ESP32-C3 flash application with an IDF app descriptor")
    if revision < image.min_rev_full or (image.max_rev_full and revision > image.max_rev_full):
        raise ValueError("Image chip revision constraints exclude this C3")
    return image.data_length + 32


def selection(metadata):
    copies = []
    for index in range(2):
        seq, state, crc = struct.unpack_from("<I20xII", metadata, index * SECTOR)
        if seq in (0, ERASED) or crc != zlib.crc32(struct.pack("<I", seq), ERASED):
            continue
        if state in (3, 4):  # invalid or aborted
            continue
        if state not in (2, ERASED):
            raise ValueError("OTA verification is pending or the selection state is unknown")
        copies.append((seq, index))
    if not copies:
        if metadata == b"\xff" * (2 * SECTOR):
            return 0, 0, None
        raise ValueError("No valid OTA selector in the existing metadata")
    seq, index = max(copies)
    return (seq - 1) % 2, seq, index


def program(stub, offset, data):
    # The flasher stub erases sectors covering the uncompressed length.
    # In particular, an OTA selection update touches exactly one sector.
    compressed = zlib.compress(data, 9)
    size = stub.FLASH_WRITE_SIZE
    blocks = stub.flash_defl_begin(len(data), len(compressed), offset)
    for n in range(blocks):
        stub.flash_defl_block(compressed[n * size:(n + 1) * size], n)
    stub.flash_begin(0, 0)
    stub.flash_defl_finish(False)
    if stub.flash_md5sum(offset, len(data)) != hashlib.md5(data).hexdigest():
        raise RuntimeError("Flash readback digest mismatch")


def provision(stub, revision, backup):
    before = backup.read_bytes()
    if len(before) != 4 * 1024 * 1024:
        raise ValueError("Expected a full 4 MiB pre-migration backup")
    if stub.flash_md5sum(0, len(before)) != hashlib.md5(before).hexdigest():
        raise ValueError("Live flash differs from the supplied backup")
    old_table = expected_table().to_binary()
    new_table = expected_table("partitions-journal.csv").to_binary()
    if before[0x8000:0x8000 + len(old_table)] != old_table:
        raise ValueError("Expected the original partitions-ota.csv layout")
    if before[0x280000:0x290000] != b"\xff" * 65536:
        raise ValueError("The proposed journal space is occupied")
    for start, end in [(0x10000, 0x150000), (0x150000, 0x280000)]:
        app = before[start:end]
        if app != b"\xff" * len(app):
            image_size(app, revision)
    sector = new_table + before[0x8000 + len(new_table):0x9000]
    program(stub, 0x8000, sector)
    if stub.read_flash(0x8000, 4096) != sector:
        raise RuntimeError("Journal partition table verification failed")
    for start, end in [(0, 0x8000), (0x9000, len(before))]:
        if stub.flash_md5sum(start, end - start) != hashlib.md5(before[start:end]).hexdigest():
            raise RuntimeError("Data outside the partition table changed")
    print("Reserved 64 KiB. All bytes outside the partition table match the backup.")


def operate(stub, revision, args):
    if args.command == "provision-journal":
        provision(stub, revision, args.backup)
        return
    table = expected_table()
    binary = table.to_binary()
    live = stub.read_flash(0x8000, len(binary))
    if live != binary:
        table = expected_table("partitions-journal.csv")
        if live != table.to_binary():
            raise ValueError("Unrecognized partition table")

    parts = {part.name: part for part in table}
    ota = parts["otadata"]
    metadata = stub.read_flash(ota.offset, ota.size)
    active, seq, index = selection(metadata)
    print(f"Selected OTA slot {active}, sequence {seq}", flush=True)
    if args.command == "status":
        return
    target = args.slot
    part = parts[f"app{target}"]
    old = stub.read_flash(part.offset, part.size)
    if args.command == "backup":
        with args.output.open("xb") as out:
            out.write(old)
        print(f"Saved slot {target}, SHA-256 {hashlib.sha256(old).hexdigest()}")
        return
    next_seq = seq + 1
    if (next_seq - 1) % 2 != target:
        next_seq += 1
    if target != active and next_seq >= ERASED:
        raise ValueError("OTA sequence exhausted")
    if args.command == "install":
        if target == active:
            raise ValueError("Install requires the inactive OTA slot")
        # IDF may fall back from a damaged selected image to the other slot.
        previous = parts[f"app{active}"]
        image_size(stub.read_flash(previous.offset, previous.size), revision)
        data = args.image.read_bytes()
        if len(data) > part.size or image_size(data, revision) != len(data):
            raise ValueError("App size does not match its checksummed image length or slot capacity")
        if old[:len(data)] != data:
            if old != b"\xff" * part.size and (not args.replace_backup or args.replace_backup.read_bytes() != old):
                raise ValueError("Nonempty inactive slot requires its exact full-slot --replace-backup")
            program(stub, part.offset, data)
    else:
        image_size(old, revision)
    if target == active:
        return
    copy = 0 if index is None else 1 - index
    new = bytearray(b"\xff" * SECTOR)
    raw = struct.pack("<I", next_seq)
    struct.pack_into("<I20xII", new, 0, next_seq, ERASED, zlib.crc32(raw, ERASED))
    program(stub, ota.offset + copy * SECTOR, new)
    if selection(stub.read_flash(ota.offset, ota.size))[:2] != (target, next_seq):
        raise RuntimeError("Boot selection did not verify")
    print(f"Selected OTA slot {target}, sequence {next_seq}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    migrate = commands.add_parser("provision-journal", help="reserve the erased 64 KiB tail of slot 1")
    migrate.add_argument("backup", type=Path, help="verified full-device pre-migration backup")
    backup = commands.add_parser("backup")
    install = commands.add_parser("install")
    select = commands.add_parser("select", help="select an existing application, including for rollback")
    for cmd in (backup, install, select):
        cmd.add_argument("slot", type=int, choices=(0, 1))
    backup.add_argument("output", type=Path)
    install.add_argument("image", type=Path)
    install.add_argument("--replace-backup", type=Path)
    args = parser.parse_args()
    chip = detect_chip(port=args.port, baud=115200)
    try:
        if chip.CHIP_NAME != "ESP32-C3" or chip.get_flash_encryption_enabled() or chip.get_secure_boot_enabled():
            raise ValueError("Expected an unencrypted development C3 with secure boot disabled")
        revision = chip.get_chip_revision()
        stub = chip.run_stub()
        try:
            operate(stub, revision, args)
        finally:
            stub.hard_reset()
    finally:
        chip._port.close()


if __name__ == "__main__":
    main()

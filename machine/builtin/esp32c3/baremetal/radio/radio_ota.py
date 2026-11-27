"""Run C3 radio tests in a temporary OTA slot and restore its original bytes."""
import argparse
from contextlib import contextmanager
from hashlib import md5
from pathlib import Path
import re
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace

from esptool import detect_chip
from serial import Serial

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from ota_slot import SECTOR, expected_table, image_size, operate, program, selection

from check_ble import check as check_ble
from check_station import Console

FLASH_BYTES = 0x400000
TABLE = 0x8000
OTA = 0xE000
APP0 = 0x10000
APP1 = 0x150000
JOURNAL = 0x280000
JOURNAL_END = 0x290000


def verify(stub, start, data):
    if stub.flash_md5sum(start, len(data)) != md5(data).hexdigest():
        raise RuntimeError(f"C3 flash digest differs at 0x{start:x}")


def verify_protected(stub, baseline):
    for start, end in ((0, OTA), (APP0, APP1), (JOURNAL_END, FLASH_BYTES)):
        verify(stub, start, baseline[start:end])


def check_layout(stub, baseline, revision, image):
    table = expected_table("partitions-journal.csv").to_binary()
    if len(baseline) != FLASH_BYTES or baseline[TABLE:TABLE+len(table)] != table:
        raise ValueError("Expected the original 4 MiB flash backup with the journal layout")
    if not image or len(image) > JOURNAL - APP1 or image_size(image, revision) != len(image):
        raise ValueError("Temporary image does not fit the verified C3 slot")
    image_size(baseline[APP0:APP1], revision)
    image_size(baseline[APP1:JOURNAL], revision)
    verify_protected(stub, baseline)
    verify(stub, APP1, baseline[APP1:JOURNAL])
    verify(stub, OTA, baseline[OTA:APP0])
    if selection(baseline[OTA:APP0])[0] != 1:
        raise ValueError("Expected the backup to select slot 1")


def select_original(stub, revision, reference):
    operate(stub, revision, SimpleNamespace(command="select", slot=0, reference=reference))


def stage(stub, revision, reference, backup, image):
    select_original(stub, revision, reference)
    operate(stub, revision, SimpleNamespace(command="install", slot=1, reference=reference,
                                            replace_backup=backup, image=image))


def restore(stub, revision, reference, baseline, length, journal_digest):
    verify_protected(stub, baseline)
    live_journal = stub.flash_md5sum(JOURNAL, JOURNAL_END - JOURNAL)
    if live_journal != journal_digest:
        print("Journal changed during the radio test", file=sys.stderr, flush=True)
    select_original(stub, revision, reference)
    last = APP1 + (length + SECTOR - 1) // SECTOR * SECTOR
    program(stub, APP1, baseline[APP1:last])
    verify(stub, APP1, baseline[APP1:JOURNAL])

    # Restore the sector that booted the original slot 1 first. The
    # preceding selector still points at the verified slot 0 until then.
    index = selection(baseline[OTA:APP0])[2]
    for sector in (index, 1 - index):
        start = OTA + sector * SECTOR
        program(stub, start, baseline[start:start+SECTOR])
    verify(stub, OTA, baseline[OTA:APP0])
    verify_protected(stub, baseline)
    if stub.flash_md5sum(JOURNAL, JOURNAL_END - JOURNAL) != journal_digest:
        raise RuntimeError("Radio test changed the journal. Its live bytes were preserved.")
    print("Restored original firmware and OTA selection. Journal digest matches.", flush=True)


@contextmanager
def attached_stub(port, expected_mac):
    chip = detect_chip(port=port, baud=115200)
    try:
        if (chip.CHIP_NAME != "ESP32-C3" or bytes(chip.read_mac()).hex() != expected_mac
                or chip.get_flash_encryption_enabled() or chip.get_secure_boot_enabled()):
            raise ValueError("Unexpected device, encryption, or secure boot")
        revision = chip.get_chip_revision()
        stub = chip.run_stub()
        try:
            yield stub, revision
        finally:
            stub.hard_reset()
    finally:
        chip._port.close()


def check_scan(port, ssid):
    with Serial(port=None, baudrate=115200, timeout=0.25, write_timeout=5) as serial:
        serial.port = port
        serial.dtr = serial.rts = False
        serial.open()
        console = Console(serial)
        serial.write(b"?")
        console.until(re.compile(rb"FPR C3 FLASH wifi"), 15)
        console.until(re.compile(rb"FPR WIFI SCAN READY"), 15)
        serial.write(bytes([len(ssid)]) + ssid)
        target_seen = True
        if ssid:
            matched = console.until(re.compile(rb"FPR WIFI TARGET (SEEN|ABSENT)"), 25)
            target_seen = matched[1] == b"SEEN"
        count = int(console.until(re.compile(rb"FPR WIFI SCAN APs=(\d+)"), 25)[1])
        console.until(re.compile(rb"FPR DONE"), 15)
        if not count:
            raise RuntimeError("Wi-Fi scan completed without seeing an access point")
        if not target_seen:
            raise RuntimeError("The passive scan missed the requested test AP")
        print(f"Wi-Fi passive scan PASS: {count} APs and clean shutdown", flush=True)


def run(args):
    baseline = args.reference.read_bytes()
    image = args.image.read_bytes()
    # ESP image header and first segment header occupy 32 bytes. The
    # application descriptor's 32-byte project name begins 48 bytes later.
    project = image[80:112].split(b"\0", 1)[0]
    if project != f"fprisc-c3-{args.profile}".encode():
        raise ValueError("Image project name does not match the radio test profile")
    needs_restore = False
    journal_digest = None
    try:
        with TemporaryDirectory(prefix="fpr-c3-ota-") as directory:
            backup = Path(directory) / "slot1.bin"
            backup.write_bytes(baseline[APP1:JOURNAL])
            with attached_stub(args.port, args.mac) as (stub, revision):
                check_layout(stub, baseline, revision, image)
                journal_digest = stub.flash_md5sum(JOURNAL, JOURNAL_END - JOURNAL)
                needs_restore = True
                stage(stub, revision, args.reference, backup, args.image)
        if args.profile == "ble":
            check_ble(args.port, args.observer, args.restarts)
        else:
            check_scan(args.port, args.ssid)
    finally:
        if needs_restore:
            with attached_stub(args.port, args.mac) as (stub, revision):
                restore(stub, revision, args.reference, baseline, len(image), journal_digest)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("profile", choices=("ble", "wifi"))
    parser.add_argument("image", type=Path)
    parser.add_argument("--mac", required=True, help="12 hex digits for the C3 being tested")
    parser.add_argument("--reference", required=True, type=Path, help="verified full-flash backup")
    parser.add_argument("--observer", type=Path, help="compiled CoreBluetooth observer for BLE")
    parser.add_argument("--restarts", type=int, default=3)
    parser.add_argument("--ssid", default="", help="optional visible test SSID for passive scan")
    args = parser.parse_args()
    args.mac = args.mac.lower()
    if not re.fullmatch(r"[0-9a-f]{12}", args.mac):
        parser.error("Expected a 12-digit MAC")
    if args.profile == "ble" and not args.observer:
        parser.error("--observer is required for BLE")
    if args.observer:
        args.observer = args.observer.resolve()
    args.ssid = args.ssid.encode()
    if len(args.ssid) > 32 or b"\0" in args.ssid:
        parser.error("The SSID must have at most 32 bytes with no NUL")
    if args.restarts < 0:
        parser.error("--restarts must be nonnegative")
    run(args)

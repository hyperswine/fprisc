"""RAM-load the P4 Builtin self-check with optional BLE HCI verification."""
import argparse
from pathlib import Path
import time
from types import SimpleNamespace

from esptool import detect_chip, load_ram


def check(port, image, ble_hci):
    chip = detect_chip(port=port, baud=115200)
    try:
        if chip.CHIP_NAME != "ESP32-P4":
            raise RuntimeError(f"Expected an ESP32-P4, found {chip.CHIP_NAME}")
        load_ram(chip, SimpleNamespace(filename=str(image)))
        chip._port.timeout = 0.2
        chip._port.write(b"B" if ble_hci else b"?")
        expected = [b"P4 BARE METAL integer self-check: 827204 [PASS]\n", b"FPR DONE\n"]
        if ble_hci:
            expected.append(b"P4 SDIO HCI Reset Command Complete PASS\n")
        output = bytearray()
        deadline = time.monotonic() + 15
        while b"FPR DONE\n" not in output and time.monotonic() < deadline:
            output.extend(chip._port.read(256))
        print(output.decode(errors="replace"), end="", flush=True)
        if any(line not in output for line in expected):
            raise RuntimeError("The P4 did not pass the requested RAM checks")
    finally:
        try:
            chip.hard_reset()
        finally:
            chip._port.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("image", type=Path)
    parser.add_argument("--ble-hci", action="store_true")
    args = parser.parse_args()
    check(args.port, args.image, args.ble_hci)

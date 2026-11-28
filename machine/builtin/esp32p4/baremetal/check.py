"""RAM-load the P4 Builtin self-check and restore normal flash boot."""
import argparse
from pathlib import Path
import time
from types import SimpleNamespace

from esptool import detect_chip, load_ram


def check(port, image):
    chip = detect_chip(port=port, baud=115200)
    try:
        if chip.CHIP_NAME != "ESP32-P4":
            raise RuntimeError(f"Expected an ESP32-P4, found {chip.CHIP_NAME}")
        load_ram(chip, SimpleNamespace(filename=str(image)))
        chip._port.timeout = 0.2
        chip._port.write(b"?")
        expected = b"P4 BARE METAL integer self-check: 827204 [PASS]\nFPR DONE\n"
        output = bytearray()
        deadline = time.monotonic() + 10
        while expected not in output and time.monotonic() < deadline:
            output.extend(chip._port.read(256))
        if expected not in output:
            raise RuntimeError(f"P4 RAM self-check did not pass: {output[-1024:]!r}")
        print(expected.decode(), end="", flush=True)
    finally:
        try:
            chip.hard_reset()
        finally:
            chip._port.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("image", type=Path)
    args = parser.parse_args()
    check(args.port, args.image)

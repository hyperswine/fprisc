"""RAM-load the bare-metal self-check using esptool 4.x."""
import argparse
import time
from types import SimpleNamespace

from esptool import detect_chip, load_ram


def check(port, image):
    chip = detect_chip(port=port, baud=115200)
    try:
        if chip.CHIP_NAME != "ESP32-C3":
            raise RuntimeError(f"Expected ESP32-C3, found {chip.CHIP_NAME}")
        load_ram(chip, SimpleNamespace(filename=image))
        serial = chip._port
        serial.timeout = 0.2
        output = bytearray()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            output.extend(serial.read(256))
            if b"C3 BARE METAL integer self-check: 827204 [PASS]\nFPR DONE\n" in output:
                print(output.decode(errors="replace").strip())
                return
        raise RuntimeError(f"Missing self-check result. Received {output[:1800]!r}")
    finally:
        chip._port.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("image")
    args = parser.parse_args()
    check(args.port, args.image)

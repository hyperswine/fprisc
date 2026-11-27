"""RAM-load the bare-metal self-check using esptool 4.x."""
import argparse
import time
from types import SimpleNamespace

from esptool import detect_chip, load_ram


def check_button(serial):
    # Read single bytes so a prompt appears while the guest waits for BOOT.
    for expected, prompt, timeout in (
        (b"1", "GPIO9 high. Press and release BOOT.", 10),
        (b"0", "GPIO9 low. Release BOOT.", 300),
        (b"1", "GPIO9 high again.", 60),
        (b"FPR DONE\n", "BOOT press/release PASS", 10),
    ):
        received = bytearray()
        deadline = time.monotonic() + timeout
        while len(received) < len(expected) and time.monotonic() < deadline:
            received.extend(serial.read(len(expected) - len(received)))
        if received != expected:
            raise RuntimeError(f"Expected {expected!r}, received {received!r}")
        print(prompt, flush=True)


def check(port, image, button=False):
    chip = detect_chip(port=port, baud=115200)
    try:
        if chip.CHIP_NAME != "ESP32-C3":
            raise RuntimeError(f"Expected ESP32-C3, found {chip.CHIP_NAME}")
        load_ram(chip, SimpleNamespace(filename=image))
        serial = chip._port
        serial.timeout = 0.2
        if button:
            return check_button(serial)
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
    parser.add_argument("--button", action="store_true", help="verify a physical BOOT press and release")
    args = parser.parse_args()
    check(args.port, args.image, args.button)

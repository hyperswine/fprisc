"""RAM-load the ESP32-P4 Builtin hardware checks."""
import argparse
from pathlib import Path
import re
import time
from types import SimpleNamespace

from esptool import detect_chip, load_ram


def bounce_button(port):
    # The qualified board's CH343 auto-download circuit drives P4 GPIO35
    # from DTR while RTS is deasserted. Inject bounce on both transitions.
    for asserted in (True, False, True):
        port.setDTR(asserted)
        time.sleep(0.007)
    time.sleep(0.75)
    for asserted in (False, True, False):
        port.setDTR(asserted)
        time.sleep(0.007)


def check(port, image, mode):
    chip = detect_chip(port=port, baud=115200)
    try:
        if chip.CHIP_NAME != "ESP32-P4":
            raise RuntimeError(f"Expected an ESP32-P4, found {chip.CHIP_NAME}")
        load_ram(chip, SimpleNamespace(filename=str(image)))
        chip._port.timeout = 0.2
        if mode == b"G":
            chip._port.setRTS(False)
            chip._port.setDTR(False)
        chip._port.write(mode)
        expected = [b"P4 BARE METAL integer self-check: 827204 [PASS]\n", b"FPR DONE\n"]
        if mode == b"B":
            expected.append(b"P4 SDIO HCI Reset Command Complete PASS\n")
        if mode in (b"T", b"G"):
            expected += [b"P4 machine trap PASS\n", b"P4 monotonic deadline IRQ PASS\n"]
        if mode == b"G":
            expected.append(b"P4 GPIO debounce PASS\n")
        output = bytearray()
        bounced = False
        deadline = time.monotonic() + 15
        while b"FPR DONE\n" not in output and time.monotonic() < deadline:
            output.extend(chip._port.read(256))
            if mode == b"G" and not bounced and b"P4 GPIO35 ready\n" in output:
                bounce_button(chip._port)
                bounced = True
        print(output.decode(errors="replace"), end="", flush=True)
        if any(line not in output for line in expected):
            raise RuntimeError("The P4 did not pass the requested RAM checks")
        if mode == b"G":
            count = re.search(rb"P4 GPIO35 IRQs ([0-9a-f]{8})\n", output)
            if not count or int(count[1], 16) < 4:
                raise RuntimeError("The P4 did not register the injected bounce")
    finally:
        try:
            chip.hard_reset()
        finally:
            chip._port.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("image", type=Path)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--ble-hci", dest="mode", action="store_const", const=b"B")
    modes.add_argument("--timer", dest="mode", action="store_const", const=b"T")
    modes.add_argument("--button-dtr", dest="mode", action="store_const", const=b"G")
    parser.set_defaults(mode=b"?")
    args = parser.parse_args()
    check(args.port, args.image, args.mode)

"""RAM-load the Builtin endurance workload and measure two hours without reset."""
import argparse
import re
import time
from types import SimpleNamespace

from esptool import detect_chip, load_ram

from check_board import until


LINE = re.compile(rb"FPR STATS (\d+) blocks=(\d+) live=(\d+) peak=(\d+) heap=(\d+) minheap=(\d+) stack=(\d+)")


def check(port, image, seconds):
    chip = detect_chip(port=port, baud=115200)
    try:
        if chip.CHIP_NAME != "ESP32-C3":
            raise RuntimeError(f"Unexpected chip {chip.CHIP_NAME}")
        load_ram(chip, SimpleNamespace(filename=image))
        serial = chip._port
        serial.timeout = 0.25
        until(serial, b"FPR READY free_heap=")
        print("Entry heap", until(serial, b"\n").strip().decode(), flush=True)
        start = None
        index = 0
        while True:
            deadline = time.monotonic() + 90
            data = bytearray()
            while time.monotonic() < deadline:
                data.extend(serial.read_until(b"\n"))
                if data.endswith(b"\n"):
                    print(data.rstrip().decode(errors="replace"), flush=True)
                    match = LINE.fullmatch(data.strip())
                    if match:
                        break
                    if b"PANIC" in data or b"FPR DONE" in data or b"FPR READY" in data:
                        raise RuntimeError("Device exited or restarted")
                    data.clear()
            else:
                raise RuntimeError("No device checkpoint within 90 seconds")
            group, blocks, live, peak, heap, minheap, stack = map(int, match.groups())
            if group != index or not (0 < live <= peak <= 8192 and 0 < minheap <= heap and stack > 0):
                raise RuntimeError("Invalid checkpoint")
            if start is None:
                start = time.monotonic()
                baseline = (blocks, live, heap)
            elif (blocks, live, heap) != baseline:
                raise RuntimeError(f"Residency changed from {baseline}")
            elapsed = time.monotonic() - start
            print(f"checkpoint={group} elapsed_s={elapsed:.3f}", flush=True)
            if elapsed >= seconds:
                print(f"PASS: {group + 1} checkpoints", flush=True)
                return
            index += 1
    finally:
        chip._port.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("image")
    parser.add_argument("--seconds", type=int, default=7200)
    args = parser.parse_args()
    if args.seconds <= 0:
        parser.error("duration must be positive")
    check(args.port, args.image, args.seconds)

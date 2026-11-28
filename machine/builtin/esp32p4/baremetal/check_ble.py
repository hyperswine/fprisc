"""Verify the bare-metal P4's ESP32-C6-backed BLE service from macOS."""
import argparse
from pathlib import Path
import re
import subprocess
import time
from types import SimpleNamespace

from esptool import detect_chip, load_ram

UUID = "ACAF3791-694C-4F66-AC82-12C4D04D35D9"
STATS = rb"FPR P4 BLE STATS ms=([0-9a-f]{8}) live=([0-9a-f]{8}) peak=([0-9a-f]{8})"
ADVERTISING = rb"FPR P4 BLE ADVERTISING"
STOPPED = rb"FPR P4 BLE STOPPED"
SAMPLE_SECONDS = 60


class Console:
    def __init__(self, serial):
        self.serial = serial
        self.pending = b""

    def until(self, pattern, seconds=12):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.pending += self.serial.read(256)
            while b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                print(line.decode(errors="replace"), flush=True)
                match = re.fullmatch(pattern, line)
                if match:
                    return match
                if b"P4 Builtin main failed" in line:
                    raise RuntimeError("The P4 BLE program failed")
        raise RuntimeError(f"Missing serial line matching {pattern!r}")

    def command(self, key, expected):
        self.serial.write(key)
        return self.until(expected)


def observe(observer, advertising):
    start = time.monotonic()
    run = subprocess.run([str(observer), UUID], capture_output=True, text=True, timeout=35)
    print(run.stdout.strip(), flush=True)
    if "Bluetooth ready." not in run.stdout:
        raise RuntimeError("The Mac did not start a Bluetooth scan")
    if advertising:
        if run.returncode != 0 or f"BLE PASS {UUID}" not in run.stdout:
            raise RuntimeError("The Mac did not discover the P4 BLE service")
    elif run.returncode != 1 or "No matching BLE advertisement" not in run.stdout:
        raise RuntimeError("Expected a complete scan with no P4 BLE advertisements")
    return time.monotonic() - start


def endurance(console, observer, seconds):
    started = time.monotonic()
    first = last = occupancy = None
    discoveries = []
    while True:
        now, live, peak = [int(value, 16) for value in console.command(b"S", STATS).groups()]
        if first is None:
            first = now
            occupancy = (live, peak)
        if not 0 <= live <= peak <= 8192 or (live, peak) != occupancy:
            raise RuntimeError("Builtin heap changed during BLE endurance")
        if last is not None and not 0 < now - last <= (SAMPLE_SECONDS + 10) * 1000:
            raise RuntimeError("Unexpected gap in device samples")
        last = now
        sample_start = time.monotonic()
        discoveries.append(observe(observer, advertising=True))
        span = (now - first) / 1000
        if span >= seconds and time.monotonic() - started >= seconds:
            break
        interval = min(SAMPLE_SECONDS, max(1, seconds - span + 0.1))
        time.sleep(max(0, interval - (time.monotonic() - sample_start)))
    print(f"BLE endurance PASS {span:.3f} s, {len(discoveries)} Mac discoveries, "
          f"live heap {live} bytes, peak {peak} bytes", flush=True)


def check(port, image, observer, restarts, seconds):
    chip = detect_chip(port=port, baud=115200)
    try:
        if chip.CHIP_NAME != "ESP32-P4":
            raise RuntimeError(f"Expected an ESP32-P4, found {chip.CHIP_NAME}")
        load_ram(chip, SimpleNamespace(filename=str(image)))
        chip._port.timeout = 0.2
        chip._port.write(b"?")
        console = Console(chip._port)
        console.command(b"A", ADVERTISING)
        observe(observer, advertising=True)
        console.command(b"X", STOPPED)
        observe(observer, advertising=False)
        for _ in range(restarts):
            console.command(b"A", ADVERTISING)
            observe(observer, advertising=True)
            console.command(b"X", STOPPED)
        console.command(b"A", ADVERTISING)
        console.command(b"R", rb"FPR P4 BLE RECOVERED")
        observe(observer, advertising=True)
        if seconds:
            endurance(console, observer, seconds)
        console.command(b"Q", STOPPED)
        console.until(rb"FPR DONE")
        print(f"BLE PASS, {restarts} stop/start cycles and companion reset recovery", flush=True)
    finally:
        try:
            chip.hard_reset()
        finally:
            chip._port.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("image", type=Path)
    parser.add_argument("observer", type=Path)
    parser.add_argument("--restarts", type=int, default=3)
    parser.add_argument("--seconds", type=int, default=0)
    args = parser.parse_args()
    if args.restarts < 0 or args.seconds < 0:
        parser.error("restarts and seconds must be nonnegative")
    check(args.port, args.image, args.observer.resolve(), args.restarts, args.seconds)

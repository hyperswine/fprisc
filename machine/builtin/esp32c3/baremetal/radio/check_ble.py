"""Verify C3 advertising and repeated controller restarts on a Mac."""
import argparse
from pathlib import Path
import re
import subprocess
import time

from serial import Serial

from check_station import Console

UUID = "43AA9E7E-1EA0-4AB4-A7C2-1A280B18B13C"
ADVERTISING = re.compile(rb"FPR BLE ADVERTISING " + UUID.encode())
STOPPED = re.compile(rb"FPR BLE STOPPED")
HEAP = re.compile(rb"FPR BLE HEAP live=(\d+) peak=(\d+)")
STATS = re.compile(rb"FPR BLE STATS ms=(\d+) live=(\d+) peak=(\d+)")
ARENA_BYTES = 24 * 1024
SAMPLE_SECONDS = 60


def observe(observer):
    started = time.monotonic()
    scan = subprocess.run([str(observer), UUID], capture_output=True, text=True, timeout=35)
    if scan.returncode or f"BLE PASS {UUID}" not in scan.stdout:
        raise RuntimeError("The Mac did not discover the C3 service UUID")
    elapsed = time.monotonic() - started
    print(scan.stdout.strip(), flush=True)
    print(f"Mac discovery took {elapsed:.3f} s", flush=True)
    return elapsed


def endurance(serial, console, observer, seconds):
    first = None
    last = None
    expected_heap = None
    discoveries = []
    max_gap = 0
    while True:
        serial.write(b"S")
        now, live, peak = map(int, console.until(STATS, 6).groups())
        if not 0 < live <= peak <= ARENA_BYTES:
            raise RuntimeError("Invalid BLE heap counters while advertising")
        if first is None:
            first = now
            expected_heap = (live, peak)
        if (live, peak) != expected_heap:
            raise RuntimeError("BLE heap occupancy changed during endurance")
        if last is not None:
            gap = now - last
            if not 0 < gap <= (SAMPLE_SECONDS + 5) * 1000:
                raise RuntimeError(f"Unexpected gap between BLE device samples: {gap} ms")
            max_gap = max(max_gap, gap)
        last = now
        sample_time = time.monotonic()
        discoveries.append(observe(observer))
        span = now - first
        if span >= seconds * 1000:
            break
        remaining = (seconds * 1000 - span) / 1000
        delay = min(SAMPLE_SECONDS, remaining + 0.05) - (time.monotonic() - sample_time)
        time.sleep(max(0, delay))
    print(f"BLE endurance PASS: {span / 1000:.3f} s device time, "
          f"{len(discoveries)} Mac discoveries, max sample gap {max_gap} ms, "
          f"discovery {min(discoveries):.3f}–{max(discoveries):.3f} s, "
          f"live heap {live} bytes, peak {peak} bytes", flush=True)


def check(port, observer, restarts, seconds=0):
    with Serial(port=None, baudrate=115200, timeout=0.2, write_timeout=5) as serial:
        serial.port = port
        serial.dtr = serial.rts = False
        serial.open()
        console = Console(serial)
        serial.write(b"?")
        console.until(re.compile(rb"FPR C3 FLASH ble"), 15)
        try:
            console.until(ADVERTISING, 20)
            observe(observer)
            if seconds:
                endurance(serial, console, observer, seconds)
            for _ in range(restarts):
                serial.write(b"B")
                console.until(STOPPED, 15)
                live, peak = map(int, console.until(HEAP, 5).groups())
                if live != 0 or peak > ARENA_BYTES:
                    raise RuntimeError("BLE heap occupancy changed after restart")
                console.until(ADVERTISING, 20)
                observe(observer)
        finally:
            serial.write(b"Q")
        console.until(STOPPED, 15)
        live, peak = map(int, console.until(HEAP, 5).groups())
        if live != 0 or peak > ARENA_BYTES:
            raise RuntimeError("BLE heap occupancy changed at shutdown")
        console.until(re.compile(rb"FPR DONE"), 5)
        print(f"BLE PASS: {restarts} restarts, {restarts + 1} Mac observations, peak {peak} bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("observer", type=Path)
    parser.add_argument("--restarts", type=int, default=3)
    parser.add_argument("--seconds", type=int, default=0, help="minimum BLE endurance time")
    args = parser.parse_args()
    if args.restarts < 0:
        parser.error("--restarts must be nonnegative")
    if args.seconds < 0:
        parser.error("--seconds must be nonnegative")
    check(args.port, args.observer.resolve(), args.restarts, args.seconds)

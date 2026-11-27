"""Verify C3 advertising and repeated controller restarts on a Mac."""
import argparse
from pathlib import Path
import re
import subprocess

from serial import Serial

from check_station import Console

UUID = "43AA9E7E-1EA0-4AB4-A7C2-1A280B18B13C"
ADVERTISING = re.compile(rb"FPR BLE ADVERTISING " + UUID.encode())
STOPPED = re.compile(rb"FPR BLE STOPPED")
HEAP = re.compile(rb"FPR BLE HEAP live=(\d+) peak=(\d+)")


def observe(observer):
    scan = subprocess.run([str(observer), UUID], capture_output=True, text=True, timeout=35)
    if scan.returncode or f"BLE PASS {UUID}" not in scan.stdout:
        raise RuntimeError("The Mac did not discover the C3 service UUID")
    print(scan.stdout.strip(), flush=True)


def check(port, observer, restarts):
    with Serial(port=None, baudrate=115200, timeout=0.2, write_timeout=5) as serial:
        serial.port = port
        serial.dtr = serial.rts = False
        serial.open()
        console = Console(serial)
        serial.write(b"?")
        console.until(re.compile(rb"FPR C3 FLASH ble"), 15)
        expected_live = None
        try:
            console.until(ADVERTISING, 20)
            observe(observer)
            for _ in range(restarts):
                serial.write(b"B")
                console.until(STOPPED, 15)
                live, peak = map(int, console.until(HEAP, 5).groups())
                if expected_live is None:
                    expected_live = live
                if live != expected_live or not live <= peak <= 24 * 1024:
                    raise RuntimeError("BLE heap occupancy changed after restart")
                console.until(ADVERTISING, 20)
                observe(observer)
        finally:
            serial.write(b"Q")
        console.until(STOPPED, 15)
        live, peak = map(int, console.until(HEAP, 5).groups())
        if (expected_live is not None and live != expected_live) or not live <= peak <= 24 * 1024:
            raise RuntimeError("BLE heap occupancy changed at shutdown")
        console.until(re.compile(rb"FPR DONE"), 5)
        print(f"BLE PASS: {restarts} restarts, {restarts + 1} Mac observations, peak {peak} bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("observer", type=Path)
    parser.add_argument("--restarts", type=int, default=3)
    args = parser.parse_args()
    if args.restarts < 0:
        parser.error("--restarts must be nonnegative")
    check(args.port, args.observer.resolve(), args.restarts)

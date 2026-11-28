"""Verify concurrent C3 BLE advertisements, Wi-Fi echo and runtime counters on a Mac."""
import argparse
from getpass import getpass
from ipaddress import IPv4Address
from pathlib import Path
import re
import subprocess
import time

from serial import Serial

from check_ble import ADVERTISING, observe
from check_station import CONNECTED, Console, ECHO, provision
STATS = re.compile(
    rb"FPR COEX ms=(\d+) heap=(\d+) peak=(\d+) rx-drop=(\d+) tx-error=(\d+)"
)
ARENA_BYTES = 65536


class Metrics:
    def __init__(self):
        self.last_ms = None
        self.max_gap = 0
        self.samples = 0
        self.peak = 0
        self.min_live = ARENA_BYTES
        self.max_live = 0
        self.dropped = 0
        self.tx_errors = 0
        self.echo = 0
        self.link_ends = 0

    def __call__(self, line):
        if line == b"FPR WIFI LINK ENDED":
            self.link_ends += 1
            self.last_ms = None
            self.echo = 0
        elif line == b"FPR BLE STOPPED":
            self.last_ms = None
        if echo := ECHO.fullmatch(line):
            self.echo = int(echo[1])
        if match := STATS.fullmatch(line):
            now, live, peak, drops, errors = map(int, match.groups())
            if not self.peak <= peak <= ARENA_BYTES or not 0 <= live <= peak:
                raise RuntimeError("Invalid radio heap counters")
            if self.last_ms is not None:
                gap = now - self.last_ms
                if not 0 < gap <= 2500:
                    raise RuntimeError(f"Unexpected gap between device samples: {gap} ms")
                self.max_gap = max(self.max_gap, gap)
            self.last_ms = now
            self.peak = peak
            self.min_live = min(self.min_live, live)
            self.max_live = max(self.max_live, live)
            self.dropped = max(self.dropped, drops)
            self.tx_errors = max(self.tx_errors, errors)
            self.samples += 1


def concurrent_echo(console, address, observer, metrics):
    baseline = metrics.echo
    command = ["ping", "-c", "25", "-i", "0.5", "-W", "1000", str(address)]
    with subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as ping:
        try:
            observe(observer)
            if ping.poll() is not None:
                raise RuntimeError("BLE was observed outside the active Wi-Fi ping window")
            if ping.wait(timeout=15):
                raise RuntimeError("No IPv4 echo reply during the BLE scan window")
        finally:
            if ping.poll() is None:
                ping.terminate()
    deadline = time.monotonic() + 10
    while metrics.echo <= baseline:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("The C3 did not count a new ICMP reply")
        console.until(ECHO, remaining)
    print("PASS: BLE advertising and IPv4 echo observed during the same test", flush=True)


def endurance(console, address, observer, metrics, seconds):
    started = time.monotonic()
    first_sample = metrics.samples
    first_link_ends = metrics.link_ends
    while time.monotonic() - started < seconds:
        window = min(started + seconds, time.monotonic() + 60)
        concurrent_echo(console, address, observer, metrics)
        while time.monotonic() < window:
            console.until(STATS, 4)
    elapsed = time.monotonic() - started
    samples = metrics.samples - first_sample
    if metrics.link_ends != first_link_ends:
        raise RuntimeError("Wi-Fi disconnected during the steady coexistence window")
    if samples < seconds * 0.8:
        raise RuntimeError(f"Only {samples} samples during {elapsed:.1f} seconds")
    print(f"Endurance PASS: {elapsed:.1f} s, {samples} samples, "
          f"max sample gap {metrics.max_gap} ms, live heap {metrics.min_live}–{metrics.max_live} bytes, "
          f"peak {metrics.peak} bytes, RX drops {metrics.dropped}, TX errors {metrics.tx_errors}",
          flush=True)


def check(port, address, ssid, observer, open_network, reconnect, seconds):
    message = provision(address, ssid, "" if open_network else getpass("Test AP passphrase: "))
    with Serial(port=None, baudrate=115200, timeout=0.2, write_timeout=5) as serial:
        serial.port = port
        serial.dtr = serial.rts = False
        serial.open()
        metrics = Metrics()
        console = Console(serial, metrics)
        serial.write(b"?")
        console.until(re.compile(rb"FPR C3 FLASH coex"), 15)
        console.until(re.compile(rb"FPR WIFI CONFIG"), 15)
        serial.write(message)
        try:
            console.until(ADVERTISING, 20)
            if int(console.until(CONNECTED, 120)[1]) != 1:
                raise RuntimeError("Unexpected initial Wi-Fi association")
            endurance(console, address, observer, metrics, seconds)
            serial.write(b"B")
            console.until(re.compile(rb"FPR BLE STOPPED"), 15)
            console.until(ADVERTISING, 20)
            concurrent_echo(console, address, observer, metrics)
            if reconnect:
                print("Restart the test AP and reconnect this Mac to it.", flush=True)
                console.until(re.compile(rb"FPR WIFI LINK ENDED"), 120)
                if int(console.until(CONNECTED, 120)[1]) != 2:
                    raise RuntimeError("Unexpected Wi-Fi reassociation generation")
                concurrent_echo(console, address, observer, metrics)
        finally:
            serial.write(b"Q")
        console.until(re.compile(rb"FPR DONE"), 15)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("ssid")
    parser.add_argument("address", type=IPv4Address)
    parser.add_argument("observer", type=Path, help="path to the compiled Mac BLE observer")
    parser.add_argument("--open", action="store_true", help="use an open test AP")
    parser.add_argument("--reconnect", action="store_true", help="also check after an AP restart")
    parser.add_argument("--seconds", type=int, default=1800, help="minimum coexistence test duration")
    args = parser.parse_args()
    if args.seconds <= 0:
        parser.error("--seconds must be positive")
    check(args.port, args.address, args.ssid, args.observer.resolve(), args.open, args.reconnect, args.seconds)

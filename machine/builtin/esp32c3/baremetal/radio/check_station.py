"""Provision the C3 station test over USB and verify local IPv4 echo from this Mac."""
import argparse
from getpass import getpass
from ipaddress import IPv4Address
import re
import subprocess
import time

from serial import Serial

CONNECTED = re.compile(rb"FPR WIFI CONNECTED (\d+)")
ECHO = re.compile(rb"FPR WIFI ECHO (\d+)")


class Console:
    def __init__(self, port):
        self.port = port
        self.pending = bytearray()

    def until(self, pattern, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.pending.extend(self.port.read_until(b"\n"))
            if not self.pending.endswith(b"\n"):
                continue
            line = bytes(self.pending).rstrip(b"\r\n")
            self.pending.clear()
            # Firmware emits phases and counters. Provisioning bytes are never echoed.
            print(line.decode(errors="replace"), flush=True)
            if b"PANIC" in line or line.startswith(b"C3 trap"):
                raise RuntimeError("C3 reported a firmware failure")
            match = pattern.fullmatch(line)
            if match:
                return match
        raise TimeoutError(f"No C3 response matching {pattern.pattern!r}")


def provision(address, ssid, password):
    encoded_ssid = ssid.encode()
    encoded_password = password.encode()
    if not 1 <= len(encoded_ssid) <= 32 or b"\0" in encoded_ssid:
        raise ValueError("The SSID must have 1–32 bytes with no NUL")
    if encoded_password and (not 8 <= len(encoded_password) <= 63
                             or any(byte < 32 or byte > 126 for byte in encoded_password)):
        raise ValueError("WPA2 test passphrase must have 8–63 printable ASCII bytes")
    if not address.is_private or address.is_loopback or address.is_unspecified or address.is_multicast:
        raise ValueError("Use an unused private IPv4 address on the isolated test network")
    return bytes((len(encoded_ssid), len(encoded_password))) + address.packed + encoded_ssid + encoded_password


def check_echo(console, address, expected_generation):
    association = console.until(CONNECTED, 120)
    if int(association[1]) != expected_generation:
        raise RuntimeError(f"Expected association generation {expected_generation}")
    result = subprocess.run(["ping", "-c", "3", "-W", "1000", str(address)],
                            capture_output=True, text=True, timeout=12)
    if result.returncode != 0:
        raise RuntimeError("The Mac received no IPv4 echo reply")
    if int(console.until(ECHO, 10)[1]) < 1:
        raise RuntimeError("The C3 did not count an IPv4 echo reply")
    print(f"IPv4 echo verified on association {expected_generation}", flush=True)


def check(port, address, ssid, open_network, reconnect):
    message = provision(address, ssid, "" if open_network else getpass("Test AP passphrase: "))
    with Serial(port=None, baudrate=115200, timeout=0.2, write_timeout=5) as serial:
        serial.port = port
        serial.dtr = serial.rts = False
        serial.open()
        console = Console(serial)
        serial.write(b"?")
        console.until(re.compile(rb"FPR C3 FLASH wifi-sta"), 15)
        console.until(re.compile(rb"FPR WIFI CONFIG"), 15)
        serial.write(message)
        try:
            check_echo(console, address, 1)
            if reconnect:
                print("Restart the test AP and reconnect this Mac to it.", flush=True)
                console.until(re.compile(rb"FPR WIFI LINK ENDED"), 120)
                check_echo(console, address, 2)
        finally:
            serial.write(b"Q")
        console.until(re.compile(rb"FPR DONE"), 15)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("ssid")
    parser.add_argument("address", type=IPv4Address)
    parser.add_argument("--open", action="store_true", help="use an open test AP")
    parser.add_argument("--reconnect", action="store_true", help="also check after a test AP restart")
    args = parser.parse_args()
    check(args.port, args.address, args.ssid, args.open, args.reconnect)

"""Append three records to the test journal and check ordered replay across reset."""
import argparse
from contextlib import contextmanager
from types import SimpleNamespace

from esptool import detect_chip, load_ram

from check_board import receive, until


@contextmanager
def boot(port, image):
    chip = detect_chip(port=port, baud=115200)
    try:
        if chip.CHIP_NAME != "ESP32-C3":
            raise RuntimeError(f"Expected ESP32-C3, got {chip.CHIP_NAME}")
        load_ram(chip, SimpleNamespace(filename=image))
        serial = chip._port
        serial.timeout = 0.2
        serial.write_timeout = 5
        until(serial, b"FPR READY free_heap=")
        print("Entry heap", until(serial, b"\n").strip().decode())
        until(serial, b"\x06")
        yield serial
    finally:
        chip._port.close()


def replay(serial):
    serial.write(b"L")
    records = []
    while True:
        length = receive(serial, 1)
        if length == b"\0":
            break
        if not length or length[0] > 64:
            raise RuntimeError(f"Invalid record length {length!r}")
        record = receive(serial, length[0])
        if len(record) != length[0]:
            raise RuntimeError("Incomplete replay")
        records.append(record)
    if receive(serial, 1) != b"\x06":
        raise RuntimeError("Journal reports damaged suffix")
    return records


def check(port, image):
    samples = [bytes(range(64)), b"\0\xffFP-RISC", b"x"]
    with boot(port, image) as serial:
        expected = replay(serial) + samples
        for payload in samples:
            serial.write(b"A" + bytes([len(payload)]) + payload)
            if receive(serial, 1) != b"\x06":
                raise RuntimeError("Append failed")
        if replay(serial) != expected:
            raise RuntimeError("Replay mismatch")
        serial.write(b"A\x40incomplete")
        serial.flush()
    with boot(port, image) as serial:
        if replay(serial) != expected:
            raise RuntimeError("Replay mismatch after reset")
    print("PASS: acknowledged records survived reset during an incomplete serial frame")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("image", help="journal RAM image")
    args = parser.parse_args()
    check(args.port, args.image)

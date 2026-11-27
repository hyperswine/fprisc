"""RAM-load one example and validate its USB bytes, using esptool 4.x."""
import argparse
import hashlib
import time
from types import SimpleNamespace

from esptool import detect_chip, load_ram


def until(port, marker):
    captured = bytearray()
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        captured += port.read(1)
        if captured.endswith(marker):
            return bytes(captured)
    raise RuntimeError(f"Missing {marker!r}. Serial tail: {captured[-1024:]!r}")


def receive(port, size):
    data = bytearray()
    deadline = time.monotonic() + 12
    while len(data) < size and time.monotonic() < deadline:
        data.extend(port.read(size - len(data)))
    return bytes(data)


def check(port, image, mode):
    chip = detect_chip(port=port, baud=115200)
    try:
        if chip.CHIP_NAME != "ESP32-C3":
            raise RuntimeError(f"Expected C3, found {chip.CHIP_NAME}")
        load_ram(chip, SimpleNamespace(filename=image))
        serial = chip._port
        serial.timeout = 0.2
        serial.write_timeout = 5
        until(serial, b"FPR READY free_heap=")
        print("Free heap at entry:", until(serial, b"\n").strip().decode(), flush=True)
        payload = bytes(range(256)) * 4 + b"\x00\xff\r\n"
        if mode in ("write", "read", "exclusive"):
            until(serial, b"\x06")  # filesystem mounted; boot diagnostics have ended
        if mode == "echo":
            # Each write forces reads spanning several 64-byte device buffers.
            for start in range(0, len(payload), 193):
                part = payload[start:start + 193]
                serial.write(part)
                if receive(serial, len(part)) != part:
                    raise RuntimeError(f"Echo mismatch at chunk starting at {start}")
        elif mode == "write":
            serial.write(b"W")
            for start in range(0, len(payload), 64):
                part = payload[start:start + 64]
                serial.write(bytes([len(part)]) + part)
                ack = receive(serial, len(part))
                if ack != part:
                    raise RuntimeError(f"Write failed at {start}: {ack!r}")
            serial.write(b"\x00")
            until(serial, b"FPR DONE 0")
        elif mode == "exclusive":
            serial.write(b"W")
            until(serial, b"FPR DONE -17")  # EEXIST
            print("exclusive create PASS")
            return
        elif mode == "read":
            serial.write(b"R")
            actual = receive(serial, len(payload))
            if actual != payload:
                raise RuntimeError(f"File mismatch: received {len(actual)} bytes; prefix {actual[:64]!r}")
            if until(serial, b"FPR DONE 0") != b"FPR DONE 0":
                raise RuntimeError("Trailing file data before EOF")
        else:
            until(serial, b"827204 [PASS]")
            return
        print(f"{mode} PASS: {len(payload)} bytes, SHA-256 {hashlib.sha256(payload).hexdigest()}")
    finally:
        chip._port.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("image")
    parser.add_argument("mode", choices=["echo", "write", "read", "exclusive", "selfcheck"])
    args = parser.parse_args()
    check(args.port, args.image, args.mode)
